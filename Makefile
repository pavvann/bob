APP := Bob.app
BIN := Bob
BUILD := .build/release
CONTENTS := $(APP)/Contents

# The marketing version lives in ./VERSION — one line, hand-edited when a release
# is cut. The build number is the commit count: monotonic without a counter to
# maintain, and reproducible from any checkout. Both are stamped into the bundle's
# Info.plist rather than committed into it, so the file on disk can never disagree
# with the tree it was built from.
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.0)
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

.PHONY: run app clean open

run:
	swift run

app: clean
	swift build -c release
	mkdir -p $(CONTENTS)/MacOS
	mkdir -p $(CONTENTS)/Resources
	cp $(BUILD)/$(BIN) $(CONTENTS)/MacOS/$(BIN)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(CONTENTS)/Info.plist
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" $(CONTENTS)/Info.plist
# SPM resource bundles — the tree-sitter highlight queries live in one of these.
# Copying only the binary leaves them behind and syntax highlighting silently
# switches itself off in the bundled app while still working under `swift run`.
	cp -R $(BUILD)/*.bundle $(CONTENTS)/Resources/
	codesign --force --deep --sign - $(APP)
	@echo "built $(APP) $(VERSION) ($(BUILD_NUMBER)) — launch with: open $(APP)"

open: app
	open $(APP)

clean:
	rm -rf $(APP)
