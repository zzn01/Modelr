DERIVED    := .derived
XCODEBUILD := xcodebuild -project Modelr.xcodeproj -scheme Modelr \
              -derivedDataPath $(DERIVED)

.PHONY: run run-release build release package test smoke gen clean

# Build (Debug) and launch the app
run: build
	open $(DERIVED)/Build/Products/Debug/Modelr.app

# Regenerate the Xcode project from project.yml
gen:
	xcodegen generate

build: gen
	$(XCODEBUILD) -configuration Debug CODE_SIGNING_ALLOWED=NO build

# Apple-silicon-only Release build (Float16 has no x86_64 slice)
release: gen
	$(XCODEBUILD) -configuration Release ARCHS=arm64 CODE_SIGNING_ALLOWED=YES build
	@echo "app: $(DERIVED)/Build/Products/Release/Modelr.app"

# Optimized local run: an unsigned Release build (same -O / Float16 paths as the
# distributed app, so performance matches — Debug `run` is far slower). Skips code
# signing so it builds without the release team certificate; a locally-built app
# runs without Gatekeeper quarantine.
run-release: gen
	$(XCODEBUILD) -configuration Release ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
	open $(DERIVED)/Build/Products/Release/Modelr.app

# Zip a signed Release app for distribution. `ditto` preserves the app bundle's
# metadata and resource forks, unlike a plain `zip` invocation.
package: release
	rm -rf dist
	mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent \
		$(DERIVED)/Build/Products/Release/Modelr.app dist/Modelr.zip

test: gen
	$(XCODEBUILD) CODE_SIGNING_ALLOWED=NO test

# Headless self-drive: onboarding -> import -> generate -> paint -> export -> screenshots
smoke: build
	MODELR_UI_SMOKE=1 MODELR_SMOKE_MODEL=small \
	MODELR_SMOKE_OUT=$(CURDIR)/docs/e2e/smoke-make \
	$(DERIVED)/Build/Products/Debug/Modelr.app/Contents/MacOS/Modelr

clean:
	rm -rf $(DERIVED)
