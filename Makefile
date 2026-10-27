APP=QuotaBar
BIN=.build/release/$(APP)
BUNDLE=QuotaBar.app
ZIP=$(APP).zip
SPARKLE_FW=$(dir $(realpath $(BIN)))Sparkle.framework

build:
	swift build -c release

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Frameworks $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/QuotaBar.icns $(BUNDLE)/Contents/Resources/QuotaBar.icns
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$(date -u +%Y%m%d%H%M%S)" $(BUNDLE)/Contents/Info.plist
	@test -n "$(SPARKLE_FW)" || (echo "Sparkle.framework not found; run swift build first"; exit 1)
	ditto "$(SPARKLE_FW)" $(BUNDLE)/Contents/Frameworks/Sparkle.framework
	codesign --force --deep --sign - $(BUNDLE)
	codesign --verify --deep --strict $(BUNDLE)
	@echo "-> $(BUNDLE)"

install: app
	@pkill -x QuotaBar 2>/dev/null || true
	@sleep 0.5
	rm -rf /Applications/$(BUNDLE)
	ditto $(BUNDLE) /Applications/$(BUNDLE)
	open /Applications/$(BUNDLE)
	@echo "-> /Applications/$(BUNDLE)"

update:
	git pull --ff-only
	$(MAKE) install

run: app
	open $(BUNDLE)

zip: app
	rm -f $(ZIP)
	ditto -c -k --sequesterRsrc --keepParent $(BUNDLE) $(ZIP)
	@echo "-> $(ZIP)"

clean:
	rm -rf .build $(BUNDLE) $(ZIP)

evidence: app
	./scripts/capture-ui.sh

verify:
	swift build -c release 2>&1 | tail -5
	test -x $(BIN) && echo "BINARY-OK"
