BIN := tty_overlay_native
SWIFT := tty_overlay.swift
SWIFTC ?= swiftc

.PHONY: all clean run

all: $(BIN)

$(BIN): $(SWIFT) Info.plist
	$(SWIFTC) -O -o $@ $< \
		-framework Speech -framework AVFoundation \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
	codesign --force --sign - $@

clean:
	rm -f $(BIN)

run: $(BIN)
	./run_overlay.sh
