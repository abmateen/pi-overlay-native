BIN := pi-overlay-native
LEGACY_BIN := pi-oui pi-overlay tty_overlay_native
SWIFT := pi_overlay_native.swift
SWIFTC ?= swiftc

NOTIFIER := PiOverlayNotifier.app
NOTIFIER_DIR := build/$(NOTIFIER)
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all clean run notifier install-notifier install-extension

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

# Install the pi extension as symlinks into this checkout. A copied extension
# keeps running the binary from the day it was copied — which is how a tty
# overlay without compact mode ended up being spawned — so link instead.
ext_install_dir := $(HOME)/.pi/agent/extensions/tty-overlay

install-extension: $(BIN)
	mkdir -p "$(ext_install_dir)"
	ln -sf "$(CURDIR)/extension.ts" "$(ext_install_dir)/index.ts"
	ln -sf "$(CURDIR)/$(BIN)" "$(ext_install_dir)/$(BIN)"
	ln -sf "$(CURDIR)/markdown-it.min.js" "$(ext_install_dir)/markdown-it.min.js"
	rm -f "$(ext_install_dir)/tty_overlay_native" $(addprefix $(ext_install_dir)/,$(LEGACY_BIN))
	@echo "extension installed in $(ext_install_dir) (symlinked to this checkout)"

run: $(BIN)
	./run_overlay.sh
