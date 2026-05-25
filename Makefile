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
	codesign --force --deep --sign - $(APP)
	@echo "built $(APP) — launch with: open $(APP)"

open: app
	open $(APP)

clean:
	rm -rf $(APP)
