BUNDLE=rbenv exec bundle
LANG_VAR=LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
FASTLANE=$(LANG_VAR) $(BUNDLE) exec fastlane
# Explicit --config prevents SwiftLint from picking up nested configs in
# BuildTools/.build/checkouts/ (e.g., SwiftGenPlugin's .swiftlint.yml).
SWIFTLINT_FROM_BUILDTOOLS=swiftlint lint --working-directory .. --config .swiftlint.yml --quiet
# Parse the human-readable output of simctl
SIMULATOR_NAME = $(shell xcrun simctl list devices available \
	| grep "iPhone" \
	| tail -1 | sed 's/^[[:space:]]*//' | sed 's/ *(.*) *$$//')

SIM_UDID = F0042A02-0973-4694-B267-49A1CC21FE19
SIM_BUNDLE_ID = com.jdj.pocketradio

# Dedicated, signed-out simulator for the CarPlay output harness (M13.1). Never sign in on it.
# Looked up by name so any machine can use it; `make carplay_sim` creates it.
CARPLAY_SIM_NAME = PocketRadio CarPlay Tests
CARPLAY_SIM_UDID = $(shell xcrun simctl list devices | grep -F "$(CARPLAY_SIM_NAME)" | head -1 \
	| grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')
CARPLAY_SIM_DEVICE_TYPE ?= com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
CARPLAY_SIM_RUNTIME ?= com.apple.CoreSimulator.SimRuntime.iOS-26-5
# Harness self-tests plus all shared output scenarios. Override to select a class or scenario.
CARPLAY_HARNESS_TESTS = IcyStreamServerTests FakeWorldTests NowPlayingProbeTests FeatureRunnerTests \
	ResetTests NowPlayingSmokeFaultTests ExpectedFailureTests NowPlayingStepsTests \
	ArtworkFixtureQueryTests StationDetailHarnessTests WireAlbumStepsTests LifecycleStepsTests \
	RaceFixtureTests PolicyStepsTests RadioOutputTestHooksTests ScenarioRegistrationTests KnownBugMappingTests
CARPLAY_SCENARIO_TESTS = NowPlayingSmokeTests CarPlayArtworkTests CarPlayLifecycleTests CarPlayRaceTests CarPlayPolicyTests
CARPLAY_TESTS ?= $(CARPLAY_HARNESS_TESTS) $(CARPLAY_SCENARIO_TESTS)

# Install on a physical device, signed with the paid Apple Developer Program team
# (X6DVXL53Z3, Individual). The paid team is required for the CarPlay Audio
# entitlement in podcasts/podcasts*.entitlements — a free personal team cannot
# provision com.apple.developer.carplay-audio.
DEVICE_UDID = 8119F0C0-0772-5040-93CA-A592AC45C465
DEVICE_TEAM_ID = X6DVXL53Z3
DEVICE_BUNDLE_ID_ROOT = com.jdj.pocketradio
DEVICE_BUNDLE_ID = $(DEVICE_BUNDLE_ID_ROOT)

.PHONY: help build clean test lint lint_lenient format install_dependencies build_sim run_sim launch_sim build_device run_device carplay_sim test_carplay test_carplay_device

define run_in_buildtools
	@pushd BuildTools && \
	export SDKROOT=$$(xcrun --sdk macosx --show-sdk-path) && \
	swift package plugin \
		--allow-writing-to-directory .. \
		--allow-writing-to-package-directory \
		$(1) && \
	popd
endef

help: ## Show this list of commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

swift_percentage: ## Swift and Obj-C percentage on the project
	./scripts/count.rb

generate_colors: ## Generate colors and themes based on themes.csv
	ruby scripts/themes/generate_themes.rb scripts/themes/theme.csv

generate_code:
	$(call run_in_buildtools,generate-code-for-resources --config ../swiftgen.yml)

lint: ## Lint the codebase
	$(call run_in_buildtools,$(SWIFTLINT_FROM_BUILDTOOLS))

lint_lenient:
	$(call run_in_buildtools,$(SWIFTLINT_FROM_BUILDTOOLS) --lenient)

build: ## Builds the Debug configuration using Xcode
	xcodebuild -project podcasts.xcodeproj \
       -scheme pocketcasts \
       -configuration Debug \
       -destination 'generic/platform=iOS Simulator' \
       build

clean: ## Cleans the build artifacts
	xcodebuild -project podcasts.xcodeproj \
       -scheme pocketcasts \
       -configuration Debug \
       clean

ONLY_TESTING ?= PocketCastsTests

test: ## Build and run the PocketCastsTests target with Unit Tests using Xcode
	xcodebuild test -project podcasts.xcodeproj \
	    -scheme pocketcasts \
        -only-testing:$(ONLY_TESTING) \
        -destination 'platform=iOS Simulator,name=$(SIMULATOR_NAME),OS=latest'

build_staging: ## Builds using the StagingDebug configuration
	xcodebuild -project podcasts.xcodeproj \
       -scheme "Pocket Casts Staging" \
       -configuration StagingDebug \
       -destination 'generic/platform=iOS Simulator' \
       build

test_staging: ## Build and run Unit Tests using the StagingDebug configuration
	xcodebuild test -project podcasts.xcodeproj \
	    -scheme "Pocket Casts Staging" \
        -only-testing:$(ONLY_TESTING) \
        -destination 'platform=iOS Simulator,name=$(SIMULATOR_NAME),OS=latest'

build_sim: ## Build StagingDebug for iPhone 17 Pro - No Watch simulator
	xcodebuild -project podcasts.xcodeproj \
	   -scheme "Pocket Casts Staging" \
	   -configuration StagingDebug \
	   -destination 'platform=iOS Simulator,id=$(SIM_UDID)' \
	   build

launch_sim: ## Boot the target simulator if not already booted
	@xcrun simctl bootstatus $(SIM_UDID) -b >/dev/null 2>&1 || xcrun simctl boot $(SIM_UDID)
	@open -a Simulator --args -CurrentDeviceUDID $(SIM_UDID)

run_sim: build_sim launch_sim ## Build, install, and launch app on iPhone 17 Pro - No Watch
	@APP_PATH=$$(xcodebuild -project podcasts.xcodeproj \
	   -scheme "Pocket Casts Staging" \
	   -configuration StagingDebug \
	   -destination 'platform=iOS Simulator,id=$(SIM_UDID)' \
	   -showBuildSettings 2>/dev/null \
	   | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$$2} / WRAPPER_NAME / {w=$$2} END {print d "/" w}'); \
	echo "Installing $$APP_PATH"; \
	xcrun simctl install $(SIM_UDID) "$$APP_PATH"; \
	xcrun simctl launch $(SIM_UDID) $(SIM_BUNDLE_ID)

carplay_sim: ## Create the dedicated CarPlay test simulator if it is missing
	@if [ -z "$(CARPLAY_SIM_UDID)" ]; then \
	   xcrun simctl create "$(CARPLAY_SIM_NAME)" $(CARPLAY_SIM_DEVICE_TYPE) $(CARPLAY_SIM_RUNTIME); \
	else echo "'$(CARPLAY_SIM_NAME)' already exists: $(CARPLAY_SIM_UDID)"; fi

# TEST_RUNNER_CARPLAY_HARNESS=1 is what lets the harness tests run: they end playback and clear caches, so
# a plain `make test_staging` on a developer simulator skips them.
# caffeinate: real playback uses the Mac's audio device. If the Mac sleeps mid-run, playback fails
# (CoreMediaErrorDomain -66681) and every title wait times out.
test_carplay: ## Run CarPlay harness self-tests and output suite (dedicated simulator, keeps the Mac awake)
	@test -n "$(CARPLAY_SIM_UDID)" || { echo "No '$(CARPLAY_SIM_NAME)' simulator. Run: make carplay_sim"; exit 1; }
	@xcrun simctl bootstatus $(CARPLAY_SIM_UDID) -b >/dev/null 2>&1 || xcrun simctl boot $(CARPLAY_SIM_UDID)
	TEST_RUNNER_CARPLAY_HARNESS=1 caffeinate -dimsu xcodebuild test -project podcasts.xcodeproj \
	   -scheme "Pocket Casts Staging" \
	   -configuration StagingDebug \
	   $(foreach t,$(CARPLAY_TESTS),-only-testing:PocketCastsTests/$(t)) \
	   -destination 'platform=iOS Simulator,id=$(CARPLAY_SIM_UDID)'

# Runs the harness on the connected, unlocked physical device (DEVICE_UDID is the one `make build_device` uses).
# WARNING: the test host is the app, so this runs against that phone's REAL data. Every scenario replaces the
# current episode and clears Up Next, and the clear syncs to the account. Listening stats also change.
# The contract `.feature` files are copied into the test bundle first, because the Mac's paths do not exist on the device.
# xcodebuild destination id for "Jonathan iPhone" (see `xcodebuild -showdestinations`).
CARPLAY_DEVICE_UDID ?= 00008120-0014688C3461A01E
CARPLAY_GENERATED = PocketCastsTests/Tests/CarPlayOutput/HarnessTests/Generated
test_carplay_device: ## Run the CarPlay output harness on the connected device (clears the phone's Up Next!)
	@mkdir -p $(CARPLAY_GENERATED) && cp ../contracts/features/now_playing/*.feature $(CARPLAY_GENERATED)/
	TEST_RUNNER_CARPLAY_HARNESS=1 TEST_RUNNER_CARPLAY_ON_DEVICE=1 caffeinate -dimsu xcodebuild test -project podcasts.xcodeproj \
	   -scheme "Pocket Casts Staging" \
	   -configuration StagingDebug \
	   $(foreach t,$(CARPLAY_TESTS),-only-testing:PocketCastsTests/$(t)) \
	   -destination 'platform=iOS,id=$(CARPLAY_DEVICE_UDID)' \
	   -allowProvisioningUpdates \
	   DEVELOPMENT_TEAM=$(DEVICE_TEAM_ID) \
	   PRODUCT_BUNDLE_IDENTIFIER_ROOT=$(DEVICE_BUNDLE_ID_ROOT)

build_device: ## Build StagingDebug for Jonathan iPhone, signed with personal team
	xcodebuild -project podcasts.xcodeproj \
	   -scheme "Pocket Casts Staging" \
	   -configuration StagingDebug \
	   -destination 'platform=iOS,id=$(DEVICE_UDID)' \
	   -allowProvisioningUpdates \
	   DEVELOPMENT_TEAM=$(DEVICE_TEAM_ID) \
	   PRODUCT_BUNDLE_IDENTIFIER_ROOT=$(DEVICE_BUNDLE_ID_ROOT) \
	   CODE_SIGN_STYLE=Automatic \
	   PROVISIONING_PROFILE_SPECIFIER="" \
	   PROVISIONING_PROFILE="" \
	   build

run_device: build_device ## Build, install, and launch on Jonathan iPhone
	@APP_PATH=$$(xcodebuild -project podcasts.xcodeproj \
	   -scheme "Pocket Casts Staging" \
	   -configuration StagingDebug \
	   -destination 'platform=iOS,id=$(DEVICE_UDID)' \
	   DEVELOPMENT_TEAM=$(DEVICE_TEAM_ID) \
	   PRODUCT_BUNDLE_IDENTIFIER_ROOT=$(DEVICE_BUNDLE_ID_ROOT) \
	   -showBuildSettings 2>/dev/null \
	   | awk -F' = ' '/ BUILT_PRODUCTS_DIR / {d=$$2} / WRAPPER_NAME / {w=$$2} END {print d "/" w}'); \
	echo "Installing $$APP_PATH on $(DEVICE_UDID)"; \
	xcrun devicectl device install app --device $(DEVICE_UDID) "$$APP_PATH"; \
	xcrun devicectl device process launch --device $(DEVICE_UDID) $(DEVICE_BUNDLE_ID)

format: ## Lint and autocorrect linter errors
	$(call run_in_buildtools,$(SWIFTLINT_FROM_BUILDTOOLS) --autocorrect)

upload_dsyms: ## Upload dSYMs
	./scripts/upload-symbols -gsp $(HOME)/.configure/pocketcasts-ios/secrets/GoogleService-Info.plist -p ios ./podcasts.app.dSYM.zip

install_dependencies: ## Install dependencies to run this project
	bundle install

update_proto: ## Generates the protobuffer Swift files
	./scripts/update_proto.sh $(API_PATH)

external_contributor: ## Generates an empty ApiCredentials.swift so the app builds
	@cp podcasts/Credentials/ApiCredentials.tpl podcasts/Credentials/LocalApiCredentials.swift
	@sed -i '' 's/%{.*}//' "podcasts/Credentials/LocalApiCredentials.swift"
	$(info You're ready to build the app, go ahead! 🎙)
