/// iOS-only output markers. Each real entry requires an unmarked baseline and recorded bug evidence.
/// The table key is the exact, stable scenario name; line-based XCTest selectors are never keys.
struct KnownBug {
    let bugID: String
    let symptom: String
    /// Exact text of one unique Then (or inherited Then/And/But) output step.
    let stepText: String
    /// Exact stable diagnostic emitted by StepFailure.outputAssertion, not a message substring or regex.
    let assertionDiagnostic: String

    var reason: String { "\(bugID) — \(symptom): \(assertionDiagnostic)" }

    func matches(_ failure: FeatureFailure) -> Bool {
        failure.kind == .stepFailed && failure.keyword == "Then" && failure.stepText == stepText
            && failure.outputAssertionDiagnostic == assertionDiagnostic
    }
}

enum KnownBugs {
    typealias Table = [String: [KnownBug]]

    /// Tables are scoped to their corresponding shared feature; no feature tags carry iOS defects.
    /// Only evidenced, platform-local output checks are expected.
    /// See docs/ios/adr/0003-carplay-output-test-boundary.md for matching policy.
    static let artwork: Table = [
        "A second song without station detail does not keep the previous artwork": [
            KnownBug(bugID: "bug_4", symptom: "closed detail retains previous song artwork",
                     stepText: "the display shows the station logo", assertionDiagnostic: "display.artwork.station-logo")
        ],
        "A tracklist one song behind lends neither its album nor its artwork": [
            KnownBug(bugID: "bug_4", symptom: "stale feed lends the previous album",
                     stepText: "the display does not show the album \"Album A\"", assertionDiagnostic: "display.album.not-equal"),
            KnownBug(bugID: "bug_4", symptom: "stale feed retains previous artwork after the album check",
                     stepText: "the display shows the station logo", assertionDiagnostic: "display.artwork.station-logo")
        ]
    ]

    static let lifecycle: Table = [
        "Pausing and resuming keeps the current song's artwork": [
            KnownBug(bugID: "bug_5", symptom: "A: pause/resume rebuild loses resolved artwork",
                     stepText: "the rebuilt display shows the title \"Song A\" with red artwork", assertionDiagnostic: "display.title-artwork.artwork")
        ],
        "A cached tracklist at playback start keeps the artwork": [
            KnownBug(bugID: "bug_5", symptom: "B: released initial rebuild loses already-published artwork",
                     stepText: "the display shows the title \"Song A\" with red artwork", assertionDiagnostic: "display.title-artwork.artwork"),
            KnownBug(bugID: "bug_5", symptom: "B: same announced title still lacks resolved artwork during the hold",
                     stepText: "the display keeps red artwork for 2 seconds", assertionDiagnostic: "display.sustained-artwork.artwork")
        ],
        "Stopping and replaying the same song resolves its artwork again": [
            KnownBug(bugID: "bug_5", symptom: "C: replay retains dedupe key but loses artwork",
                     stepText: "the rebuilt display shows the title \"Song A\" with red artwork", assertionDiagnostic: "display.title-artwork.artwork")
        ]
    ]

    static let races: Table = [
        "Switching stations prevents the old station's artwork from publishing": [
            KnownBug(bugID: "bug_6", symptom: "late artwork crosses station identity",
                     stepText: "the display never shows red artwork until the request for \"Song A\" completes", assertionDiagnostic: "display.race.no-red-artwork")
        ],
        "Switching to a podcast prevents radio artwork from publishing over it": [
            KnownBug(bugID: "bug_6", symptom: "late radio artwork crosses podcast identity",
                     stepText: "the display never shows red artwork until the request for \"Song A\" completes", assertionDiagnostic: "display.race.no-red-artwork")
        ]
    ]

    /// Validate the whole feature, even when only one generated XCTest selector is selected.
    /// Unmarked features retain the original runner's duplicate-title/line-selector behavior.
    static func validate(_ table: Table, in feature: FeatureFile) throws {
        guard !table.isEmpty else { return }
        let grouped = Dictionary(grouping: feature.scenarios, by: \.name)
        if let duplicate = grouped.keys.sorted().first(where: { grouped[$0]!.count > 1 }) {
            throw StepFailure(message: "Invalid known-bugs table: duplicate scenario name '\(duplicate)'")
        }
        for name in table.keys.sorted() {
            guard let scenario = grouped[name]?.first else {
                throw StepFailure(message: "Invalid known-bugs table: stale scenario name '\(name)'")
            }
            let entries = table[name]!
            guard !entries.isEmpty else {
                throw StepFailure(message: "Invalid known-bugs table: no output checks for '\(name)'")
            }
            var designated = Set<String>()
            for entry in entries {
                guard !entry.bugID.isEmpty, !entry.symptom.isEmpty, !entry.assertionDiagnostic.isEmpty,
                      !entry.stepText.isEmpty else {
                    throw StepFailure(message: "Invalid known-bugs table: missing bug/symptom/step/diagnostic for '\(name)'")
                }
                guard designated.insert(entry.stepText).inserted else {
                    throw StepFailure(message: "Invalid known-bugs table: duplicate output marker '\(entry.stepText)' in '\(name)'")
                }
                let steps = scenario.steps.filter { $0.keyword == "Then" && $0.text == entry.stepText }
                guard steps.count == 1 else {
                    throw StepFailure(message: "Invalid known-bugs table: expected exactly one Then '\(entry.stepText)' in '\(name)', found \(steps.count)")
                }
            }
        }
    }
}
