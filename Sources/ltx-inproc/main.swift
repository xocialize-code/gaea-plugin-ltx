import Foundation
import LTX2
import MLX
import GaeaProtocol
import LTXPlugin
import MLXLTX2
import MLXServeCore
import MLXToolKit

// The in-process reference for the plugin: LTX 2.5 loaded by MLXServeEngine in this process, with a tier's lane
// configuration and the request the worker builds (LTXPlugin's `call`). The clip is written to --out, and one JSON line
// of timings, the effective values and the warnings is printed. Not part of the plugin bundle.
//
//   ltx-inproc --tier compact24 [--operation video.generate] --prompt <text> [--params <json>] [--input name=path ...]
//              [--seed <n>] [--models-root <dir>] [--out <mp4>] [--repeat <n>] [--unwired]
//
// --repeat runs the request n more times on the same engine (seed + i) and prints MLX's live bytes (cache cleared) and
// the physical footprint after each run: a run should leave nothing behind. --unwired runs without wiring the weights.
// AB-T-0429's soak found 5,264 bytes (1,316 Metal buffers) a run, which killed workers at MLX's 499,000-buffer limit:
// mlx-swift's _updateInternal leaked every quantized load (fixed in mlx-swift 0.32.4 via mlx-engine-swift 0.74.1).
// The GAEA_PROBE_* environment modes below and in LoadProbe.swift are that bisect, kept so it can be rerun
// (gaea-mes-media-server/Docs/Evidence/AB-T-0429/ltx-leak/README.md).

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

let modelsRoot = URL(fileURLWithPath: option("--models-root") ?? "/Volumes/DEV_VOL1/Models/Models", isDirectory: true)
guard let tier = Tier(rawValue: option("--tier") ?? "compact24") else { fatalError("--tier is one of \(Tier.allCases.map(\.rawValue))") }
guard let prompt = option("--prompt") else { fatalError("ltx-inproc needs --prompt") }
let operation = option("--operation") ?? "video.generate"
let params = try option("--params").map { try JSONDecoder().decode([String: GaeaProtocol.JSONValue].self, from: Data($0.utf8)) } ?? [:]
let seed = option("--seed").flatMap(UInt64.init)
let out = option("--out")
let repeats = option("--repeat").flatMap(Int.init) ?? 0
let unwired = args.contains("--unwired")
var inputs: [String: [URL]] = [:]
while let pair = option("--input") {
    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
    inputs[parts[0], default: []].append(URL(fileURLWithPath: parts[1]))
}



if ProcessInfo.processInfo.environment["GAEA_PROBE_SIBLINGS"] == "1" {
    probeSiblings(rounds: max(repeats, 1), drop: ProcessInfo.processInfo.environment["GAEA_PROBE_SIBLINGS_DROP"] == "1")
    exit(0)
}
if let dir = ProcessInfo.processInfo.environment["GAEA_PROBE_STEPS"] {
    let step = ProcessInfo.processInfo.environment["GAEA_PROBE_STEP"] ?? "create"
    if step.hasPrefix("manual:") {
        try await probeManualLoad(directory: URL(fileURLWithPath: dir), last: String(step.dropFirst(7)), rounds: max(repeats, 1))
        exit(0)
    }
    try await probeLoadSteps(directory: URL(fileURLWithPath: dir), step: ProcessInfo.processInfo.environment["GAEA_PROBE_STEP"] ?? "create",
                             rounds: max(repeats, 1))
    exit(0)
}

// Diagnostic (AB-T-0429): GAEA_PROBE_ARRAYS=<dir> loads every safetensors file there with MLX's loadArrays, evaluates
// and drops them (GAEA_PROBE_THREADS=1 does it on DispatchQueue.concurrentPerform, as mlx-swift-lm's loader does).
if let dir = ProcessInfo.processInfo.environment["GAEA_PROBE_ARRAYS"] {
    let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "safetensors" }
    let threads = ProcessInfo.processInfo.environment["GAEA_PROBE_THREADS"] == "1"
    let cpuStream = ProcessInfo.processInfo.environment["GAEA_PROBE_CPU"] == "1"
    let gpuUse = ProcessInfo.processInfo.environment["GAEA_PROBE_GPU_USE"] == "1"
    for i in 0...max(repeats, 1) {
        if threads {
            DispatchQueue.concurrentPerform(iterations: files.count) { k in
                let a = try! MLX.loadArrays(url: files[k], stream: cpuStream ? .cpu : .default); eval(Array(a.values))
            }
        } else {
            for f in files {
                let a = try MLX.loadArrays(url: f, stream: cpuStream ? .cpu : .default); eval(Array(a.values))
                if gpuUse { eval(a.values.map { $0 * 1 }) }
            }
        }
        Memory.clearCache()
        print("arrays \(threads ? "threads" : "serial") cpu=\(cpuStream) gpuUse=\(gpuUse) \(i): MLX active \(Memory.activeMemory) bytes")
    }
    exit(0)
}

// Diagnostic (AB-T-0429): GAEA_PROBE_GEMMA=<dir> loads LTX 2.5's Gemma 4 encoder, encodes the prompt and drops it,
// repeat+1 times, printing MLX's live bytes after each (GAEA_PROBE_GEMMA_LOAD_ONLY=1 skips the forward).
if let dir = ProcessInfo.processInfo.environment["GAEA_PROBE_GEMMA"] {
    let loadOnly = ProcessInfo.processInfo.environment["GAEA_PROBE_GEMMA_LOAD_ONLY"] == "1"
    let url = URL(fileURLWithPath: dir, isDirectory: true)
    for i in 0...max(repeats, 1) {
        do {
            if ProcessInfo.processInfo.environment["GAEA_PROBE_GEMMA3"] == "1" {
                _ = try await GemmaEncoder.load(directory: url)
                Memory.clearCache()
                print("gemma3 load \(i): MLX active \(Memory.activeMemory) bytes")
                continue
            }
            let g = try await Gemma4Encoder.load(directory: url)
            if !loadOnly {
                let cfg = try Gemma4Encoder.specialTokenIds(directory: url)
                let (ids, mask) = Gemma4Encoder.tokenize(prompt, tokenizer: g.context.tokenizer, bosId: cfg.bos, padId: cfg.pad)
                let states = try g.allHiddenStates(tokenIds: ids, attentionMask: mask)
                eval(states); eval(mask)
            }
        }
        if ProcessInfo.processInfo.environment["GAEA_PROBE_RESEED"] == "1" { MLXRandom.seed(0) }
        Memory.clearCache()
        print("gemma \(loadOnly ? "load" : "load+encode") \(i): MLX active \(Memory.activeMemory) bytes")
    }
    exit(0)
}

// The budget Gaea sends a worker on a large Mac: weights wired during a run unless --unwired (Gaea's GAEA_UNWIRED=1).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 100_000_000_000, wiresWeights: !unwired))
await engine.useModelStore(ModelStore(root: modelsRoot))
let id = PackageID(tier.id)
_ = try await engine.register(.of(MLXLTX25Package.self), configuration: lane(tier).configuration, id: id)
var clock = ContinuousClock.now
let capability: Capability = operation == "video.generate" ? .textToVideo : .videoEdit
_ = try await engine.prepare(capability, package: id)
var result: [String: Any] = ["model": tier.id, "operation": operation, "prepare_s": seconds(since: clock)]
let made = try await call(Ask(operation: operation, prompt: prompt, params: params, inputs: inputs, seed: seed), tier: tier)
clock = ContinuousClock.now
let response = try await engine.run(made.request, package: id)
guard let video = (response as? T2VResponse)?.video ?? (response as? VEditResponse)?.video else { fatalError("LTX returned no video") }
result["run_s"] = seconds(since: clock)
result["effective"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(made.effective))
result["warnings"] = made.warnings.map(\.code)
if let out { try video.data.write(to: URL(fileURLWithPath: out)) }
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}
if repeats > 0 {
    // MLX's live arrays after each run, with its buffer cache emptied first: what the run left behind.
    func live() -> Double { Memory.clearCache(); return Double(Memory.activeMemory) }
    var footprints: [Double] = [Double(footprint()) / 1e6]
    var active: [Double] = [live()]
    for i in 1...repeats {
        let again = try await call(Ask(operation: operation, prompt: prompt, params: params, inputs: inputs,
                                       seed: seed.map { $0 + UInt64(i) }), tier: tier)
        _ = try await engine.run(again.request, package: id)
        active.append(live())
        footprints.append(Double(footprint()) / 1e6)
        FileHandle.standardError.write(Data(String(format: "run %d: MLX active %.0f bytes, footprint %.1f MB\n", i, active.last!,
                                                   footprints.last!).utf8))
    }
    result["footprint_mb"] = footprints
    result["active_bytes"] = active
    result["active_bytes_per_run"] = (active.last! - active[0]) / Double(repeats)
}
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
