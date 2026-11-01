import Foundation
import GaeaProtocol
import LTXPlugin
import MLXLTX2
import MLXToolKit
import Testing

@Suite struct PlanTests {
    func ask(_ params: [String: JSONValue], inputs: [String: [URL]] = [:], operation: String = "video.generate") -> Ask {
        Ask(operation: operation, prompt: "A red kite.", params: params, inputs: inputs, seed: 7)
    }

    @Test func framesLandOnTheNearest8kPlus1() {
        #expect(gridFrames(9) == 9 && gridFrames(24) == 25 && gridFrames(20) == 17 && gridFrames(21) == 25 && gridFrames(1) == 9)
    }

    @Test func eachTierHasOneLaneAtItsQuantAndProfile() throws {
        for tier in Tier.allCases {
            let c = try #require(lane(tier).configuration as? LTX2Configuration)
            #expect(c.family == .ltx25 && c.profile == tier.profile && c.quant == tier.quant && c.effectiveStreamedBlocks)
        }
        #expect(configuration(.compact24).effectiveComponentsRepo == "mlx-community/ltx-2.5-mlx-q8")
        #expect(configuration(.max128).effectiveComponentsRepo == "mlx-community/ltx-2.5-mlx")
    }

    @Test func aGenerateSnapsToTheGridAndWarns() throws {
        let call = try generateCall(ask(["size": ["width": 250, "height": 260], "duration_s": 1, "fps": 24]), tier: .compact24)
        let r = try #require(call.request as? T2VRequest)
        #expect((r.width, r.height, r.numFrames, r.fps, r.seed) == (256, 256, 25, 24, 7))
        #expect(call.warnings.map(\.code) == ["size_snapped", "duration_snapped"])
        #expect(call.effective["frames"] == 25 && call.effective["size"] == ["width": 256, "height": 256])
        // Two-stage tiers are on /64.
        let two = try #require(try generateCall(ask(["size": ["width": 300, "height": 200]]), tier: .standard64).request as? T2VRequest)
        #expect((two.width, two.height, two.numFrames) == (320, 192, 9))
    }

    @Test func absentValuesAreTheModelsDefaultsWithinTheTier() throws {
        let c = try #require(try generateCall(ask([:]), tier: .compact24).request as? T2VRequest)
        #expect((c.width, c.height, c.numFrames, c.fps) == (704, 512, 9, 24))
        let b = try #require(try generateCall(ask([:]), tier: .balanced32).request as? T2VRequest)
        #expect((b.width, b.height) == (576, 320))
    }

    @Test func pastTheTierIsOutOfLimits() {
        #expect(throws: GPPError.self) { try generateCall(ask(["size": ["width": 1280, "height": 704]]), tier: .compact24) }
        #expect(throws: GPPError.self) { try generateCall(ask(["duration_s": 10, "fps": 24]), tier: .compact24) }
        #expect(throws: GPPError.self) { try generateCall(ask([:], inputs: ["last_frame": [URL(fileURLWithPath: "/x.png")]]), tier: .compact24) }
    }

    @Test func keyframesGoToTheNearestFrameInsideTheClip() throws {
        let urls = [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.png")]
        let call = try generateCall(ask(["duration_s": 2, "fps": 24, "keyframe_times": [0.51, 1.0]], inputs: ["keyframes": urls]),
                                    tier: .standard64)
        let r = try #require(call.request as? T2VRequest)
        let frames = r.metaData[KeyframeMetaKeys.keyframes]
        #expect(frames == .array([.object(["path": .string("/a.png"), "frame": .int(12)]), .object(["path": .string("/b.png"), "frame": .int(24)])]))
        // 2 s is 48 frames, which the grid makes 49; the keyframes themselves moved less than half a frame.
        #expect(call.warnings.map(\.code) == ["duration_snapped"])
    }

    @Test func aRetakeSpanWidensToWholeLatentFrames() {
        // 17 frames at 24: latents 0 (frame 0), 1 (1–8), 2 (9–16).
        #expect(retakeSpan(start: 0.4, end: 0.7, fps: 24, frames: 17) == (9, 17))
        #expect(retakeSpan(start: 0.1, end: 0.3, fps: 24, frames: 17) == (1, 9))
        #expect(retakeSpan(start: 0, end: 0.05, fps: 24, frames: 17) == (0, 9))
        #expect(retakeSpan(start: 9.0 / 24, end: 17.0 / 24, fps: 24, frames: 17) == (9, 17))
    }

    @Test func aRetakeRemakesThoseLatentsAndReportsTheSpan() throws {
        let source = SourceClip(width: 128, height: 96, frames: 17, fps: 24, hasAudio: true)
        let call = try retakeCall(ask(["start_s": 0.4, "end_s": 0.7], operation: "video.retake"), source: source, video: Data())
        let r = try #require(call.request as? VEditRequest)
        #expect(r.mode == VEditModes.replaceAudioAndVideo && r.numFrames == 17)
        let start = try #require(r.metaData[RetakeMetaKeys.start].flatMap { if case .double(let v) = $0 { v } else { nil } })
        #expect(abs(start - (9.0 / 24 - 0.25 / 24)) < 1e-9)
        #expect(call.effective["start_s"] == .double(9.0 / 24) && call.effective["end_s"] == .double(17.0 / 24))
        #expect(call.warnings.map(\.code) == ["span_snapped"])
        let silent = SourceClip(width: 128, height: 96, frames: 17, fps: 24, hasAudio: false)
        let picture = try retakeCall(ask(["start_s": 0.4, "end_s": 0.7], operation: "video.retake"), source: silent, video: Data())
        #expect((picture.request as? VEditRequest)?.mode == VEditModes.replaceVideo && picture.effective["retake"] == "picture")
        #expect(throws: GPPError.self) {
            try retakeCall(ask(["start_s": 0.1, "end_s": 0.3], operation: "video.retake"),
                           source: SourceClip(width: 120, height: 96, frames: 17, fps: 24, hasAudio: true), video: Data())
        }
    }

    @Test func anExtendAddsWholeEightFrameSteps() throws {
        let source = SourceClip(width: 128, height: 96, frames: 17, fps: 24, hasAudio: true)
        let call = try extendCall(ask(["after_s": 0.34], operation: "video.extend"), source: source, video: Data())
        #expect(call.effective["after_s"] == .double(1.0 / 3) && call.effective["frames"] == 25 && call.warnings.isEmpty)
        let more = try extendCall(ask(["after_s": 1.1], operation: "video.extend"), source: source, video: Data())
        #expect(more.effective["frames"] == 41 && more.warnings.map(\.code) == ["duration_snapped"])
    }

    @Test func theOffersTellEachTiersTruthAndAskForAcceptance() {
        let offers = ltxPlugin.offers
        #expect(offers.count == 12 && ltxPlugin.models.map(\.id) == Tier.allCases.map(\.id))
        for offer in offers {
            let license = offer.model["license"]
            #expect(license?["accepted_required"] == true && license?["user_accept_required"] == true)
            #expect(license?["spdx"] == "LicenseRef-LTX-2-Community")
        }
        let generate = offers.filter { $0.operation == "video.generate" }
        #expect(generate.map { $0.model["supports"]?["keyframes"] } == [false, false, true, true])
        #expect(generate.map { $0.model["limits"]?["max_width"] } == [704, 576, 1280, 1920])
        #expect(generate.map { $0.model["supports"]?["deterministic"] } == [false, false, false, true])
        let compactRetake = offers.first { $0.operation == "video.retake" && $0.model["id"] == "ltx-2.5-compact24" }
        #expect(compactRetake?.model["limits"]?["max_width"] == 512)
    }
}
