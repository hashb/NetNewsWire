PROJECT ?= NetNewsWire.xcodeproj
SCHEME ?= NetNewsWire
CONFIGURATION ?= Release
DESTINATION ?= platform=macOS,arch=arm64
ARCHS ?= arm64
DERIVED_DATA ?= build/DerivedData
XCODEBUILD ?= xcodebuild
XCODEBUILD_FLAGS ?= -quiet

.DEFAULT_GOAL := release

.PHONY: release macos-release clean

release: macos-release

macos-release:
	$(XCODEBUILD) $(XCODEBUILD_FLAGS) \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		ARCHS="$(ARCHS)" \
		build
	@echo "Built app: $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(SCHEME).app"

clean:
	$(XCODEBUILD) $(XCODEBUILD_FLAGS) \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		ARCHS="$(ARCHS)" \
		clean
