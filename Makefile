APP := Bob.app
BIN := Bob
BUILD := .build/release
CONTENTS := $(APP)/Contents

.PHONY: run app clean open install

run:
	swift run

app: clean
	swift build -c release
	mkdir -p $(CONTENTS)/MacOS
	mkdir -p $(CONTENTS)/Resources
	cp $(BUILD)/$(BIN) $(CONTENTS)/MacOS/$(BIN)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
# The dock/Finder icon, named by CFBundleIconFile. `app` runs `clean` first, so
# anything not copied in here does not survive a build.
	cp Resources/Bob.icns $(CONTENTS)/Resources/$(BIN).icns
# SPM resource bundles — the tree-sitter highlight queries live in one of these.
# Copying only the binary leaves them behind and syntax highlighting silently
# switches itself off in the bundled app while still working under `swift run`.
	cp -R $(BUILD)/*.bundle $(CONTENTS)/Resources/
	codesign --force --deep --sign - $(APP)
	@echo "built $(APP) — launch with: open $(APP)"

open: app
	open $(APP)

# Put the built bundle in /Applications so it opens like any other app. The old
# copy goes first: cp -R over a live bundle leaves stale files behind, and a
# running Bob must be let go gracefully — SIGKILL races its state file.
install: app
	@osascript -e 'quit app "Bob"' 2>/dev/null || true
	@sleep 3
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/$(APP)
	@touch /Applications/$(APP)
	@echo "installed /Applications/$(APP)" 

clean:
	rm -rf $(APP)
