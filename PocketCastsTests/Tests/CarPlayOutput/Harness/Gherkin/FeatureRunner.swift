import ObjectiveC
import XCTest

/// M13.1 harness. E6, option A: a minimal in-bundle Gherkin runner. Parses a `.feature` file, registers each
/// scenario as its own XCTest method, resolves steps against regex step definitions, and reports
/// failures at the `.feature` line with the step definition's Swift location in the message.

struct FeatureStep {
    let keyword: String   // Given / When / Then (And and But inherit the previous one)
    let text: String
    let line: Int
}

struct FeatureScenario {
    let name: String
    let tags: [String]
    let line: Int
    var featurePath: String = ""
    let steps: [FeatureStep]
}

struct FeatureFile {
    let name: String
    let path: String
    let scenarios: [FeatureScenario]
}

enum FeatureParser {
    /// A `.feature` file is read from `path`. On a device that path (on the Mac) does not exist, so fall back to a
    /// copy bundled with the tests under the same file name (`make test_carplay_device` copies them in).
    static func resolve(_ path: String) -> String {
        if FileManager.default.fileExists(atPath: path) { return path }
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        return Bundle(for: FeatureTestCase.self).path(forResource: name, ofType: url.pathExtension) ?? path
    }

    static func parse(path: String) throws -> FeatureFile {
        let text = try String(contentsOfFile: resolve(path), encoding: .utf8)
        var featureName = ""
        var background: [FeatureStep] = []
        var scenarios: [FeatureScenario] = []
        var pendingTags: [String] = []
        var current: (name: String, tags: [String], line: Int, steps: [FeatureStep])?
        var inBackground = false
        var lastKeyword = "Given"

        func closeScenario() {
            if let c = current { scenarios.append(FeatureScenario(name: c.name, tags: c.tags, line: c.line, featurePath: path, steps: background + c.steps)) }
            current = nil
        }

        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = index + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("@") {
                pendingTags += trimmed.split(separator: " ").map { String($0.dropFirst()) }
                continue
            }
            if trimmed.hasPrefix("Feature:") {
                featureName = String(trimmed.dropFirst("Feature:".count)).trimmingCharacters(in: .whitespaces)
                pendingTags = []
            } else if trimmed.hasPrefix("Background:") {
                closeScenario(); inBackground = true
            } else if trimmed.hasPrefix("Scenario:") {
                closeScenario(); inBackground = false
                current = (String(trimmed.dropFirst("Scenario:".count)).trimmingCharacters(in: .whitespaces), pendingTags, line, [])
                pendingTags = []
            } else if let keyword = ["Given", "When", "Then", "And", "But"].first(where: { trimmed.hasPrefix($0 + " ") }) {
                let body = String(trimmed.dropFirst(keyword.count + 1)).trimmingCharacters(in: .whitespaces)
                let effective = (keyword == "And" || keyword == "But") ? lastKeyword : keyword
                lastKeyword = effective
                let step = FeatureStep(keyword: effective, text: body, line: line)
                if inBackground { background.append(step) } else if current != nil { current!.steps.append(step) }
            }
            // Anything else (feature description lines) is ignored.
        }
        closeScenario()
        return FeatureFile(name: featureName, path: path, scenarios: scenarios)
    }
}

final class StepLibrary {
    struct Definition {
        let regex: NSRegularExpression
        let pattern: String
        let file: String
        let line: UInt
        let handler: ([String]) throws -> Void
    }

    private(set) var definitions: [Definition] = []

    func add(_ pattern: String, file: StaticString = #fileID, line: UInt = #line, _ handler: @escaping ([String]) throws -> Void) {
        definitions.append(Definition(regex: try! NSRegularExpression(pattern: "^" + pattern + "$"), pattern: pattern,
                                      file: "\(file)", line: line, handler: handler))
    }

    func matches(_ text: String) -> [(Definition, [String])] {
        let range = NSRange(text.startIndex..., in: text)
        return definitions.compactMap { d in
            guard let m = d.regex.firstMatch(in: text, range: range) else { return nil }
            let captures = (1..<max(1, m.numberOfRanges)).compactMap { i -> String? in
                Range(m.range(at: i), in: text).map { String(text[$0]) }
            }
            return (d, captures)
        }
    }

    /// First match wins. `FeatureExecution` additionally rejects steps with more than one match.
    func match(_ text: String) -> (Definition, [String])? { matches(text).first }
}

struct StepFailure: Error, CustomStringConvertible {
    let message: String
    /// nil is an ordinary harness/precondition error, including all existing StepFailure(message:) calls.
    let outputAssertionDiagnostic: String?
    var description: String { message }

    private init(message: String, outputAssertionDiagnostic: String?) {
        self.message = message
        self.outputAssertionDiagnostic = outputAssertionDiagnostic
    }

    init(message: String) { self.init(message: message, outputAssertionDiagnostic: nil) }

    /// Opt in only at the final output comparison, after readiness/network/precondition checks succeed.
    static func outputAssertion(diagnostic: String, message: String) -> StepFailure {
        StepFailure(message: message, outputAssertionDiagnostic: diagnostic)
    }
}

/// Outcome of a failed scenario. Pure data: no XCTest types.
struct FeatureFailure {
    enum Kind { case undefinedStep, stepFailed, ambiguousStep }
    var kind: Kind
    var keyword: String
    var stepText: String
    var featurePath: String
    var line: Int
    var definitionFile: String?
    var definitionLine: UInt?
    var errorText: String?
    var outputAssertionDiagnostic: String?
    var ambiguousWith: [String] = []   // "file:line" of every matching definition

    var message: String {
        let at = "\((featurePath as NSString).lastPathComponent):\(line)"
        switch kind {
        case .undefinedStep:
            return "UNDEFINED STEP: \(keyword) \(stepText) (\(at))"
        case .ambiguousStep:
            return "AMBIGUOUS STEP: \(keyword) \(stepText) (\(at)) matches \(ambiguousWith.joined(separator: " and "))"
        case .stepFailed:
            return "\(keyword) \(stepText) (\(at))\n  \(errorText ?? "")\n  (step definition: \(definitionFile ?? "?"):\(definitionLine ?? 0))"
        }
    }
}

enum FeatureExecution {
    /// Runs the steps in order and stops at the first failure.
    static func run(scenario: FeatureScenario, steps: StepLibrary) -> FeatureFailure? {
        for step in scenario.steps {
            if let failure = run(step: step, scenario: scenario, steps: steps) { return failure }
        }
        return nil
    }

    static func run(step: FeatureStep, scenario: FeatureScenario, steps: StepLibrary) -> FeatureFailure? {
        func failure(_ kind: FeatureFailure.Kind) -> FeatureFailure {
            FeatureFailure(kind: kind, keyword: step.keyword, stepText: step.text, featurePath: scenario.featurePath, line: step.line)
        }
        let found = steps.matches(step.text)
        guard let (definition, captures) = found.first else { return failure(.undefinedStep) }
        if found.count > 1 {
            var f = failure(.ambiguousStep)
            f.ambiguousWith = found.map { "\($0.0.file):\($0.0.line)" }
            return f
        }
        do {
            try definition.handler(captures)
        } catch {
            var f = failure(.stepFailed)
            f.definitionFile = definition.file
            f.definitionLine = definition.line
            f.errorText = "\(error)"
            f.outputAssertionDiagnostic = (error as? StepFailure)?.outputAssertionDiagnostic
            return f
        }
        return nil
    }
}

/// Base class: subclasses supply the feature path and step definitions. Each scenario becomes an XCTest
/// method named `scenario_L<line>[_<tags>]_<slug>`: the line makes the name unique, the slug keeps it readable,
/// so `-only-testing:` and the `.xcresult` see each scenario individually.
class FeatureTestCase: HarnessScenarioCase {
    class var featurePath: String { fatalError("subclass must supply featurePath") }
    class var knownBugs: KnownBugs.Table { [:] }

    /// Fixture classes exist only to be run explicitly by a self-test. They are left out of normal discovery
    /// unless `allowFixtureSuites` is set around the explicit call.
    class var isFixture: Bool { false }
    static var allowFixtureSuites = false

    var currentScenario: FeatureScenario?

    /// Subclasses register definitions bound to this test instance.
    func registerSteps(_ registry: StepLibrary) { fatalError("subclass must register steps") }

    /// `<worktree>/../contracts/features/<relativePath>`, with the worktree found as the parent of `PocketCastsTests`
    /// in the caller's `#filePath`.
    static func contractsFeature(_ relativePath: String, filePath: String = #filePath) -> String {
        var parts = filePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let i = parts.lastIndex(of: "PocketCastsTests") { parts = Array(parts[..<i]) }
        if !parts.isEmpty { parts.removeLast() }   // worktree directory -> its parent, which holds contracts/
        return "/" + (parts + ["contracts", "features", relativePath]).joined(separator: "/")
    }

    /// Where failures go. Tests override this to collect instead of record.
    func report(_ issue: XCTIssue) { record(issue) }

    static func testMethodName(for scenario: FeatureScenario) -> String {
        let slug = scenario.name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
            .split(separator: "_", omittingEmptySubsequences: true).prefix(8).joined(separator: "_")
        return (["scenario", "L\(scenario.line)"] + scenario.tags + [slug]).joined(separator: "_")
    }

    override class var defaultTestSuite: XCTestSuite {
        let suite = XCTestSuite(name: NSStringFromClass(self))
        guard self != FeatureTestCase.self else { return suite }
        if isFixture && !FeatureTestCase.allowFixtureSuites { return suite }
        let path = featurePath
        var names: [(String, (FeatureTestCase) -> Void)] = []
        do {
            let feature = try FeatureParser.parse(path: path)
            if feature.scenarios.isEmpty { throw StepFailure(message: "no scenarios found") }
            try KnownBugs.validate(knownBugs, in: feature)
            names = feature.scenarios.map { scenario in (testMethodName(for: scenario), { $0.execute(scenario) }) }
        } catch {
            names = [("scenario_feature_file_unreadable", { test in
                test.reportFailure("Cannot read feature file \(path): \(error)", path: path, line: 1)
            })]
        }
        for (name, body) in names {
            let selector = NSSelectorFromString(name)
            let block: @convention(block) (FeatureTestCase) -> Void = { body($0) }
            class_addMethod(self, selector, imp_implementationWithBlock(block), "v@:")
            suite.addTest((self as XCTestCase.Type).init(selector: selector))
        }
        return suite
    }

    private func failureIssue(_ message: String, path: String, line: Int) -> XCTIssue {
        let location = XCTSourceCodeLocation(filePath: path, lineNumber: line)
        return XCTIssue(type: .assertionFailure, compactDescription: message,
                        sourceCodeContext: XCTSourceCodeContext(location: location))
    }

    fileprivate func reportFailure(_ message: String, path: String, line: Int) {
        report(failureIssue(message, path: path, line: line))
    }

    func execute(_ scenario: FeatureScenario) {
        currentScenario = scenario
        let table = type(of: self).knownBugs
        // Also validate explicit execute calls, not just dynamic suite discovery.
        if !table.isEmpty {
            do {
                try KnownBugs.validate(table, in: FeatureParser.parse(path: type(of: self).featurePath))
            } catch {
                reportFailure("Cannot validate known-bugs table: \(error)", path: scenario.featurePath, line: scenario.line)
                return
            }
        }
        let registry = StepLibrary()
        registerSteps(registry)
        let entries = table[scenario.name] ?? []
        for step in scenario.steps {
            // Execute outside XCTExpectFailure: direct assertions, asynchronous network issues, and all
            // preconditions remain ordinary. Only the classified output issue is recorded inside its block.
            let failure = FeatureExecution.run(step: step, scenario: scenario, steps: registry)
            guard let entry = entries.first(where: { step.keyword == "Then" && $0.stepText == step.text }),
                  failure.map(entry.matches) ?? true else {
                if let failure {
                    reportFailure(failure.message, path: failure.featurePath, line: failure.line)
                    return
                }
                continue
            }
            let issue = failure.map { failureIssue($0.message, path: $0.featurePath, line: $0.line) }
            let options = XCTExpectedFailure.Options()
            options.isStrict = true
            options.issueMatcher = { candidate in
                guard let issue else { return false }
                return candidate.type == .assertionFailure && candidate.compactDescription == issue.compactDescription
                    && candidate.sourceCodeContext.location == issue.sourceCodeContext.location
            }
            let definition = registry.match(step.text)?.0
            let reason = "\(entry.reason)\n  \(step.keyword) \(step.text) (\(scenario.featurePath):\(step.line))"
                + "\n  (step definition: \(definition?.file ?? "?"):\(definition?.line ?? 0))"
            XCTExpectFailure(reason, options: options) {
                if let issue { self.report(issue) }
            }
            // A matched defect (or a strict unexpected pass) never hides later ordinary assertions.
        }
    }
}
