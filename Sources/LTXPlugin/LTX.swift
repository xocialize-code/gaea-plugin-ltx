import AVFoundation
import Foundation
import GaeaPluginKit
import GaeaProtocol
import ImageIO
import MLXLTX2
import MLXToolKit
import UniformTypeIdentifiers

// gaea-plugin-ltx: Lightricks' LTX 2.5 distilled (MLX port ltx-2-mlx-swift, Apache-2.0; weights under the LTX-2
// Community License) on MES Video 0.1's video.generate, video.extend and video.retake (media-engine-spec v0.9.0, Gaea
// AB-T-0404). A joint audio-video model: every clip comes with 48 kHz stereo sound.
//
// - One model per tier (VIDEO-EVALUATION §6.1), each with one lane, so a client sees each tier's limits and what it
//   supports: compact24 and balanced32 run one stage with the int8 text encoder; standard64 and max128 run two
//   stages (half size, upsample, refine), which is what last frames, keyframes and soundtracks need. Every tier
//   streams its DiT from the granule tree.
// - Requests speak seconds and the model makes 8k + 1 frames on a /32 grid (/64 on two-stage tiers): the plugin
//   snaps to the nearest value within the tier's limits, warns, and reports what it made (Video §1.4). The package
//   clamps and snaps down on its own; the plugin hands it values already on its grid, so it never does.
// - Edits keep the source's size and frames: Gaea refuses a source off the frame grid or past the limits, and the
//   plugin one off the /32 size grid. A retake's span widens to whole latent frames.
// - Gaea marks every output AI-generated (Video §1.9) and leaves the sound out for `audio: false`.

public let componentsRepo = "mlx-community/ltx-2.5-mlx"

/// LTX 2.5's tiers, as the package's profiles (LTX2Profile), with what each offers through MES.
public enum Tier: String, CaseIterable, Sendable {
    case compact24, balanced32, standard64, max128

    public var id: String { "ltx-2.5-\(rawValue)" }
    public var title: String { "LTX 2.5 (\(rawValue))" }
    public var profile: LTX2Profile { LTX2Profile(rawValue: rawValue)! }
    /// bf16 on max128 (bit-reproducible); the int8 DiT elsewhere (2.5 has no int4 DiT).
    public var quant: Quant { self == .max128 ? .bf16 : .int8 }
    public var lane: String { quant == .bf16 ? "bf16" : "int8" }
    public var twoStage: Bool { !profile.oneStage }
    public var sizeStep: Int { twoStage ? 64 : 32 }
    public var maxWidth: Int { profile.maxWidth }
    public var maxHeight: Int { profile.maxHeight }
    public var maxFrames: Int { profile.maxFrames }
    /// What a conditioned run (a first frame, a source clip) may reach: 512×288 on compact24 (AB-T-0298).
    public var conditionedWidth: Int { profile.conditionedMaxWidth }
    public var conditionedHeight: Int { profile.conditionedMaxHeight }
    /// Last frames and keyframes ride the two-stage path only; so does audio-to-video, which would run two stages even
    /// on a one-stage tier and outgrow its budget.
    public var keyframes: Bool { twoStage }
    public var soundtrack: Bool { twoStage }
    /// The most pixel-frames (width × height × frames) a run may make: the package's measured ceiling, which the engine
    /// enforces (`workloadExceedsDeclaredCeiling`). compact24's is 512×288×121, so at 704×512 it makes 49 frames.
    public var maxPixelFrames: Int {
        configuration(self).activationScalingHint.map { Int($0.measuredCeiling) } ?? .max
    }
    /// The most frames on the 8k + 1 grid at `width`×`height`, within the frame cap and the pixel-frame ceiling.
    public func maxFrames(width: Int, height: Int) -> Int {
        let byCeiling = maxPixelFrames / max(1, width * height)
        return (min(maxFrames, byCeiling) - 1) / 8 * 8 + 1
    }
    public var qualityTiers: [String] {
        switch self {
        case .compact24: ["draft"]
        case .balanced32: ["draft", "standard"]
        case .standard64: ["standard", "best"]
        case .max128: ["best"]
        }
    }
    public var memoryClass: String { self == .max128 ? "xlarge" : "large" }
}

/// The lane each tier runs in: the package's profile advice (the int8 encoder, the lean decoder and the pinned stream
/// gate on the low tiers, streamed blocks on all), at the tier's quant.
///
/// ⚠️ ltx-2-mlx-swift 0.20.0 fetches the low tiers' int8-encoder tree (`-q8`) but `load()` resolves the components from
/// `repo`, so it ran the bf16 encoder and the stock decoder: about 24.9 GB against a declared 16.2 (AB-T-0405,
/// AB-A-0241). Until that's fixed the low tiers name the `-q8` tree as `repo` and set the encoder's quant explicitly, so
/// no suffix is added: the tree they fetch is the tree they load.
public func configuration(_ tier: Tier) -> LTX2Configuration {
    guard tier.profile.recommendedTextEncoderQuant == .int8 else {
        return LTX2Configuration(family: .ltx25, repo: componentsRepo, quant: tier.quant, profile: tier.profile)
    }
    var c = LTX2Configuration(family: .ltx25, repo: componentsRepo + "-q8", quant: tier.quant, profile: tier.profile)
    c.textEncoderQuant = .bf16   // the tree's own encoder is int8; this only stops a second "-q8"
    return c
}

// MARK: - What a job asks

/// One job's request as the plan reads it: built from a GPP run by the worker, and from the command line by
/// ltx-inproc, so both send the package the same request.
public struct Ask: Sendable {
    public var operation: String
    public var prompt: String
    public var params: [String: JSONValue]
    public var inputs: [String: [URL]]
    public var seed: UInt64?

    public init(operation: String, prompt: String, params: [String: JSONValue] = [:], inputs: [String: [URL]] = [:],
                seed: UInt64? = nil) {
        self.operation = operation; self.prompt = prompt; self.params = params; self.inputs = inputs; self.seed = seed
    }

    public init(_ job: Job) throws {
        guard let prompt = try job.text("prompt"), !prompt.isEmpty else {
            throw GPPError(.invalidRequest, "\(job.operation) needs a prompt.", detail: ["param": "prompt"])
        }
        self.init(operation: job.operation, prompt: prompt, params: job.params, inputs: job.inputs, seed: job.seed)
    }

    func number(_ name: String) -> Double? { params[name]?.doubleValue }
    func input(_ name: String) -> URL? { inputs[name]?.first }
}

/// One engine call and what it will report.
public struct Call: Sendable {
    public var request: any WireRequest
    public var effective: [String: JSONValue]
    public var warnings: [Warning]
}

/// A refusal of what the request asks of the media, with the MES code Gaea answers with (GPP-1 §3.5).
func refusal(_ code: String, _ message: String, param: String) -> GPPError {
    GPPError(.invalidRequest, message, detail: ["mes_code": .string(code), "param": .string(param)])
}

func seconds(_ frames: Int, _ fps: Double) -> Double { Double(frames) / fps }
func halfFrame(_ fps: Double) -> Double { 0.5 / fps }

/// The 8k + 1 count nearest `frames` (ties up), at least 9: LTX's frame grid (Video §1.4).
public func gridFrames(_ frames: Double) -> Int { max(9, Int(((frames - 1) / 8).rounded(.toNearestOrAwayFromZero)) * 8 + 1) }

// MARK: - generate

/// The size a generate job asks for: `size`, or `aspect` at `resolution` (the short side), or nil for the default.
func requestedSize(_ ask: Ask) -> (width: Int, height: Int)? {
    if let size = ask.params["size"]?.objectValue, let w = size["width"]?.doubleValue, let h = size["height"]?.doubleValue {
        return (Int(w), Int(h))
    }
    guard let aspect = ask.params["aspect"]?.stringValue else { return nil }
    let parts = aspect.split(separator: ":").compactMap { Double($0) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
    let short = ask.number("resolution") ?? 512
    return parts[0] >= parts[1] ? (Int((short * parts[0] / parts[1]).rounded()), Int(short))
        : (Int(short), Int((short * parts[1] / parts[0]).rounded()))
}

/// A soundtrack's length in seconds (Gaea sends audio as WAV, GPP-1 §3.3).
func audioSeconds(_ url: URL) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    return Double(file.length) / file.processingFormat.sampleRate
}

/// An image input as PNG bytes (it may arrive as JPEG or WebP).
func png(_ url: URL) throws -> Data {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw refusal("input_invalid", "\(url.lastPathComponent) isn't an image.", param: "first_frame")
    }
    let data = NSMutableData()
    guard let out = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw GPPError(.internal, "Can't write PNG.")
    }
    CGImageDestinationAddImage(out, image, nil)
    guard CGImageDestinationFinalize(out) else { throw GPPError(.internal, "Can't write PNG.") }
    return data as Data
}

/// `video.generate` (Video §3.1) on `tier`: the size, frames and keyframes on the model's grid within the tier's
/// limits, each snap warned, and a seed chosen when none was asked for.
public func generateCall(_ ask: Ask, tier: Tier) throws -> Call {
    var warnings: [Warning] = []
    let fps = ask.number("fps") ?? 24
    let firstFrame = ask.input("first_frame"), lastFrame = ask.input("last_frame")
    let keyframes = ask.inputs["keyframes"] ?? []
    let soundtrack = ask.input("soundtrack")
    if (lastFrame != nil || !keyframes.isEmpty) && !tier.keyframes {
        throw refusal("unsupported_parameter", "\(tier.title) runs one stage, which takes no last frame or keyframes.",
                      param: lastFrame != nil ? "last_frame" : "keyframes")
    }
    if soundtrack != nil && !tier.soundtrack {
        throw refusal("unsupported_parameter", "\(tier.title) takes no soundtrack.", param: "soundtrack")
    }
    let conditioned = firstFrame != nil || soundtrack != nil
    let mostW = conditioned ? tier.conditionedWidth : tier.maxWidth, mostH = conditioned ? tier.conditionedHeight : tier.maxHeight

    // The size: the nearest on the grid, never past the tier (Video §1.4). Absent: the model's 704×512, within it.
    let step = tier.sizeStep
    func snap(_ v: Int) -> Int { max(64, Int((Double(v) / Double(step)).rounded(.toNearestOrAwayFromZero)) * step) }
    let (width, height): (Int, Int)
    if let asked = requestedSize(ask) {
        (width, height) = (snap(asked.width), snap(asked.height))
        if width > mostW || height > mostH {
            throw refusal("out_of_limits", "\(asked.width)×\(asked.height) is past \(tier.title)'s \(conditioned ? "conditioned " : "")"
                          + "\(mostW)×\(mostH).", param: firstFrame != nil ? "first_frame" : "size")
        }
        if (width, height) != (asked.width, asked.height) {
            warnings.append(Warning(code: "size_snapped", message: "\(asked.width)×\(asked.height) is \(width)×\(height) on the model's "
                                    + "\(step)-pixel grid.", param: ask.params["size"] != nil ? "size" : "aspect"))
        }
    } else {
        (width, height) = (min(704, mostW) / step * step, min(512, mostH) / step * step)
    }

    // The frames: the nearest 8k + 1 count to duration × fps, within max_frames. Absent: the soundtrack's length, else
    // LTX's 9 frames.
    var frames: Int
    if let duration = ask.number("duration_s") {
        frames = gridFrames(duration * fps)
        if frames > tier.maxFrames {
            throw refusal("out_of_limits", "\(duration) s at \(fps) fps is \(frames) frames; \(tier.title) makes at most \(tier.maxFrames).",
                          param: "duration_s")
        }
        if abs(seconds(frames, fps) - duration) > halfFrame(fps) {
            warnings.append(Warning(code: "duration_snapped", message: String(format: "%g s is %d frames, %.3f s, on the model's 8k + 1 grid.",
                                                                              duration, frames, seconds(frames, fps)), param: "duration_s"))
        }
    } else if let soundtrack {
        let track = try audioSeconds(soundtrack)
        frames = min(gridFrames(track * fps), tier.maxFrames(width: width, height: height))
    } else {
        frames = 9
    }
    let most = tier.maxFrames(width: width, height: height)
    if frames > most {
        throw refusal("out_of_limits", "At \(width)×\(height) \(tier.title) makes at most \(most) frames (\(String(format: "%.2f", seconds(most, fps))) s at "
                      + "\(fps) fps): its measured ceiling is \(tier.maxPixelFrames / 1_000_000) million pixel-frames.", param: "duration_s")
    }
    if let soundtrack {
        let track = try audioSeconds(soundtrack)
        if abs(track - seconds(frames, fps)) > halfFrame(fps) {
            warnings.append(Warning(code: "soundtrack_fitted", message: String(format: "The %.2f s soundtrack is %@ to the %.3f s clip.",
                                                                               track, track > seconds(frames, fps) ? "cut" : "padded with silence",
                                                                               seconds(frames, fps)), param: "soundtrack"))
        }
    }

    // Keyframes at the nearest frame, strictly inside the clip; the last frame on the clip's last.
    let times = ask.params["keyframe_times"]?.arrayValue?.compactMap(\.doubleValue) ?? []
    guard times.count == keyframes.count else {
        throw GPPError(.invalidRequest, "keyframes and keyframe_times go together, one time per image.", detail: ["param": "keyframe_times"])
    }
    var anchors: [MetaValue] = []
    var placed: [JSONValue] = []
    for (time, url) in zip(times, keyframes) {
        let frame = min(max(1, Int((time * fps).rounded())), frames - 2)
        if abs(seconds(frame, fps) - time) > halfFrame(fps) {
            warnings.append(Warning(code: "keyframe_moved", message: String(format: "The keyframe at %g s is on frame %d, %.3f s.",
                                                                            time, frame, seconds(frame, fps)), param: "keyframe_times"))
        }
        anchors.append(.object([KeyframeMetaKeys.path: .string(url.path), KeyframeMetaKeys.frame: .int(frame)]))
        placed.append(.double(seconds(frame, fps)))
    }
    if let lastFrame {
        anchors.append(.object([KeyframeMetaKeys.path: .string(lastFrame.path), KeyframeMetaKeys.frame: .int(frames - 1)]))
    }
    if ask.params["prompt_enhance"]?.stringValue == "on" {
        warnings.append(Warning(code: "prompt_enhance_ignored", message: "Gaea has no prompt enhancer for video; the prompt ran as written.",
                                param: "prompt_enhance"))
    }

    let seed = ask.seed ?? UInt64.random(in: 0 ..< (1 << 32))
    let request = T2VRequest(
        prompt: ask.prompt, initImage: try firstFrame.map { Image(format: .png, data: try png($0)) },
        initAudio: try soundtrack.map { Audio(format: .wav, data: try Data(contentsOf: $0)) },
        numFrames: frames, fps: fps, width: width, height: height, seed: seed,
        metaData: anchors.isEmpty ? [:] : [KeyframeMetaKeys.keyframes: .array(anchors)])
    var effective: [String: JSONValue] = ["seed": .int(Int64(seed)), "frames": .int(Int64(frames)), "fps": .double(fps),
                                          "duration_s": .double(seconds(frames, fps)),
                                          "size": ["width": .int(Int64(width)), "height": .int(Int64(height))]]
    if !placed.isEmpty { effective["keyframe_times"] = .array(placed) }
    return Call(request: request, effective: effective, warnings: warnings)
}

// MARK: - extend and retake

/// A source clip's picture: what an edit keeps.
public struct SourceClip: Sendable, Equatable {
    public var width: Int, height: Int, frames: Int, fps: Double, hasAudio: Bool

    public init(width: Int, height: Int, frames: Int, fps: Double, hasAudio: Bool) {
        self.width = width; self.height = height; self.frames = frames; self.fps = fps; self.hasAudio = hasAudio
    }

    public static func read(_ url: URL) async throws -> SourceClip {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw refusal("input_invalid", "The video has no picture.", param: "video")
        }
        let size = try await video.load(.naturalSize)
        let fps = Double(try await video.load(.nominalFrameRate))
        let range = try await video.load(.timeRange)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        withExtendedLifetime(asset) {}
        return SourceClip(width: Int(size.width), height: Int(size.height), frames: Int((range.duration.seconds * fps).rounded()),
                          fps: fps, hasAudio: audio != nil)
    }
}

/// The latent frame a pixel frame belongs to: frame 0 alone, then eight a latent (LTX's causal VAE).
func latent(ofPixel p: Int) -> Int { p == 0 ? 0 : (p + 7) / 8 }
/// The first and one-past-last pixel frames of latent `k`.
func pixels(ofLatent k: Int) -> (first: Int, end: Int) { k == 0 ? (0, 1) : (8 * k - 7, 8 * k + 1) }

/// A retake span widened outward to whole latent frames (Video §3.3): the pixel frames made again, `[first, end)`.
public func retakeSpan(start: Double, end: Double, fps: Double, frames: Int) -> (first: Int, end: Int) {
    let a = latent(ofPixel: min(frames - 1, Int((start * fps + 1e-6).rounded(.down))))
    let b = latent(ofPixel: min(frames - 1, max(0, Int((end * fps - 1e-6).rounded(.up)) - 1)))
    return (pixels(ofLatent: a).first, min(frames, pixels(ofLatent: max(a, b)).end))
}

/// An edit's output within the tier's pixel-frame ceiling (the engine refuses past it).
func checkEditWorkload(_ source: SourceClip, frames: Int, tier: Tier, param: String) throws {
    let most = tier.maxFrames(width: source.width, height: source.height)
    guard frames <= most else {
        throw refusal("out_of_limits", "At \(source.width)×\(source.height) \(tier.title) edits clips of at most \(most) frames; this one would have "
                      + "\(frames).", param: param)
    }
}

/// The source's size on LTX's /32 edit grid, or an `input_invalid` refusal: the package would cut it down.
func checkEditSize(_ source: SourceClip) throws {
    guard source.width % 32 == 0, source.height % 32 == 0, source.width >= 64, source.height >= 64 else {
        throw refusal("input_invalid", "The video is \(source.width)×\(source.height); LTX edits clips whose sides are multiples of 32 "
                      + "(at least 64), so it would change the clip's size.", param: "video")
    }
}

/// `video.extend` (Video §3.2): `after_s` (default 1 s) in whole 8-frame steps after the source.
public func extendCall(_ ask: Ask, source: SourceClip, video: Data, tier: Tier) throws -> Call {
    try checkEditSize(source)
    var warnings: [Warning] = []
    let asked = ask.number("after_s") ?? 1
    let steps = max(1, Int((asked * source.fps / 8).rounded(.toNearestOrAwayFromZero)))
    try checkEditWorkload(source, frames: source.frames + steps * 8, tier: tier, param: "after_s")
    let added = seconds(steps * 8, source.fps)
    if abs(added - asked) > halfFrame(source.fps) {
        warnings.append(Warning(code: "duration_snapped", message: String(format: "%g s added is %d frames, %.3f s, on the model's 8-frame steps.",
                                                                          asked, steps * 8, added), param: "after_s"))
    }
    let seed = ask.seed ?? UInt64.random(in: 0 ..< (1 << 32))
    let request = VEditRequest(video: Video(format: .mp4, data: video), prompt: ask.prompt, numFrames: source.frames, fps: source.fps,
                               seed: seed, mode: VEditModes.extend, metaData: [RetakeMetaKeys.extendSeconds: .double(added)])
    return Call(request: request, effective: ["seed": .int(Int64(seed)), "after_s": .double(added), "before_s": 0,
                                              "frames": .int(Int64(source.frames + steps * 8))], warnings: warnings)
}

/// `video.retake` (Video §3.3): the span widened to whole latent frames, `retake` picture, sound or both (default: both
/// where the source has sound, else picture).
public func retakeCall(_ ask: Ask, source: SourceClip, video: Data, tier: Tier) throws -> Call {
    try checkEditSize(source)
    try checkEditWorkload(source, frames: source.frames, tier: tier, param: "video")
    guard let start = ask.number("start_s"), let end = ask.number("end_s"), end > start else {
        throw GPPError(.invalidRequest, "A retake needs start_s before end_s.", detail: ["param": "end_s"])
    }
    var warnings: [Warning] = []
    let span = retakeSpan(start: start, end: end, fps: source.fps, frames: source.frames)
    let (from, to) = (seconds(span.first, source.fps), seconds(span.end, source.fps))
    if abs(from - start) > halfFrame(source.fps) || abs(to - end) > halfFrame(source.fps) {
        warnings.append(Warning(code: "span_snapped", message: String(format: "%g–%g s is %.3f–%.3f s, whole latent frames of the model.",
                                                                      start, end, from, to), param: "start_s"))
    }
    let what = ask.params["retake"]?.stringValue ?? (source.hasAudio ? "both" : "picture")
    let mode: Mode = switch what {
    case "picture": VEditModes.replaceVideo
    case "sound": VEditModes.replaceAudio
    default: VEditModes.replaceAudioAndVideo
    }
    let seed = ask.seed ?? UInt64.random(in: 0 ..< (1 << 32))
    // The package remakes the tokens whose start lies in [start, end): a quarter frame inside the span's own edges, so
    // the latents chosen are exactly the widened span's.
    let quarter = 0.25 / source.fps
    let request = VEditRequest(video: Video(format: .mp4, data: video), prompt: ask.prompt, numFrames: source.frames, fps: source.fps,
                               seed: seed, mode: mode,
                               metaData: [RetakeMetaKeys.start: .double(max(0, from - quarter)), RetakeMetaKeys.duration: .double(to - from)])
    return Call(request: request, effective: ["seed": .int(Int64(seed)), "start_s": .double(from), "end_s": .double(to),
                                              "retake": .string(what), "frames": .int(Int64(source.frames))], warnings: warnings)
}

/// The call for any of the three operations.
public func call(_ ask: Ask, tier: Tier) async throws -> Call {
    switch ask.operation {
    case "video.generate":
        return try generateCall(ask, tier: tier)
    case "video.extend", "video.retake":
        guard let url = ask.input("video") else {
            throw GPPError(.invalidRequest, "\(ask.operation) needs the video.", detail: ["param": "video"])
        }
        let source = try await SourceClip.read(url)
        let data = try Data(contentsOf: url)
        return ask.operation == "video.extend" ? try extendCall(ask, source: source, video: data, tier: tier)
            : try retakeCall(ask, source: source, video: data, tier: tier)
    default:
        throw GPPError(.unsupportedOperation, "LTX doesn't do \(ask.operation).")
    }
}

func operation(_ name: String, tier: Tier) -> EngineOperation {
    EngineOperation(name) { job, session in
        let call = try await call(try Ask(job), tier: tier)
        let response = try await session.run(call.request)
        guard let video = (response as? T2VResponse)?.video ?? (response as? VEditResponse)?.video else {
            throw GPPError(.modelError, "LTX returned no video.")
        }
        let url = session.outputDir.appending(path: "video-0.mp4")
        try video.data.write(to: url)
        return RunResult(outputs: [.file("video", url, mediaType: "video/mp4")], effective: call.effective, warnings: call.warnings)
    }
}

// MARK: - The plugin

public let operations = ["video.generate", "video.extend", "video.retake"]

public func lane(_ tier: Tier) -> LaneDefinition {
    LaneDefinition(id: tier.lane, default: true, configuration: configuration(tier))
}

func model(_ tier: Tier) -> ModelDefinition {
    .engine(MLXLTX25Package.self, id: tier.id, title: tier.title, lanes: [lane(tier)], operations: operations.map { operation($0, tier: tier) })
}

public let licenseNotice = "LTX 2.5's weights are under the LTX-2 Community License (Lightricks). By using them you accept its terms, "
    + "including its use restrictions (Attachment A), that an entity with US$10 million or more in annual revenue needs a "
    + "commercial licence from Lightricks, and that what it makes must not be presented without saying it is machine-generated. "
    + "Gaea marks every clip it makes as AI-generated."

func offer(_ tier: Tier, operation: String) -> PluginManifest.Offer {
    var supports: [String: JSONValue] = [
        "audio": true, "sample_rate": 48000, "channels": 2, "negative_prompt": false, "deterministic": .bool(tier.quant == .bf16),
        "frame_step": ["multiple": 8, "offset": 1], "seed": true,
    ]
    var limits: [String: JSONValue] = ["max_frames": .int(Int64(tier.maxFrames)),
                                       "max_duration_s": .double(Double(tier.maxFrames) / 24)]
    switch operation {
    case "video.generate":
        supports["first_frame"] = true
        supports["last_frame"] = .bool(tier.keyframes)
        supports["keyframes"] = .bool(tier.keyframes)
        supports["soundtrack"] = .bool(tier.soundtrack)
        supports["size_step"] = .int(Int64(tier.sizeStep))
        limits["max_width"] = .int(Int64(tier.maxWidth)); limits["max_height"] = .int(Int64(tier.maxHeight))
        limits["min_width"] = 64; limits["min_height"] = 64; limits["max_fps"] = 30
        if tier.keyframes { limits["max_keyframes"] = 5 }
        if tier.soundtrack { limits["max_soundtrack_s"] = .double(Double(tier.maxFrames) / 24) }
    case "video.extend":
        supports["overlap_s"] = 0.5
        supports["extend_before"] = false
        limits["max_width"] = .int(Int64(tier.conditionedWidth)); limits["max_height"] = .int(Int64(tier.conditionedHeight))
        limits["max_source_s"] = .double(Double(tier.maxFrames - 8) / 24)
    default:
        supports["retake"] = ["picture", "sound", "both"]
        limits["max_width"] = .int(Int64(tier.conditionedWidth)); limits["max_height"] = .int(Int64(tier.conditionedHeight))
        limits["max_source_s"] = .double(Double(tier.maxFrames) / 24)
    }
    let notes = tier.twoStage
        ? "Two stages, \(tier.maxWidth)×\(tier.maxHeight) and \(tier.maxFrames) frames at most, with sound. First and last frames, keyframes and a soundtrack."
        : "One stage, \(tier.maxWidth)×\(tier.maxHeight) (\(tier.conditionedWidth)×\(tier.conditionedHeight) from a first frame or a clip) and \(tier.maxFrames) frames at most, with sound."
    let ceiling = " At most \(tier.maxPixelFrames / 1_000_000) million pixel-frames: \(tier.maxFrames(width: tier.maxWidth, height: tier.maxHeight)) frames at "
        + "\(tier.maxWidth)×\(tier.maxHeight)."
    return PluginManifest.Offer(
        operation: operation, profile: "video",
        model: [
            "id": .string(tier.id), "title": .string(tier.title),
            "license": ["spdx": "LicenseRef-LTX-2-Community", "commercial_use": true, "accepted_required": true,
                        "user_accept_required": true, "terms_url": "https://github.com/Lightricks/LTX-2/blob/main/LICENSE",
                        "notice": .string(licenseNotice)],
            "memory_class": .string(tier.memoryClass), "speed_class": "slow",
            "quality_tiers": .array(tier.qualityTiers.map { .string($0) }),
            "notes": .string(notes + ceiling), "supports": .object(supports), "limits": .object(limits),
        ])
}

public let ltxPlugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.ltx", version: "0.1.2", minGaea: "0.11.0", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize-code/gaea-plugin-ltx", title: "LTX 2.5",
    summary: "LTX 2.5: video with sound from text, frames and soundtracks (MES video.generate), and extend and retake, in four memory tiers.",
    license: "Apache-2.0", executable: "gaea-ltx-worker",
    models: Tier.allCases.map(model), offers: Tier.allCases.flatMap { tier in operations.map { offer(tier, operation: $0) } })
