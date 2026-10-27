APP=QuotaBar
BIN=.build/release/$(APP)
BUNDLE=QuotaBar.app
ZIP=$(APP).zip

build:
	swift build -c release

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
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
