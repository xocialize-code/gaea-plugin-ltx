import Foundation
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
//              [--seed <n>] [--models-root <dir>] [--out <mp4>]

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
let params = try option("--params").map { try JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8)) } ?? [:]
let seed = option("--seed").flatMap(UInt64.init)
let out = option("--out")
var inputs: [String: [URL]] = [:]
while let pair = option("--input") {
    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
    inputs[parts[0], default: []].append(URL(fileURLWithPath: parts[1]))
}

// The budget Gaea sends a worker on a large Mac (wiresWeights off).
let engine = MLXServeEngine(workerBudget: WorkerBudget(ceilingBytes: 100_000_000_000, wiresWeights: false))
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
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
result["max_rss_gb"] = Double(usage.ru_maxrss) / 1e9
print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
