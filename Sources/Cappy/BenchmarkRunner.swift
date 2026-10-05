import CoreML
import Foundation

enum BenchmarkRunner {
    private static func milliseconds(_ start: UInt64, _ end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(Int(Double(sorted.count - 1) * fraction), sorted.count - 1)]
    }

    private static func summary(_ values: [Double]) -> [String: Double] {
        [
            "p50_ms": percentile(values, 0.50),
            "p95_ms": percentile(values, 0.95),
            "p99_ms": percentile(values, 0.99)
        ]
    }

    private static func benchmarkModel(
        name: String,
        computeUnits: MLComputeUnits,
        iterations: Int = 1_000
    ) -> [String: Any] {
        let loadStart = DispatchTime.now().uptimeNanoseconds
        let reranker = ContextReranker(computeUnits: computeUnits)
        let loadEnd = DispatchTime.now().uptimeNanoseconds
        guard reranker.isAvailable else { return ["available": false] }

        let samples = [
            ["your", "returning", "tomorrow"],
            ["their", "arriving", "soon"],
            ["there", "painting", "outside"],
            ["your", "ready", "meal"],
            ["their", "going", "rate"],
            ["there", "is", "hope"]
        ]
        _ = reranker.decision(tokens: samples[0])
        var durations: [Double] = []
        durations.reserveCapacity(iterations)
        for index in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = reranker.decision(tokens: samples[index % samples.count])
            let end = DispatchTime.now().uptimeNanoseconds
            durations.append(milliseconds(start, end))
        }

        let predictions = samples.map { tokens -> [String: Any] in
            guard let decision = reranker.decision(tokens: tokens) else {
                return ["text": tokens.joined(separator: " "), "available": false]
            }
            return [
                "text": tokens.joined(separator: " "),
                "action": String(describing: decision.action),
                "confidence": decision.confidence
            ]
        }

        var result: [String: Any] = [
            "available": true,
            "compute_units": name,
            "cold_load_ms": milliseconds(loadStart, loadEnd),
            "iterations": iterations,
            "predictions": predictions
        ]
        result.merge(summary(durations)) { _, new in new }
        return result
    }

    private static func benchmarkGeneralSpelling() -> [String: Any] {
        let start = DispatchTime.now().uptimeNanoseconds
        let frequencies = WordFrequencyModel.shared
        let loadTime = milliseconds(start, DispatchTime.now().uptimeNanoseconds)
        let samples = [
            "Hello whta is yuor name? ",
            "This is what its doign. ",
            "it should be bale to do all corrections ",
            "I have a bale of hay ",
            "I heard form you yesterday ",
            "visit whta.com and yuor@example.com "
        ]
        let predictions = samples.map { input -> [String: String] in
            var engine = FastCorrectionEngine(contextualSpellingProvider: frequencies.replacement)
            var output = ""
            for character in input {
                output.append(character)
                if let correction = engine.consume(String(character)),
                   let source = CorrectionRangePlanner.sourceRange(for: correction, selection: NSRange(location: (output as NSString).length, length: 0)) {
                    output = (output as NSString).replacingCharacters(in: source, with: correction.replacement)
                }
            }
            return ["input": input, "output": output]
        }
        return ["available": frequencies.isAvailable, "cold_load_ms": loadTime, "predictions": predictions]
    }

    static func run() {
        let iterations = 10_000
        var durations: [Double] = []
        durations.reserveCapacity(iterations)
        for _ in 0..<iterations {
            var engine = FastCorrectionEngine()
            engine.synchronize(leftContext: "I ")
            let start = DispatchTime.now().uptimeNanoseconds
            _ = engine.consume("definately ")
            let end = DispatchTime.now().uptimeNanoseconds
            durations.append(milliseconds(start, end))
        }

        let output: [String: Any] = [
            "hardware": "Mac14,2",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "automatic_threshold": ContextReranker.automaticThreshold,
            "deterministic": summary(durations).merging(["iterations": Double(iterations)]) { _, new in new },
            "general_spelling": benchmarkGeneralSpelling(),
            "coreml": [
                benchmarkModel(name: "cpu_only", computeUnits: .cpuOnly),
                benchmarkModel(name: "cpu_and_neural_engine", computeUnits: .cpuAndNeuralEngine),
                benchmarkModel(name: "all", computeUnits: .all)
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
