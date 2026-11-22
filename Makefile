# Knife Terminal — native builds
# make install-mac   build the macOS app and install to /Applications
# make install-mac-2 build and install a second Knife for another Claude account (Knife 2.app)
# make mac           build only
# make ios           build the iOS app for the connected device (install via Xcode/devicectl)
# make gen           regenerate the Xcode project from apple/project.yml
# make release       archive, notarize, sign the appcast, publish the GitHub release

APPLE := apple
DERIVED := $(APPLE)/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Knife Terminal.app
IOS_APP := $(DERIVED)/Build/Products/Debug-iphoneos/Knife.app
# Per-machine overrides (gitignored), e.g. XCODEBUILD_FLAGS = DEVELOPMENT_TEAM=… CODE_SIGN_ENTITLEMENTS=…
-include local.mk
XCODEBUILD_FLAGS ?=
XCODEBUILD_FLAGS_IOS ?=

gen:
	cd $(APPLE) && xcodegen generate

mac: gen
	cd $(APPLE) && xcodebuild -project KnifeTerminal.xcodeproj -scheme KnifeMac \
		-configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates \
		-allowProvisioningDeviceRegistration -skipPackagePluginValidation $(XCODEBUILD_FLAGS) \
		SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s build
# ^ optimized, but still the Debug configuration: its entitlements point at the
#   Production CloudKit environment, which a locally signed Release build would not

install-mac: mac
	rm -rf "/Applications/Knife Terminal.app"
	cp -R "$(APP)" /Applications/
	@echo installed

# ─── A second Knife for another Claude Code account ───
# Its own app (bundle id, windows, tabs, sidebar settings, socket ~/.knife-$(KNIFE2_ID).sock), whose tabs run
# with CLAUDE_CONFIG_DIR=$(KNIFE2_CONFIG_DIR) and whose window is tinted $(KNIFE2_TINT). No iCloud (the phone
# mirror and jobs stay with the main app) and no Sparkle. Built into its own DerivedData so the two builds
# never share products. XCODEBUILD_FLAGS_2 (local.mk) signs it: a distinct bundle id and entitlements
# without iCloud, e.g. PRODUCT_BUNDLE_IDENTIFIER=com.you.knifeterminal.2 CODE_SIGN_ENTITLEMENTS=macOS/KnifeMacDev.entitlements
KNIFE2_ID ?= 2
KNIFE2_NAME ?= Knife 2
KNIFE2_CONFIG_DIR ?= ~/.claude-worker
KNIFE2_TINT ?= 3FAF6C
XCODEBUILD_FLAGS_2 ?= PRODUCT_BUNDLE_IDENTIFIER=com.cwandt.knifeterminal.2
APP2 := $(APPLE)/DerivedData2/Build/Products/Debug/Knife Terminal.app

mac-2: gen
	cd $(APPLE) && xcodebuild -project KnifeTerminal.xcodeproj -scheme KnifeMac \
		-configuration Debug -derivedDataPath DerivedData2 -allowProvisioningUpdates \
		-allowProvisioningDeviceRegistration -skipPackagePluginValidation $(XCODEBUILD_FLAGS_2) \
		KNIFE_INSTANCE="$(KNIFE2_ID)" KNIFE_APP_NAME="$(KNIFE2_NAME)" KNIFE_CLAUDE_CONFIG_DIR="$(KNIFE2_CONFIG_DIR)" \
		KNIFE_TINT="$(KNIFE2_TINT)" KNIFE_ICON=icon-$(KNIFE2_ID) KNIFE_CLOUD_CONTAINER= \
		SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s build

install-mac-2: mac-2
	rm -rf "/Applications/$(KNIFE2_NAME).app"
	cp -R "$(APP2)" "/Applications/$(KNIFE2_NAME).app"
	@echo installed "$(KNIFE2_NAME)"

ios: gen
	cd $(APPLE) && xcodebuild -project KnifeTerminal.xcodeproj -scheme KnifeiOS \
		-configuration Debug -destination 'generic/platform=iOS' \
		-derivedDataPath DerivedData -allowProvisioningUpdates \
		-allowProvisioningDeviceRegistration -skipPackagePluginValidation $(XCODEBUILD_FLAGS_IOS) build

# IOS_DEVICE: a device id from `xcrun devicectl list devices` (set it in local.mk)
install-ios: ios
	xcrun devicectl device install app --device "$(IOS_DEVICE)" "$(IOS_APP)"
	@echo installed on $(IOS_DEVICE)

release:
	./release.sh "$(NOTES)"

.PHONY: gen mac install-mac mac-2 install-mac-2 ios install-ios release
