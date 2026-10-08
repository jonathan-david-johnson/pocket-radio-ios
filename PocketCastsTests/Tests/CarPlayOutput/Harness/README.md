# CarPlay output harness

The harness runs real playback against a loopback fake world and reads the system Now Playing record. Shared specs live in `contracts/features/now_playing/`.

## Enablement and destructive state

The harness is opt-in: `CARPLAY_HARNESS=1` enables destructive tests. Without it, they skip before resetting playback. There is no runtime-target validation gate; choosing the safe destination is the operator's responsibility.

`make test_carplay` supplies `TEST_RUNNER_CARPLAY_HARNESS=1` to Xcode and selects the dedicated **PocketRadio CarPlay Tests** simulator. Use only that signed-out simulator. Never sign it into Pocket Casts or use it for a personal queue. An approved manual check may play real radio while signed out; stop that playback before returning to destructive harness tests.

The device target additionally supplies `TEST_RUNNER_CARPLAY_ON_DEVICE=1`, read in the test process as `CARPLAY_ON_DEVICE=1`. That changes how blocked background account traffic is treated; it is not a destination safety check.

Reset stops playback, closes retained detail controllers, cancels artwork/metadata work, clears local Up Next and display state, and clears the station tracklist/image caches. Actual playback changes the current episode and listening stats. Synthetic podcast rows are removed during teardown. The harness does not restore an arbitrary preexisting queue.

Do not run the device target without explicit approval. The expanded suite has not been device-validated; retained detail tests require signed-out state, and full device runs can change personal playback state.

## Run and select

```sh
make test_carplay
make test_carplay CARPLAY_TESTS='CarPlayArtworkTests CarPlayLifecycleTests'
```

The default selection contains 17 harness self-test classes and five scenario classes:

- `NowPlayingSmokeTests`
- `CarPlayArtworkTests`
- `CarPlayLifecycleTests`
- `CarPlayRaceTests`
- `CarPlayPolicyTests`

The 15 shared scenarios each appear as their own XCTest result. Their generated selectors have the form `scenario_L<line>_<tags>_<name>` and can also be passed as `CARPLAY_TESTS='ClassName/selector'`. Read the current selector from the log because edits to the feature can change its line number. No second “run every scenario” wrapper duplicates them.

Keep the laptop lid open. Caffeinate does not prevent clamshell sleep. Restart the dedicated simulator after host sleep or stalled playback, and check power logs before accepting timing results.

## What runs

- AVPlayer consumes loopback MP3 with scriptable ICY metadata. No playback mock or scenario-time metadata injection.
- Real tracklist/artwork resolution consumes KCRW-shaped tracklists and query-specific iTunes responses.
- Kingfisher downloads uniquely addressed solid-color artwork from the fake server.
- `MPNowPlayingInfoCenter` is observed directly. Color and bundled-logo comparisons are probe assertions, not image stand-ins.
- Feature parsing/step registration and exact known-bug matching have their own self-tests.

This exercises the publisher, not rendered CarPlay UI. In the observed manual simulator setup, CarPlay omits a visible cover and uses background colors instead. Neither cover omission nor approximate gradient colors prove what artwork was published. MP3/ICY fixtures do not cover a real station's HLS/AAC path.

## Fake world and guard

`FakeWorld` owns the stream, tracklist, iTunes, artwork and network guard. One scenario has one guard owner; a second station and local podcast stay under that owner. The app uses its normal cache and download paths.

`NetworkGuard` intercepts URLSession.shared and Kingfisher, records requests, serves exact fixtures and rejects unexpected guarded hosts as ordinary harness failures. AVPlayer bypasses URLProtocol, so every media URL must be loopback. The guard does not cover every app session; do not claim full network hermeticity.

Retained detail scenes have fixtures for their auxiliary requests. Cleanup closes the controller and cancels its work before cache reset. Local podcast fixtures remove their own synthetic database rows.

## Narrow expected failures

Shared feature files contain no known-bug tags. Each iOS class supplies `FeatureTestCase.knownBugs`, keyed by exact unique scenario name.

A `KnownBug` matches one exact Then step and one classified `StepFailure.outputAssertion` diagnostic. The runner opens a strict expected-failure scope only for that output check. A passing marked check fails; wrong identity, readiness, undefined/ambiguous steps, missing input evidence, unexpected requests, reset and teardown remain ordinary failures. Later checks still run rather than disappearing into a whole-scenario expected failure.

The current mappings identify defects 4, 5 and 6: stale metadata/artwork, lifecycle artwork loss and artwork crossing playback identities. Remove the appropriate marker when fixing a defect; do not weaken the output assertion.

## Approved testability hooks

The DEBUG-only `RadioOutputTestHooks` barrier can hold the real initial radio rebuild after preparation. The cached-start scenario proves cache warm-up, callback capture and actual red artwork publication before releasing it. Identity-bound tickets reject stale release; reset cancels without running the continuation. The unarmed DEBUG path is unchanged and Release excludes the hook.

The real CarPlay disconnect callback calls internal `CarPlaySceneDelegate.handleDisconnect()`. Policy tests use that same unchanged cleanup/restoration body. The connection seam models connectivity at the album-publishing boundary, not system scene construction. A separate real-playback check proves restoration from a genuinely published lyric, so an already-correct album cannot hide a broken handler.

These hooks do not fix app artwork, album or stale-callback bugs.

## Evidence limits

Reset waits for its asynchronous image-cache completion and drains queued main callbacks. It cannot prove all unrelated global startup work finished; a dirty startup remains an ordinary error.

Race checks prove old request start, new display identity, delayed response completion, client cache arrival and a post-completion hold. Polling does not intercept every transient write. Ad checks prove socket delivery during the hold, not receiver acknowledgement. Lyric tests bypass retrieval/sync timing but invoke the real publishing boundary.

For the durable decision and rejected shortcuts, see [the CarPlay output test boundary ADR](../../../../../docs/ios/adr/0003-carplay-output-test-boundary.md).

## Maintainer map

| File/area | Purpose |
|---|---|
| `Gherkin/FeatureRunner.swift` | Parsing, registration, per-scenario XCTest discovery, step-scoped failures |
| `Gherkin/KnownBugs.swift` | Platform-local exact known-bug tables |
| `Gherkin/NowPlayingSteps*.swift` | Shared phrases, lifecycle, race and policy operations |
| `FakeWorld/` | Scripted loopback input and request/delivery evidence |
| `Guard/NetworkGuard.swift` | Guarded external services and fixture scope |
| `Probe/` | System display snapshots and artwork comparisons |
| `Reset/` | Opt-in base class and process-state reset |
| `StationDetailHarness.swift` | Retained real controller lifecycle |
| `LocalPodcastFixture.swift` | Synthetic local episode lifecycle |
