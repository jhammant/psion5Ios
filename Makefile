SIM ?= iPhone Duo
DERIVED := build
APP_SIM := $(DERIVED)/Build/Products/Debug-iphonesimulator/Psion5.app
APP_DEV := $(DERIVED)/Build/Products/Release-iphoneos/Psion5.app
BUNDLE_ID := io.hammant.psion5

.PHONY: setup project sim device testflight mock-claude clean

## Fetch the emulator files and generate the Xcode project.
setup:
	./scripts/fetch-windemu.sh
	$(MAKE) project

project:
	xcodegen generate

## Build and launch on the iPhone Duo simulator.
sim: project
	xcodebuild -project Psion5.xcodeproj -scheme Psion5 -configuration Debug \
		-destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath $(DERIVED) build
	xcrun simctl boot '$(SIM)' 2>/dev/null || true
	open -a Simulator
	xcrun simctl install '$(SIM)' $(APP_SIM)
	xcrun simctl launch '$(SIM)' $(BUNDLE_ID)

## Build a Release copy and install it on the connected iPhone (DEVICE=<name or UDID> to pick one).
device: project
	xcodebuild -project Psion5.xcodeproj -scheme Psion5 -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath $(DERIVED) -allowProvisioningUpdates build
	xcrun devicectl device install app --device "$${DEVICE:?set DEVICE to your iPhone name or UDID (xcrun devicectl list devices)}" $(APP_DEV)
	xcrun devicectl device process launch --device "$$DEVICE" $(BUNDLE_ID)

## Archive and upload to TestFlight (internal testers only; see scripts/testflight.sh).
testflight:
	./scripts/testflight.sh

## Run a stand-in for the Claude API that debug builds can use (see README).
mock-claude:
	python3 scripts/mock-claude.py

clean:
	rm -rf $(DERIVED) Psion5.xcodeproj
