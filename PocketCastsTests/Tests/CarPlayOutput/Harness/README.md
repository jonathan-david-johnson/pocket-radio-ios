# CarPlay output harness

An in-process test harness that plays a **fake radio station** through the **real app code** and reads
what the system Now Playing display (and so CarPlay and the lock screen) would show.

Run it: `make test_carplay` (from `pocket-radio-ios`). The first time, `make carplay_sim` creates the
dedicated simulator `PocketRadio CarPlay Tests`. **Never sign in on that simulator.**

## What is fake, what is real

| Fake (the outside world) | Real (the code under test) |
|---|---|
| A loopback radio stream with ICY titles (`FakeWorld/IcyStreamServer`), a tone as audio | `AVPlayer`, the audio session, playback pacing |
| The KCRW tracklist and iTunes answers, served by a `URLProtocol` (`Guard/NetworkGuard`) | `RadioPlaybackStarter`, `PlaybackManager`, `RadioMetadataObserver` |
| Artwork images from a loopback server (`FakeWorld/ArtworkServer`), one solid colour per song | `RadioTracklistService`, `TrackArtworkResolver`, Kingfisher |
| | `NowPlayingHelper` and the system `MPNowPlayingInfoCenter` |

Time is real. A title change costs about 5.7 s, and starting playback about 3.3 s.

## Parts

| Folder | What it does |
|---|---|
| `FakeWorld/` | `FakeWorld` is the one object a scenario scripts: `play(song)`, `setTracklist`, `setLatency`, `fail`, `dropStream`, `sendAdFrame`, `makeStation`. `make_tone.sh` regenerates the tone fixture. |
| `Guard/` | `NetworkGuard` answers fixture hosts, **blocks and logs every other non-loopback host**, and drops delayed responses that outlive their world. |
| `Probe/` | `NowPlayingProbe` reads the display: title, artist, album, live flag, media type, and the artwork's centre-pixel colour. `waitUntil` and `holds` poll the run loop and fail with the last snapshot and a diff. |
| `Reset/` | `HarnessReset.fullReset()` clears process-wide state between scenarios. `HarnessScenarioCase` calls it around every test. |
| `Gherkin/` | `FeatureRunner` turns `.feature` files into one XCTest per scenario. `NowPlayingSteps` are the iOS step definitions. |

## Add a scenario

1. Write it in `contracts/features/<area>/<name>.feature` (see `contracts/features/README.md`). Reuse existing step phrases.
2. If you need a new phrase, add its definition to `NowPlayingSteps.register(in:)`, or to a new steps class.
3. Add a `FeatureTestCase` subclass whose `featurePath` is `contractsFeature("<area>/<name>.feature")` and whose
   `registerSteps` registers the steps. Each scenario appears as its own test, named `scenario_L<line>_<slug>`.
4. Run one scenario: `make test_carplay CARPLAY_TESTS="NowPlayingSmokeTests/scenario_L12_the_first_song_shows_its_title_artist_album"`.

## Rules the harness depends on

- **Stream URLs must be loopback.** AVPlayer traffic bypasses the network guard. `FakeWorld.makeStation` rejects anything else.
- **The test host is the app.** Never write real `UserDefaults.standard` keys from a test. Playback itself changes
  `StatsListenedTo`, `lastPauseTime` and `lastPausedAt`. That is harmless on the dedicated simulator but real.
- **Device runs are destructive.** `make test_carplay_device` runs against the phone's real install: every scenario
  replaces the current episode and clears Up Next, and playback changes listening stats. The guard blocks the app's
  account and favorites traffic (`api.pocketcasts.com`, `*.supabase.co`) so it is never sent; it is tolerated, not failed.
- **Keep the Mac awake.** `make test_carplay` runs under `caffeinate -dimsu`. If macOS sleeps mid-run, playback fails
  (`CoreMediaErrorDomain -66681`) and every title wait times out.
- **One agent or person on the simulator at a time.**
- **Pass `republishWidgetState: false`** when starting playback, or the run writes App Group widget state.
- **Reset seams** are `#if DEBUG` blocks in `PlaybackManager`, `NowPlayingHelper`, `TrackArtworkResolver` and
  `RadioTracklistService`. They are inert unless called. Keep them small: two of the files come from upstream.

## What the harness cannot prove

- HLS and AAC streams. The fake station is MP3 over ICY. KCRW's real stream is HLS.
- CarPlay's own rendering, head-unit truncation, Bluetooth. The harness reads the record CarPlay draws from.
- The full and mini players' own artwork code, lyrics, and ACR fingerprinting.
- Signed-in behavior and account sync.
- A run with Wi-Fi off. Nothing depends on the network, and the guard blocks leaks on `URLSession.shared` and
  Kingfisher, but the offline run is a manual check.
