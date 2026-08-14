APP := Bob.app
BIN := Bob
BUILD := .build/release
CONTENTS := $(APP)/Contents

.PHONY: run app clean open

run:
	swift run

app: clean
	swift build -c release
	mkdir -p $(CONTENTS)/MacOS
	mkdir -p $(CONTENTS)/Resources
	cp $(BUILD)/$(BIN) $(CONTENTS)/MacOS/$(BIN)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
# SPM resource bundles — the tree-sitter highlight queries live in one of these.
# Copying only the binary leaves them behind and syntax highlighting silently
# switches itself off in the bundled app while still working under `swift run`.
	cp -R $(BUILD)/*.bundle $(CONTENTS)/Resources/
	codesign --force --deep --sign - $(APP)
	@echo "built $(APP) — launch with: open $(APP)"

open: app
	open $(APP)

clean:
	rm -rf $(APP)
