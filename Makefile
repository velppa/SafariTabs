APP_NAME := SafariTabs
BUNDLE   := build/$(APP_NAME).app
BIN      := .build/release/$(APP_NAME)

.PHONY: run build app clean

run:
	swift run

build:
	swift build -c release

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist) ($$(date '+%Y-%m-%d %H:%M'))" $(BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --deep --sign - $(BUNDLE)
	@echo "Built $(BUNDLE)"
	@echo "Open with: open $(BUNDLE)"

clean:
	rm -rf .build build
