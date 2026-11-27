# gld-kiln-asm build switch:
#   make MODE=cabi        -> lib/libkiln_asm.a (System V AMD64 C ABI)
#   make MODE=cabi test   -> builds and runs conformance tests against libkiln_asm.a
#   make MODE=nolibc      -> bin/kiln_bench_nolibc (static zero-libc ELF)
#   make MODE=nolibc test -> verifies zero NEEDED libs (readelf -d) & runs --self-test

MODE ?= cabi

AS      := as
LD      := ld
AR      := ar
CC      := gcc
READELF := readelf

ASFLAGS := --64 -I arch/x86_64
CFLAGS  := -std=c11 -O3 -march=native -Wall -Wextra -Werror -I include
LDFLAGS_NOLIBC := -static -nostdlib --gc-sections -z noexecstack

BUILD_DIR := build/$(MODE)
LIB_DIR   := lib
BIN_DIR   := bin

CORE_SRCS := \
	arch/x86_64/utf8.s \
	arch/x86_64/wire.s \
	arch/x86_64/codecs_bench.s \
	arch/x86_64/tensor.s

CORE_OBJS := $(patsubst arch/x86_64/%.s,$(BUILD_DIR)/%.o,$(CORE_SRCS))

.PHONY: all test example bench c_ref clean check-nolibc

ifeq ($(MODE),cabi)

CABI_OBJS := $(CORE_OBJS) $(BUILD_DIR)/abi_c.o
TARGET    := $(LIB_DIR)/libkiln_asm.a

all: $(TARGET) $(BIN_DIR)/kiln_bench_cabi

$(TARGET): $(CABI_OBJS) | $(LIB_DIR)
	$(AR) rcs $@ $^

$(BIN_DIR)/test_conformance: tests/test_conformance.c $(TARGET) include/kiln_asm.h | $(BIN_DIR)
	$(CC) $(CFLAGS) -o $@ tests/test_conformance.c $(TARGET)

$(BIN_DIR)/example_roundtrip: examples/roundtrip.c $(TARGET) include/kiln_asm.h | $(BIN_DIR)
	$(CC) $(CFLAGS) -o $@ examples/roundtrip.c $(TARGET)

$(BIN_DIR)/kiln_bench_cabi: bench/bench_cabi.c $(TARGET) include/kiln_asm.h | $(BIN_DIR)
	$(CC) $(CFLAGS) -o $@ bench/bench_cabi.c $(TARGET)

example: $(BIN_DIR)/example_roundtrip

test: $(BIN_DIR)/test_conformance
	./$(BIN_DIR)/test_conformance

else ifeq ($(MODE),nolibc)

NOLIBC_OBJS := $(CORE_OBJS) $(BUILD_DIR)/nolibc_entry.o
TARGET      := $(BIN_DIR)/kiln_bench_nolibc

all: $(TARGET)

$(TARGET): $(NOLIBC_OBJS) | $(BIN_DIR)
	$(LD) $(LDFLAGS_NOLIBC) -o $@ $^

check-nolibc: $(TARGET)
	@if $(READELF) -d $(TARGET) 2>/dev/null | grep -q 'NEEDED'; then \
		echo "ERROR: $(TARGET) has dynamic NEEDED dependencies!" >&2; \
		$(READELF) -d $(TARGET) >&2; \
		exit 1; \
	fi
	@echo "Verified: $(TARGET) has zero NEEDED dynamic libraries"

test: check-nolibc
	./$(TARGET) --self-test

else
$(error Unsupported MODE='$(MODE)'. Use MODE=cabi or MODE=nolibc)
endif

$(BUILD_DIR)/%.o: arch/x86_64/%.s arch/x86_64/defs.inc | $(BUILD_DIR)
	$(AS) $(ASFLAGS) -o $@ $<

$(BIN_DIR)/kiln_bench_cref: c_ref/kiln_c_ref.c include/kiln_asm.h | $(BIN_DIR)
	$(CC) $(CFLAGS) -o $@ c_ref/kiln_c_ref.c

c_ref: $(BIN_DIR)/kiln_bench_cref

bench:
	@./bench/run_bench.sh

$(BUILD_DIR) $(LIB_DIR) $(BIN_DIR):
	mkdir -p $@

clean:
	rm -rf build $(LIB_DIR) $(BIN_DIR)
