import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// Diagnostic (AB-T-0429): which step of mlx-swift-lm's load leaves arrays alive after the model is dropped.
// GAEA_PROBE_STEPS=<dir> runs `rounds` rounds of: build the model from config.json (step "create"), then also load its
// weights through loadWeights ("weights"), printing MLX's live bytes after each round.
func probeLoadSteps(directory: URL, step: String, rounds: Int) async throws {
    let data = try Data(contentsOf: directory.appending(path: "config.json"))
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
    for i in 0...rounds {
        do {
            let model = try await LLMTypeRegistry.shared.createModel(configuration: data, modelType: base.modelType)
            if step == "weights" {
                try await loadWeights(modelDirectory: directory, model: model, quantization: base.quantization,
                                      perLayerQuantization: base.perLayerQuantization)
            }
        }
        Memory.clearCache()
        print("steps \(step) \(i): MLX active \(Memory.activeMemory) bytes")
    }
}

// GAEA_PROBE_STEP=manual:<last> replays loadWeights with serial, default-stream loading, stopping after <last>:
// sanitize | quantize | update | eval | prepare.
func probeManualLoad(directory: URL, last: String, rounds: Int) async throws {
    let data = try Data(contentsOf: directory.appending(path: "config.json"))
    let base = try JSONDecoder().decode(BaseConfiguration.self, from: data)
    let order = ["sanitize", "quantize", "update", "eval", "prepare"]
    let upTo = order.firstIndex(of: last) ?? 0
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "safetensors" }
    for i in 0...rounds {
        do {
            let model = try await LLMTypeRegistry.shared.createModel(configuration: data, modelType: base.modelType)
            var weights = [String: MLXArray]()
            var metadata = [String: String]()
            for f in files {
                let (a, m) = try loadArraysAndMetadata(url: f)
                weights.merge(a) { $1 }; metadata.merge(m) { $1 }
            }
            weights = model.sanitize(weights: weights, metadata: metadata)
            if upTo >= 1, let q = base.quantization {
                quantize(model: model) { path, _ in weights["\(path).scales"] != nil ? q.asTuple : nil }
            }
            if upTo >= 2 { try model.update(parameters: ModuleParameters.unflattened(weights), verify: ProcessInfo.processInfo.environment["GAEA_PROBE_NOVERIFY"] == "1" ? [] : [.all]) }
            if upTo >= 3 { eval(model) }
            if upTo >= 4 { try model.prepare() }
        }
        Memory.clearCache()
        print("manual \(last) \(i): MLX active \(Memory.activeMemory) bytes")
    }
}

// GAEA_PROBE_SIBLINGS=1: the minimal case. quantized() of a lazy random weight gives three sibling arrays; replacing
// them through _updateInternal (mlx_array_set) instead of dropping them. GAEA_PROBE_SIBLINGS_DROP=1 is the control.
func probeSiblings(rounds: Int, drop: Bool) {
    for i in 0...rounds {
        for _ in 0 ..< 100 {
            let (w, s, b) = MLX.quantized(MLXRandom.uniform(low: -0.5, high: 0.5, [64, 64]), groupSize: 64, bits: 4)
            if !drop {
                w._updateInternal(MLXArray.zeros([1])); s._updateInternal(MLXArray.zeros([1]))
                b?._updateInternal(MLXArray.zeros([1]))
            }
        }
        Memory.clearCache()
        print("siblings \(drop ? "dropped" : "replaced") \(i) (100 layers each): MLX active \(Memory.activeMemory) bytes")
    }
}
