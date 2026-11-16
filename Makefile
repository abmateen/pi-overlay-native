BIN := pi-overlay-native
LEGACY_BIN := pi-oui pi-overlay tty_overlay_native
SWIFT := pi_overlay_native.swift
SWIFTC ?= swiftc

NOTIFIER := PiOverlayNotifier.app
NOTIFIER_DIR := build/$(NOTIFIER)
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all clean run notifier install-notifier

all: $(BIN)

$(BIN): $(SWIFT) Info.plist
	$(SWIFTC) -O -o $@ $< \
		-framework Speech -framework AVFoundation \
		-framework UserNotifications \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
	codesign --force --sign - $@

# Notification helper. It has to be a real .app bundle in a stable location,
# because macOS refuses UserNotifications for processes the pi extension spawns
# directly (see notifier.swift).
notifier: $(NOTIFIER_DIR)

$(NOTIFIER_DIR): notifier.swift NotifierInfo.plist
	mkdir -p $@/Contents/MacOS
	cp NotifierInfo.plist $@/Contents/Info.plist
	$(SWIFTC) -O -o $@/Contents/MacOS/PiOverlayNotifier notifier.swift \
		-framework AppKit -framework UserNotifications
	codesign --force --deep --sign - $@

install-notifier: $(NOTIFIER_DIR)
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/$(NOTIFIER)"
	cp -R $(NOTIFIER_DIR) "$(HOME)/Applications/"
	$(LSREGISTER) -f "$(HOME)/Applications/$(NOTIFIER)"
	@echo "installed $(HOME)/Applications/$(NOTIFIER)"

clean:
	rm -f $(BIN) $(LEGACY_BIN)
	rm -rf build/$(NOTIFIER)

run: $(BIN)
	./run_overlay.sh
