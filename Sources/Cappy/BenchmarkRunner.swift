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

    private static func benchmarkPersonalisation() -> [String: Any] {
        let suite = "CappyBenchmark.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = PersonalizationStore(defaults: defaults)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let protected = ProtectedWords(url: url, watch: false)
        defer { store.flush(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        protected.protect("SMT")
        for _ in 0..<12 { store.record(.suggestionAccepted, original: "ware", replacement: "are") }
        let ranker = ContextualPhraseRanker(frequencies: .shared, provider: NativeSpellingCandidates.cachedSuggestions)
        func measure(_ operation: () -> Void) -> [String: Double] {
            operation()
            var durations: [Double] = []; durations.reserveCapacity(2000)
            for _ in 0..<2000 {
                let start = DispatchTime.now().uptimeNanoseconds; operation()
                durations.append(milliseconds(start, DispatchTime.now().uptimeNanoseconds))
            }
            return summary(durations)
        }
        var firstUse: [Double] = []
        for word in ["botanical", "acoustics", "chrysanthemum", "solstice", "orthogonal", "polyphony", "tessellate", "rhythmic", "zirconium", "metaphorical", "lithography", "luminescent", "archetypal", "apothecary", "parallax", "silhouette", "quixotic", "thermodynamic", "benevolent", "cartography"] {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = NativeSpellingCandidates.suggestions(for: word)
            firstUse.append(milliseconds(start, DispatchTime.now().uptimeNanoseconds))
        }
        let ordinary = measure {
            var engine = FastCorrectionEngine(); engine.synchronize(leftContext: "Hello ")
            for character in "ordinarytyping" { _ = engine.consume(String(character)) }
        }
        let spelling = measure {
            var engine = FastCorrectionEngine(); engine.synchronize(leftContext: "I "); _ = engine.consume("teh ")
        }
        let generation = measure { _ = ranker.candidates(tokens: ["Ho", "ware", "you"]) }
        let ranking = measure { _ = ranker.score(["how", "are", "you"]) }
        let personal = measure { _ = store.adjustment(original: "ware", replacement: "are") }
        let suggestions = measure {
            var engine = FastCorrectionEngine(phraseProvider: ranker.candidates)
            engine.synchronize(leftContext: "ware "); _ = engine.consume("you "); _ = engine.suggestion
        }
        let lookup = measure { _ = protected.suppresses(original: "SMT", replacement: "smart") }
        let boundary = measure {
            var engine = FastCorrectionEngine(rerankProvider: ContextReranker.shared.decision,
                contextualSpellingProvider: WordFrequencyModel.shared.replacement, phraseProvider: ranker.candidates,
                personalScore: { store.adjustment(original: $0.source, replacement: $0.replacement, context: $0.contextSignature) })
            engine.synchronize(leftContext: "What ar "); _ = engine.consume("you ")
        }
        return ["iterations": 2000, "uncached_spelling_lookup_20_words": summary(firstUse), "ordinary_typing_14_characters": ordinary, "simple_spelling": spelling,
            "phrase_generation_and_pruning": generation, "phrase_ranking": ranking,
            "personalised_scoring": personal, "suggestion_generation": suggestions,
            "protected_word_lookup": lookup, "complete_phrase_boundary": boundary]
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
            "personalisation": benchmarkPersonalisation(),
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

struct CorrectionEvaluationCase: Codable {
    let group: String
    let input: String
    let expected: String
}
enum CorrectionEvaluationRunner {
    private final class EvaluationDocument: CorrectionClient {
        var text = ""
        var caret = 0
        func selectedRange() -> NSRange { NSRange(location: caret, length: 0) }
        func attributedSubstring(from range: NSRange) -> NSAttributedString? {
            guard range.location != NSNotFound, NSMaxRange(range) <= (text as NSString).length else { return nil }
            return NSAttributedString(string: (text as NSString).substring(with: range))
        }
        func insertText(_ string: String, replacementRange: NSRange) {
            let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            text = (text as NSString).replacingCharacters(in: range, with: string)
            caret = range.location + (string as NSString).length
        }
    }
    static func integrity(cases: [CorrectionEvaluationCase], frequencies: WordFrequencyModel) -> [String: Any] {
        let suite = "CappyIntegrityEvaluation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let words = ProtectedWords(url: url, watch: false)
        var undoAttempts = 0, undoSuccess = 0, protectedAttempts = 0, protectedSuccess = 0
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: url) }
        for item in cases {
            // Fresh learning per fixture avoids cross-case preference contamination.
            defaults.removePersistentDomain(forName: suite)
            let store = PersonalizationStore(defaults: defaults)
            let session = CorrectionSession(personalization: store, frequencyModel: frequencies, protectedWords: words)
            let document = EvaluationDocument()
            var last: FastCorrection?
            session.onPresentation = { presentation, _ in
                if case .corrected(let correction) = presentation { last = correction }
                return true
            }
            for character in item.input { last = nil; _ = session.processInput(String(character), client: document) }
            if let correction = last {
                for command in ["undo:", "deleteBackward:"] {
                    // Separate session for each undo semantic.
                    let trial = EvaluationDocument()
                    let trialSession = CorrectionSession(personalization: PersonalizationStore(defaults: UserDefaults(suiteName: suite + command)!), frequencyModel: frequencies, protectedWords: words)
                    for character in item.input { _ = trialSession.processInput(String(character), client: trial) }
                    let range = NSRange(location: (trial.text as NSString).length - correction.replacementUTF16Length - correction.suffixUTF16Length,
                        length: correction.replacementUTF16Length + correction.suffixUTF16Length)
                    let restored = correction.original + (command == "undo:" ? correction.suffix : String(correction.suffix.dropLast()))
                    let expected = (trial.text as NSString).replacingCharacters(in: range, with: restored)
                    undoAttempts += 1
                    if trialSession.didCommand(command, client: trial), trial.text == expected, trial.caret == (expected as NSString).length { undoSuccess += 1 }
                    trialSession.finishSession(); UserDefaults(suiteName: suite + command)?.removePersistentDomain(forName: suite + command)
                }
            }
            session.finishSession()
        }
        for token in ["SMT", "IFVG", "NQ", "CoreML", "QuantLab", "teh", "yuor", "ware", "bale", "Elowen"] {
            _ = words.protect(token)
            let store = PersonalizationStore(defaults: defaults)
            let session = CorrectionSession(personalization: store, frequencyModel: frequencies, protectedWords: words)
            let document = EvaluationDocument()
            for character in token + " " { _ = session.processInput(String(character), client: document) }
            protectedAttempts += 1
            if document.text == token + " " { protectedSuccess += 1 }
            session.finishSession()
        }
        return ["undo_attempts": undoAttempts, "undo_successes": undoSuccess,
            "undo_success": undoAttempts == 0 ? 0 : Double(undoSuccess) / Double(undoAttempts),
            "protected_word_attempts": protectedAttempts, "protected_word_successes": protectedSuccess,
            "protected_word_success": Double(protectedSuccess) / Double(protectedAttempts)]
    }

    static func run(cases: [CorrectionEvaluationCase], frequencies: WordFrequencyModel) -> [String: Any] {
        var autoTP = 0, autoFP = 0, suggestionTP = 0, suggestionFP = 0
        var positiveCases = 0, negativeCases = 0, autoSuccess = 0, suggestionSuccess = 0
        var falsePositiveCases = 0, falseNegativeCases = 0, phraseSuccess = 0, phraseCount = 0
        var predictions: [[String: Any]] = []
        let ranker = ContextualPhraseRanker(frequencies: frequencies, provider: NativeSpellingCandidates.cachedSuggestions)
        for item in cases {
            let positive = item.input != item.expected
            if positive { positiveCases += 1 } else { negativeCases += 1 }
            var engine = FastCorrectionEngine(rerankProvider: ContextReranker.shared.decision,
                contextualSpellingProvider: frequencies.replacement, phraseProvider: ranker.candidates)
            var output = "", hadCorrectSuggestion = false
            var suggestions: [String] = []
            let characters = Array(item.input)
            for (index, character) in characters.enumerated() {
                output.append(character)
                let automatic = engine.consume(String(character))
                let remaining = String(characters.dropFirst(index + 1))
                if let correction = automatic,
                   let range = CorrectionRangePlanner.sourceRange(for: correction, selection: NSRange(location: (output as NSString).length, length: 0)) {
                    output = (output as NSString).replacingCharacters(in: range, with: correction.replacement)
                    if output + remaining == item.expected { autoTP += 1 } else { autoFP += 1 }
                } else if let suggestion = engine.suggestion,
                          let range = CorrectionRangePlanner.sourceRange(for: suggestion, selection: NSRange(location: (output as NSString).length, length: 0)) {
                    let proposed = (output as NSString).replacingCharacters(in: range, with: suggestion.replacement)
                    suggestions.append(suggestion.original + " → " + suggestion.replacement)
                    if proposed + remaining == item.expected { suggestionTP += 1; hadCorrectSuggestion = true }
                    else { suggestionFP += 1 }
                }
            }
            if positive && output == item.expected { autoSuccess += 1 }
            if positive && hadCorrectSuggestion { suggestionSuccess += 1 }
            if !positive && output != item.expected { falsePositiveCases += 1 }
            if positive && output != item.expected && !hadCorrectSuggestion { falseNegativeCases += 1 }
            if item.group == "multi-word mistakes" {
                phraseCount += 1
                if output == item.expected || hadCorrectSuggestion { phraseSuccess += 1 }
            }
            predictions.append(["group": item.group, "input": item.input, "expected": item.expected,
                "automatic_output": output, "suggestions": suggestions, "correct_suggestion": hadCorrectSuggestion])
        }
        func ratio(_ numerator: Int, _ denominator: Int) -> Any { denominator == 0 ? NSNull() : Double(numerator) / Double(denominator) }
        return ["cases": cases.count, "positive_cases": positiveCases, "negative_cases": negativeCases,
            "automatic_precision": ratio(autoTP, autoTP + autoFP), "automatic_recall": ratio(autoSuccess, positiveCases),
            "suggestion_precision": ratio(suggestionTP, suggestionTP + suggestionFP), "suggestion_recall": ratio(suggestionSuccess, positiveCases),
            "false_positive_rate": ratio(falsePositiveCases, negativeCases), "false_negative_rate": ratio(falseNegativeCases, positiveCases),
            "phrase_correction_success": ratio(phraseSuccess, phraseCount),
            "automatic_correct_edits": autoTP, "automatic_incorrect_edits": autoFP,
            "suggestion_correct_events": suggestionTP, "suggestion_incorrect_events": suggestionFP,
            "predictions": predictions]
    }
    static func run(url: URL) throws {
        let cases = try JSONDecoder().decode([CorrectionEvaluationCase].self, from: Data(contentsOf: url))
        var output = run(cases: cases, frequencies: .shared)
        output["integrity"] = integrity(cases: cases, frequencies: .shared)
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
