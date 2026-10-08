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

## Manual CarPlay check on this Mac

Use the normal app, without harness enablement, on the same signed-out simulator. Manual playback does not replace the automated publication checks. Leave Wi-Fi unchanged; disabling it is not an acceptance requirement.

Xcode 27 on this Mac provides **Device Hub**, not the legacy `Simulator.app`. `make run_sim` still fails at its `open -a Simulator` step even when the build succeeds. Use the Simulator included in the separately downloaded Xcode 26.5 at `~/Downloads/Xcode.app`. Do not change the active `xcode-select` setting.

1. From the iOS checkout, build the normal app with the active toolchain:

   ```sh
   SIM_UDID=6565636E-BB8D-4C34-A9EB-56F2BB638400
   make build_sim SIM_UDID="$SIM_UDID"
   ```

2. Quit Device Hub. If it asks, choose **Quit and Keep Simulators Running**. Open the legacy Simulator with its own developer directory:

   ```sh
   open --env "DEVELOPER_DIR=$HOME/Downloads/Xcode.app/Contents/Developer" \
     "$HOME/Downloads/Xcode.app/Contents/Developer/Applications/Simulator.app" \
     --args -CurrentDeviceUDID "$SIM_UDID"
   ```

3. Verify that Home and taps work. If input is unresponsive, quitting Device Hub alone is not enough: quit the legacy Simulator, restart only the dedicated device, and reopen the GUI with the command above. Do not erase it or shut down unrelated simulators.

   ```sh
   DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer" \
     xcrun simctl shutdown "$SIM_UDID"
   DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer" \
     xcrun simctl bootstatus "$SIM_UDID" -b
   ```

   If shutdown reports that the device is already shut down, proceed to boot. Verify Home input again before opening CarPlay. This recovery worked on this Mac; it does not establish which frontend caused the input failure.

4. Always install the app built in step 1 before collecting new evidence; `build_sim` does not update an existing installation. Locate that app, install it, and launch normally:

   ```sh
   APP_PATH=$(xcodebuild -project podcasts.xcodeproj \
     -scheme 'Pocket Casts Staging' -configuration StagingDebug \
     -destination "platform=iOS Simulator,id=$SIM_UDID" \
     -showBuildSettings -json 2>/dev/null | python3 -c '
   import json, sys
   settings = next(t["buildSettings"] for t in json.load(sys.stdin) if t["target"] == "podcasts")
   print(settings["TARGET_BUILD_DIR"] + "/" + settings["FULL_PRODUCT_NAME"])
   ')
   xcrun simctl install "$SIM_UDID" "$APP_PATH"
   xcrun simctl launch "$SIM_UDID" com.jdj.pocketradio
   ```

   Do not set `CARPLAY_HARNESS`, `TEST_RUNNER_CARPLAY_HARNESS`, or their `SIMCTL_CHILD_` variants for this launch.

5. In the legacy Simulator, choose **I/O → External Displays → CarPlay**. Verify Home input still works, play KCRW Eclectic 24, and observe at least three song transitions. Compare audible transitions, phone title/artwork, CarPlay title/artist/third line, LIVE, and transport controls. Record discrepancies rather than treating the manual run as an all-policy pass. This simulator may show artwork-derived gradients without a visible cover; exact published artwork must still be checked through the Now Playing probe.

Stop real-radio playback before the next destructive harness run. Keep lyric timing and retrieval investigation separate from CarPlay publication policy.

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

The original 43-test harness checkpoint was accepted after two clean physical-device runs on 2026-10-07, replacing the rejected Wi-Fi-off check. Those runs do not validate the expanded 128-test suite on device or prove offline operation. On the signed-in phone, the guard blocked observed favorites-sync and Up Next-sync requests; device mode tolerated those blocked requests. Whether a later ordinary app sync restored the cleared local Up Next was not checked. Do not infer that every network stack or later sync is covered.

Template button state was readable without constructing a CarPlay scene in the initial experiment. Favourite/mute output-suite coverage remains deferred; pure button tests are not full scene-lifecycle verification.

Reset waits for its asynchronous image-cache completion and drains queued main callbacks. It cannot prove all unrelated global startup work finished; a dirty startup remains an ordinary error.

Race checks prove old request start, new display identity, delayed response completion, client cache arrival and a post-completion hold. Polling does not intercept every transient write. Ad checks prove socket delivery during the hold, not receiver acknowledgement. Lyric tests bypass retrieval/sync timing but invoke the real publishing boundary.

For the durable decision and rejected shortcuts, see [the CarPlay output test boundary ADR](../../../../../docs/ios/adr/0003-carplay-output-test-boundary.md).

## Harness coverage map

| Behavior | Maintained test |
|---|---|
| ICY block offsets and title changes | `IcyStreamServerTests.testIcyFramingAndTitleChange` |
| Fake tracklist and real parser agree | `FakeWorldTests.testTracklistContractParsesScriptedEntriesAndSkipsBreak` |
| Tracklist/iTunes requests reach fixtures | `FakeWorldTests.testTracklistAndITunesRequestsAreServedByTheFake` |
| Unexpected guarded hosts are blocked | `FakeWorldTests.testUnknownHostIsBlockedFromURLSessionAndKingfisher` |
| Scenario order does not contaminate output | `ResetTests.test_orderIndependence_XY_YX_XX_YY` |
| Artwork color and absence readback | `NowPlayingProbeTests.testArtworkColoursReadBack`, `testNoArtworkIsNil` |
| Timeout includes the last snapshot and diff | `NowPlayingProbeTests.testWaitUntilTimesOutWithLastSnapshotAndDiff` |
| Real-playback smoke contract | `NowPlayingSmokeTests`, loading `smoke.feature` |
| Undefined steps report their feature location | `FeatureRunnerTests.testUndefinedStepEndToEndReportsAtFeatureLine` |

The five scenario classes listed above retain the output contracts. `ExpectedFailureTests` and `KnownBugMappingTests` check strict failure classification and exact mappings; `ScenarioRegistrationTests` checks individual discovery. Manual rendering and scene-connectivity verification remain separate.

## Maintainer map

| File/area | Purpose |
|---|---|
| `Gherkin/FeatureRunner.swift` | Parsing, runtime Objective-C registration, per-scenario XCTest discovery, step-scoped failures. Recheck discovery and single-scenario selection after XCTest/Xcode upgrades. |
| `Gherkin/KnownBugs.swift` | Platform-local exact known-bug tables |
| `Gherkin/NowPlayingSteps*.swift` | Shared phrases, lifecycle, race and policy operations |
| `FakeWorld/` | Scripted loopback input and request/delivery evidence |
| `Guard/NetworkGuard.swift` | Guarded external services and fixture scope |
| `Probe/` | System display snapshots and artwork comparisons |
| `Reset/` | Opt-in base class and process-state reset |
| `StationDetailHarness.swift` | Retained real controller lifecycle |
| `LocalPodcastFixture.swift` | Synthetic local episode lifecycle |
