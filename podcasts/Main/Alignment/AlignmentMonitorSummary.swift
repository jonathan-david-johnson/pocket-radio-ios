#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// One per 1 s player tick.
struct AlignmentMonitorSample: Equatable {
    let elapsed: TimeInterval
    let mediaSeconds: TimeInterval?
    let programDate: Date?
    let rate: Float
    let isPlaying: Bool
}

/// One per feed poll attempt.
struct AlignmentMonitorPoll: Equatable {
    let elapsed: TimeInterval
    let succeeded: Bool
}

struct SpeedWindow: Equatable {
    let start: TimeInterval
    let mediaSeconds: TimeInterval
    let elapsedSeconds: TimeInterval
    var ratio: Double? { elapsedSeconds > 0 ? mediaSeconds / elapsedSeconds : nil }
}

struct AlignmentMonitorSummary: Equatable {
    /// Speed windows with fewer contributed seconds than this are reported but not judged.
    static let minJudgedWindowSeconds: TimeInterval = 60
    static let sampleGapCandidateThreshold: TimeInterval = 1.5
    /// A stall is logged from status changes, not ticks; gap endpoints may sit this far outside it.
    static let stallTolerance: TimeInterval = 1.5

    let sampleCount: Int
    let pollAttempts: Int
    let pollFailures: Int
    let firstValidClockElapsed: TimeInterval?
    /// Longest inter-sample gap, measured from the first playing sample onward.
    let longestSampleGap: TimeInterval
    /// Every inter-sample interval longer than `sampleGapCandidateThreshold`, from the first playing sample onward.
    let sampleGapsOverLimitCandidates: [ClosedRange<TimeInterval>]
    let longestPollAttemptGap: TimeInterval
    let tailSampleGap: TimeInterval
    let tailPollGap: TimeInterval
    let clockInvalidIntervals: [ClosedRange<TimeInterval>]
    let minRate: Float?
    let maxRate: Float?
    let speedWindows: [SpeedWindow]

    static func compute(samples: [AlignmentMonitorSample], polls: [AlignmentMonitorPoll],
                        endElapsed: TimeInterval, windowLength: TimeInterval = 300) -> AlignmentMonitorSummary {
        func clockInvalidIntervals(_ samples: [AlignmentMonitorSample]) -> [ClosedRange<TimeInterval>] {
            var result: [ClosedRange<TimeInterval>] = []
            var runStart: TimeInterval?
            var runEnd: TimeInterval = 0
            for sample in samples {
                if sample.isPlaying, sample.programDate == nil {
                    if runStart == nil { runStart = sample.elapsed }
                    runEnd = sample.elapsed
                } else if let start = runStart {
                    result.append(start ... runEnd)
                    runStart = nil
                }
            }
            if let start = runStart { result.append(start ... runEnd) }
            return result
        }
        /// Only pairs where both samples are playing, have finite media, and fall in the same bucket contribute.
        /// Windows with no contributing pair are omitted.
        func speedWindows(_ samples: [AlignmentMonitorSample], _ length: TimeInterval) -> [SpeedWindow] {
            guard length > 0 else { return [] }
            var buckets: [Int: (media: TimeInterval, elapsed: TimeInterval)] = [:]
            for (a, b) in zip(samples, samples.dropFirst()) {
                guard a.isPlaying, b.isPlaying, let ma = a.mediaSeconds, let mb = b.mediaSeconds,
                      ma.isFinite, mb.isFinite,
                      b.elapsed - a.elapsed <= sampleGapCandidateThreshold else { continue }
                let bucket = Int((a.elapsed / length).rounded(.down))
                guard bucket == Int((b.elapsed / length).rounded(.down)) else { continue }
                let current = buckets[bucket] ?? (0, 0)
                buckets[bucket] = (current.media + (mb - ma), current.elapsed + (b.elapsed - a.elapsed))
            }
            return buckets.keys.sorted().map {
                SpeedWindow(start: Double($0) * length, mediaSeconds: buckets[$0]!.media, elapsedSeconds: buckets[$0]!.elapsed)
            }
        }
        func longestGap(_ times: [TimeInterval]) -> TimeInterval {
            zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0
        }
        let sampleTimes = samples.map(\.elapsed)
        let postPlayingTimes = samples.firstIndex(where: \.isPlaying).map { Array(sampleTimes[$0...]) } ?? []
        let gapCandidates = zip(postPlayingTimes, postPlayingTimes.dropFirst())
            .filter { $1 - $0 > sampleGapCandidateThreshold }.map { $0 ... $1 }
        let pollTimes = polls.map(\.elapsed)
        let firstValid = samples.first.flatMap { first in
            samples.first { $0.programDate != nil && $0.isPlaying }.map { $0.elapsed - first.elapsed }
        }
        let playingRates = samples.filter(\.isPlaying).map(\.rate)
        return AlignmentMonitorSummary(
            sampleCount: samples.count,
            pollAttempts: polls.count,
            pollFailures: polls.filter { !$0.succeeded }.count,
            firstValidClockElapsed: firstValid,
            longestSampleGap: longestGap(postPlayingTimes),
            sampleGapsOverLimitCandidates: gapCandidates,
            longestPollAttemptGap: longestGap(pollTimes),
            tailSampleGap: sampleTimes.last.map { endElapsed - $0 } ?? 0,
            tailPollGap: pollTimes.last.map { endElapsed - $0 } ?? 0,
            clockInvalidIntervals: clockInvalidIntervals(samples),
            minRate: playingRates.min(),
            maxRate: playingRates.max(),
            speedWindows: speedWindows(samples, windowLength)
        )
    }
}

struct LockedRunVerdict: Equatable {
    let passed: Bool
    let failures: [String]
}

extension AlignmentMonitorSummary {
    func evaluateLockedRun(sessionAliveAtEnd: Bool, audioNeverStopped: Bool,
                           loggedStallIntervals: [ClosedRange<TimeInterval>] = [], clockResyncGrace: TimeInterval = 5,
                           maxSampleGap: TimeInterval = 5, maxPollGap: TimeInterval = 45,
                           minPollAttempts: Int = 58, speedTolerance: Double = 0.01) -> LockedRunVerdict {
        func f1(_ v: TimeInterval) -> String { String(format: "%.1f", v) }
        var failures: [String] = []
        let tol = Self.stallTolerance
        let unexcusedGaps = sampleGapsOverLimitCandidates.filter { gap in
            gap.upperBound - gap.lowerBound > maxSampleGap
                && !loggedStallIntervals.contains { $0.lowerBound - tol <= gap.lowerBound && gap.upperBound <= $0.upperBound + tol }
        }
        if let worst = unexcusedGaps.map({ $0.upperBound - $0.lowerBound }).max() {
            failures.append("longest sample gap \(f1(worst)) s exceeds \(f1(maxSampleGap)) s")
        }
        if tailSampleGap > maxSampleGap {
            failures.append("tail sample gap \(f1(tailSampleGap)) s exceeds \(f1(maxSampleGap)) s")
        }
        if longestPollAttemptGap > maxPollGap {
            failures.append("longest poll attempt gap \(f1(longestPollAttemptGap)) s exceeds \(f1(maxPollGap)) s")
        }
        if tailPollGap > maxPollGap {
            failures.append("tail poll gap \(f1(tailPollGap)) s exceeds \(f1(maxPollGap)) s")
        }
        if pollAttempts < minPollAttempts {
            failures.append("poll attempts \(pollAttempts) below \(minPollAttempts)")
        }
        for interval in clockInvalidIntervals {
            let short = interval.upperBound - interval.lowerBound <= clockResyncGrace
            let excused = short && loggedStallIntervals.contains {
                let delta = interval.lowerBound - $0.upperBound
                return delta >= 0 && delta <= clockResyncGrace
            }
            if !excused {
                failures.append("clock invalid \(f1(interval.lowerBound))-\(f1(interval.upperBound)) s not explained by a logged stall")
            }
        }
        if !sessionAliveAtEnd { failures.append("session not alive at end") }
        if !audioNeverStopped { failures.append("audio stopped during the run") }
        for window in speedWindows where window.elapsedSeconds >= Self.minJudgedWindowSeconds {
            if let ratio = window.ratio, abs(ratio - 1) > speedTolerance {
                failures.append("speed window at \(Int(window.start)) s ratio \(String(format: "%.3f", ratio)) outside 1.000 ± \(String(format: "%.3f", speedTolerance))")
            }
        }
        if let minRate, let maxRate {
            if minRate != 1 || maxRate != 1 {
                failures.append("rate range \(String(format: "%.2f", minRate))-\(String(format: "%.2f", maxRate)) is not exactly 1.0")
            }
        } else {
            failures.append("no playing samples to check rate")
        }
        return LockedRunVerdict(passed: failures.isEmpty, failures: failures)
    }

    /// Plain `[align] summary` lines for the stop-time log. No URLs.
    func formattedLines() -> [String] {
        func f1(_ v: TimeInterval) -> String { String(format: "%.1f", v) }
        func rate(_ v: Float?) -> String { v.map { String(format: "%.2f", $0) } ?? "none" }
        let first = firstValidClockElapsed.map(f1) ?? "none"
        var lines = ["[align] summary samples=\(sampleCount) polls=\(pollAttempts) pollFailures=\(pollFailures) firstClock=\(first) "
            + "sampleGapMax=\(f1(longestSampleGap)) pollGapMax=\(f1(longestPollAttemptGap)) "
            + "tailSampleGap=\(f1(tailSampleGap)) tailPollGap=\(f1(tailPollGap)) rate=\(rate(minRate))-\(rate(maxRate))"]
        let invalid = clockInvalidIntervals.map { "\(f1($0.lowerBound))-\(f1($0.upperBound))" }.joined(separator: ",")
        lines.append("[align] summary clockInvalid=\(invalid.isEmpty ? "none" : invalid)")
        for window in speedWindows {
            let ratio = window.ratio.map { String(format: "%.3f", $0) } ?? "none"
            lines.append("[align] summary window start=\(Int(window.start)) media=\(f1(window.mediaSeconds)) "
                + "elapsed=\(f1(window.elapsedSeconds)) ratio=\(ratio)")
        }
        return lines
    }
}
#endif
