import CoreML
import Foundation

enum ContextualAction: Int {
    case keep = 0
    case yourToYoure
    case theirToTheyre
    case thereToTheyre
    case thereToTheir
    case ofToHave
    case itsToItsApostrophe
}

struct ContextualRerankDecision {
    let action: ContextualAction
    let confidence: Double
}

final class ContextReranker {
    static let shared = ContextReranker()
    static let featureCount = 4_096
    static let automaticThreshold = 0.95

    private let model: MLModel?

    init(bundle: Bundle = .main, computeUnits: MLComputeUnits = .all) {
        guard let url = bundle.url(forResource: "ContextReranker", withExtension: "mlmodelc") else {
            model = nil
            return
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try? MLModel(contentsOf: url, configuration: configuration)
    }

    var isAvailable: Bool { model != nil }

    func decision(tokens: [String]) -> ContextualRerankDecision? {
        guard let model,
              let array = try? MLMultiArray(shape: [NSNumber(value: Self.featureCount)], dataType: .float32) else {
            return nil
        }
        for index in 0..<Self.featureCount { array[index] = 0 }
        for (index, value) in Self.features(tokens: tokens) { array[index] = NSNumber(value: value) }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["features": array]),
              let result = try? model.prediction(from: provider),
              let scores = result.featureValue(for: "scores")?.multiArrayValue else { return nil }

        let rawScores = (0..<scores.count).map { scores[$0].doubleValue }
        guard let maximum = rawScores.max() else { return nil }
        let exponentials = rawScores.map { Foundation.exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        guard total > 0,
              let bestIndex = exponentials.indices.max(by: { exponentials[$0] < exponentials[$1] }),
              let action = ContextualAction(rawValue: bestIndex) else { return nil }
        return ContextualRerankDecision(action: action, confidence: exponentials[bestIndex] / total)
    }

    private static func features(tokens: [String]) -> [Int: Float] {
        let bounded = tokens.suffix(5).map { $0.lowercased() }
        var result: [Int: Float] = [featureIndex("bias"): 1]
        for (index, token) in bounded.enumerated() {
            let relative = index - bounded.count
            result[featureIndex("u:\(relative):\(token)"), default: 0] += 1
            let characters = Array(token)
            if characters.count >= 2 {
                for width in 2...min(4, characters.count) {
                    let prefix = String(characters.prefix(width))
                    let suffix = String(characters.suffix(width))
                    result[featureIndex("p:\(relative):\(prefix)"), default: 0] += 1
                    result[featureIndex("s:\(relative):\(suffix)"), default: 0] += 1
                    for start in 0...(characters.count - width) {
                        let gram = String(characters[start..<(start + width)])
                        result[featureIndex("c:\(relative):\(gram)"), default: 0] += 1
                    }
                }
            }
        }
        if bounded.count >= 2 {
            for index in 1..<bounded.count {
                let relative = index - bounded.count
                result[featureIndex("b:\(relative):\(bounded[index - 1]):\(bounded[index])"), default: 0] += 1
            }
        }
        return result
    }

    private static func featureIndex(_ text: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash % UInt64(featureCount))
    }
}
