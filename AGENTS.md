## Project context

This is **PocketRadio**, a personal fork of `Automattic/pocket-casts-ios` maintained by Jonathan David Johnson. The fork adds internet radio streaming (radio-browser.info) and other "spoken / streamed audio" features on top of the upstream podcast app. See `README.md` for the human-facing summary.

Milestone planning documents live at `../docs/ios/current_milestone.md` and `../docs/ios/milestones/milestone_N.md`. Always check `../docs/ios/current_milestone.md` when picking up work — it is the source of truth for the active task.

**Symlink convention:** `../docs/ios/current_milestone.md` is always a symlink to the active milestone file (e.g. `milestones/milestone_8.md`). To start a new milestone, create `milestones/milestone_N.M.md` and repoint the symlink — do NOT write the new plan through `current_milestone.md`, that overwrites the previous milestone's archive. Use `/new-milestone <N>` to do this safely.

**`CLAUDE.md` convention:** `CLAUDE.md` is a plain file containing the single line `@AGENTS.md` — never more. Put all real content here in `AGENTS.md`.

## Simulator and bundle reference

| Item | Value |
|------|-------|
| Default sim — "iPhone 17 Pro - No Watch" UDID | `F0042A02-0973-4694-B267-49A1CC21FE19` |
| Staging bundle id | `com.jdj.pocketradio` — what the app actually installs and launches as. Do NOT grep `simctl listapps` for `au.com.shiftyjelly.podcasts`; that is upstream's id and returns a false "not installed" |
| Staging scheme | `"Pocket Casts Staging"` |
| Staging configuration | `StagingDebug` |
| Bundle id root xcconfig | `config/PocketCasts.base.xcconfig` (`PRODUCT_BUNDLE_IDENTIFIER_ROOT`) |

Build/run helpers on the pinned sim:
- `make build_sim` — build StagingDebug for the sim UDID above
- `make run_sim` — build, boot Simulator.app, install, and launch the app
- `SIM_UDID=...` overrides the default sim

On the pinned physical device ("Jonathan iPhone", UDID
`8119F0C0-0772-5040-93CA-A592AC45C465`, signed with team `X6DVXL53Z3`):
- `make build_device` — build StagingDebug for that device
- `make run_device` — build, install, and launch on it
- `xcrun devicectl list devices` to confirm it is paired and available

Reach for the device, not the sim, whenever the thing under test is a gesture,
haptics, or real account state.

## Committing

**Never commit without explicit user approval after manual testing.** Build + tests passing is not sufficient — always stop and ask the user to test the feature before creating any commit.

## Formatting

Format all code using the linter formatter:
```bash
make format
```

## Building and Running

```bash
make build_staging
```

## Cleaning Build Artifacts

```bash
make clean
```

## Running Tests

```bash
make test_staging
```

### Running a Single Test

```bash
make test_staging ONLY_TESTING=PocketCastsTests/YourTestClass/testMethodName
```

### Test file layout

Unit tests live under `PocketCastsTests/Tests/<Feature>/<ClassName>Tests.swift`. The `PocketCastsTests` target uses an Xcode `PBXFileSystemSynchronizedRootGroup`, so **new test files placed under `PocketCastsTests/Tests/` are picked up automatically** — no `project.pbxproj` edit is required. `podcasts/Main/` is a synchronized root group too, so files added under it are registered automatically — M12 added eleven with zero `project.pbxproj` edits. Elsewhere under `podcasts/` registration is still required; mirror an existing peer (e.g. `StreamsHostViewController.swift`). Prefer placing new files under an already-synchronized directory rather than editing the pbxproj, which conflicts easily.

Test pattern: `XCTest` + `@testable import podcasts`, instantiate the view controller, call `loadViewIfNeeded()`, assert on resulting state. See `PocketCastsTests/Tests/Discover/CategoryPodcastsViewControllerTests.swift` as a representative example.

**The test host is the app.** `UserDefaults.standard` inside a test is the app's
own preferences on the simulator running the suite, and `ServerSettings` reflects
whoever is signed in there. So a test that writes or clears a real defaults key
destroys that simulator's app state, and a test that asserts on sign-in state
passes or fails depending on the machine. Both have happened: see
`docs/ios/bugs/bug_1.md` and `docs/ios/bugs/bug_2.md`. Build tests against an
injected `UserDefaults(suiteName:)` and an injected user lookup, never the
ambient ones. `PocketCastsTests/Tests/Main/TabLayoutStoreTests.swift` is the
model to copy.

### Running Module Tests

```bash
# DataModel module tests
make test_staging ONLY_TESTING=PocketCastsDataModelTests

# Server module tests
make test_staging ONLY_TESTING=PocketCastsServerTests

# Utils module tests
make test_staging ONLY_TESTING=PocketCastsUtilsTests
```

## Architecture

### Modular Structure

The codebase uses Swift Package Manager modules under `Modules/`:

- **DataModel** (`Modules/DataModel/`) - Core data persistence using GRDB. Contains podcast, episode, and playback models. Uses custom GRDB macros for model generation.
- **Server** (`Modules/Server/`) - API communication layer using Protocol Buffers. Depends on DataModel and Utils.
- **Utils** (`Modules/Utils/`) - Shared utilities including localization helpers.
- **DependencyInjection** (`Modules/DependencyInjection/`) - DI container for the app.

### Main App Structure

The main iOS app lives in `podcasts/` with:
- UIKit + SwiftUI hybrid (123+ ViewControllers, XIBs/Storyboards)
- Feature-based organization (Analytics, Bookmarks, Folders, IAP, Player, etc.)
- Multi-platform targets: iOS, watchOS, widgets, App Clip, CarPlay

### Key Directories

| Directory | Purpose |
|-----------|---------|
| `podcasts/` | Main iOS app source |
| `PocketCastsTests/` | Unit tests organized by feature |
| `Pocket Casts Watch App/` | watchOS companion |
| `WidgetExtension/` | Home screen widgets |
| `BuildTools/` | SwiftLint and SwiftGen plugins |

## Data Access - DataManager (Singleton Facade)

All data operations go through `DataManager.sharedManager`:

```swift
// Located at: Modules/DataModel/Sources/PocketCastsDataModel/Public/DataManager.swift
let dataManager = DataManager.sharedManager

// Podcast operations
let podcasts = dataManager.allPodcasts(includeUnsubscribed: false)
let podcast = dataManager.findPodcast(uuid: "...")
dataManager.save(podcast: podcast)

// Episode operations
let episode = dataManager.findEpisode(uuid: "...")
dataManager.save(episode: episode)
let downloadedCount = dataManager.downloadedEpisodeCount()

// Playlist/Filter operations
let playlists = dataManager.allPlaylists(includeDeleted: false)
let episodes = dataManager.playlistEpisodes(for: playlist)

// Up Next queue
let queue = dataManager.allUpNextEpisodes()

// Folder operations
let folders = dataManager.allFolders(includeDeleted: false)
let podcastsInFolder = dataManager.allPodcastsInFolder(folder: folder)
```

## Localization

Strings are managed via SwiftGen. Add new strings to `podcasts/en.lproj/Localizable.strings`:

```swift
/* Description for translators with placeholder info */
"feature_description_key" = "Value with %1$@ placeholder";
```

Use generated `L10n` enum:
```swift
let text = L10n.featureDescriptionKey(value)
```

Key rules:
- Use snake_case keys with pattern: `feature_relevantIdentifier_description`
- Always include comment describing context and placeholders
- Use positional specifiers (`%1$@`, `%2$@`), never string interpolation
- Handle plurals manually with separate `_singular`/`_plural` keys

## Code Style

SwiftLint is configured with opt-in rules. Notable custom rules:
- Use `naturalContentHorizontalAlignment` instead of `.left`/`.right` for RTL support
- Use `.natural` text alignment instead of `.left`
- Never use `LocalizedStringKey` in SwiftUI - use `NSLocalizedString` with L10n

## Themes
- When styling Views, use `@EnvironmentObject private var theme: Theme` and inject `.environmentObject(Theme.sharedTheme)` where the View is used.
- **SwiftUI:** `AppTheme.color(for: .primaryText01, theme: theme)` → returns SwiftUI `Color`.
- **UIKit:** `AppTheme.colorForStyle(.primaryText01, themeOverride: ...)` → returns `UIColor`. Do NOT call the SwiftUI signature from UIKit code; the types won't bridge.

## In-repo patterns (use before reinventing)

| Need | Established pattern | Reference file |
|------|---------------------|----------------|
| Segmented container row above content (3+ segments, each child keeps own nav controller) | `UISegmentedControl` + `containerView` + `showChild(_:)` swapping `UINavigationController`-wrapped children | `podcasts/Radio/StreamsHostViewController.swift` |
| Two-segment header in the nav bar itself (single nav bar, no extra row) | `SegmentedTitleView` as `navigationItem.titleView`; children added directly (no inner nav controller); children's bar buttons routed via `effectiveNavigationItem` extension | `podcasts/PlaylistsHostViewController.swift`, `podcasts/SegmentedTitleView.swift`, `podcasts/Common Components/View Controllers/UIViewController+EffectiveNavigationItem.swift` |
| Top-level tabs | `MainTabBarController` `Tab` enum + `pcTabs` array | `podcasts/Main/MainTabBarController.swift` |

When adding a similar UI pattern, mirror the established one rather than introducing a new style.

## Reference sweeps before refactors

When removing or renaming a widely-referenced symbol (an enum case in `Tab`, a public function name, a UserDefaults key, etc.), perform a **reference sweep** before declaring the file list complete:

```bash
grep -rn "Tab\.upNext\|case upNext\b" podcasts/ Modules/ PocketCastsTests/
```

Common stragglers when changing `Tab` enum cases specifically:
- `podcasts/AnalyticsHelper.swift` — `tabSelected(tab:)` switch
- `podcasts/Analytics/AnalyticsEvent.swift` — enum cases like `upNextTabOpened`
- `podcasts/Main/MainTabBarController+shortcuts.swift` — keyboard shortcut handlers
- `podcasts/Main/NavigationManager.swift` — navigation dispatch

List every hit in the plan and address it as part of the same change set. A build that succeeds in one target may still fail in another configuration, so confirm with `make build_staging` after the sweep.

## UserDefaults migrations

When changing the semantics of a stored value (e.g., remapping `lastTabOpened` after a tab is removed), the migration **must be idempotent**:

1. Define a one-shot flag key in `Constants.UserDefaults` named for the migration (e.g., `lastTabOpenedMigratedM5`).
2. Read the flag at the migration site. If set, skip.
3. Perform the remap. Write the new value back.
4. Set the flag.

Include the flag key and gating condition explicitly in the milestone plan — do not leave the choice to the implementing agent.

## Gestures that animate and then revert

When a drag, swipe or reorder tracks the finger correctly and then snaps back on
release, **prove the callback fires before reasoning about what it received.**
Add a temporary `NSLog` in the handler, install to the pinned sim, and read it
back:

```bash
xcrun simctl spawn $SIM_UDID log show --last 15m --style compact \
  --predicate 'eventMessage CONTAINS "YOURTAG"'
```

Silence means the gesture never reached your code and no argument handling can
fix it. This is not a rare case in SwiftUI: a `.moveDisabled` row in a `List` is
not a legal *drop target* either, and UIKit refuses any reorder whose final index
is the one that row occupies — so `onMove` is never called for drops beside it.
That cost a long detour into index arithmetic on a screen whose indices were
already correct. Full write-up in `docs/ios/bugs/bug_1.md`.

## SourceKit diagnostic caveat

After adding new Swift files or editing across module boundaries, SourceKit (the IDE language service) may emit transient "No such module 'UIKit'", "No such module 'XCTest'", or "No such module 'PocketCastsDataModel'" errors. These are **stale-index artifacts**, not real build failures.

**Always trust the result of `make build_staging` / `make test_staging` over a SourceKit-only diagnostic.** Re-running the build typically refreshes the index. Do not chase imports based on these warnings alone.

## Widget extension bundle isolation

The `WidgetExtension/` target has its own bundle and its own asset catalog at `WidgetExtension/Assets.xcassets`. Code in the widget extension **cannot** read images from `podcasts/CommonImages.xcassets` (or any other catalog in the main app's bundle) via `UIImage(named:)` — those resources don't exist in the widget binary.

When a widget needs a bundled image used elsewhere in the app (e.g. a curated station logo), copy the imageset into `WidgetExtension/Assets.xcassets`. The catalog is auto-included in the widget target.

## App Group ID — single source of truth

The shared App Group ID must match across:
- `podcasts/SharedConstants.swift` → `SharedConstants.GroupUserDefaults.groupContainerId`
- `podcasts/WidgetHelper.swift` → `WidgetHelper.appGroupId`
- `WidgetExtension/Common/CommonWidgetHelper.swift` → `CommonWidgetHelper.appGroupId`
- every `*.entitlements` file (`podcasts/`, `WidgetExtension/`, `Share Extension/`, etc.)

The PocketRadio fork value is `group.com.jdj.pocketradio`. Read from the `SharedConstants` constant; never hardcode the literal in helper files. A mismatch silently breaks every widget — `UserDefaults(suiteName:)` returns a defaults object that reads nil and writes no-ops, with no error surfaced.

## Interactive widget intents — explicit widget refresh

`AudioPlaybackIntent.perform()` (e.g. `PlayEpisodeIntent`, `PlayRadioStationIntent`) runs in the main app process when invoked from a widget tap, but the `NotificationCenter` observers in `WidgetHelper` can fire too late for `WidgetCenter`'s next timeline sample. Result: the widget face shows stale state for several seconds.

Always end the intent's `perform()` body with `WidgetHelper.shared.republishAllPocketRadioState()` (or the equivalent for the widget kind). This forces a fresh App Group write + `reloadAllTimelines()` before the closure returns.

## PlaybackManager.load() — outgoing item preservation

Upstream Pocket Casts gates the "push outgoing to Up Next" path on `queue.upNextCount() > 0`. That count excludes the currently-playing slot, so a single-podcast session (or any post-`switchTo` path where the radio shim was just removed) reads as `0`, and `overrideAllEpisodesWith(episode:)` then calls `queue.remove(episode: previousEpisode, ...)` under `FeatureFlag.avoidReplaceOnEpisodeSwap`. The outgoing item is dropped from the queue entirely — to the user this looks like the previous podcast was "marked played" rather than pushed down.

PocketRadio patches `PlaybackManager.load(...)` so:
- The outer guard goes through `switchTo(...)` whenever the episode is changing (no `upNextCount() > 0` requirement).
- The branch decision uses `pushNewCurrentlyPlaying` whenever `currentEpisode() != nil` (override only when explicitly requested or when nothing is playing).
- When the outgoing episode is a `RadioStation`, `switchTo` is called with `moveExistingToUpNext: false` so radio shims never accumulate in Up Next.

If you change `load()`, preserve all three behaviors.

## Protocol Buffers

Server objects use protobuf. To regenerate after API changes:
```bash
brew install protobuf swift-protobuf  # One-time setup
make update_proto API_PATH=/path/to/pocketcasts-api/api/modules/protobuf/src/main/proto
```
