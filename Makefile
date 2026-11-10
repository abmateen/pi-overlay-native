BIN := tty_overlay_native
SWIFT := tty_overlay.swift
SWIFTC ?= swiftc

.PHONY: all clean run

all: $(BIN)

$(BIN): $(SWIFT)
	$(SWIFTC) -O -o $@ $<

clean:
	rm -f $(BIN)

run: $(BIN)
	./run_overlay.sh
