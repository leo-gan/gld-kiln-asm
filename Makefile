# gld-kiln-asm build switch:
#   make MODE=cabi        -> lib/libkiln_asm.a + lib/libkiln_asm.so (System V AMD64 C ABI)
#   make MODE=cabi test   -> builds and runs conformance tests against libkiln_asm.a & libkiln_asm.so
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
VERSION_SCRIPT := arch/x86_64/libkiln_asm.map
LDFLAGS_SO     := -shared -Bsymbolic --version-script=$(VERSION_SCRIPT) -z noexecstack -z relro -z now -soname libkiln_asm.so

BUILD_DIR := build/$(MODE)
LIB_DIR   := lib
BIN_DIR   := bin

CORE_SRCS := \
	arch/x86_64/utf8.s \
	arch/x86_64/wire.s \
	arch/x86_64/codecs_bench.s \
	arch/x86_64/tensor.s

CORE_OBJS := $(patsubst arch/x86_64/%.s,$(BUILD_DIR)/%.o,$(CORE_SRCS))

.PHONY: all test test-codegen example bench c_ref clean check-nolibc check-so

ifeq ($(MODE),cabi)

CABI_OBJS := $(CORE_OBJS) $(BUILD_DIR)/abi_c.o
TARGET    := $(LIB_DIR)/libkiln_asm.a
TARGET_SO := $(LIB_DIR)/libkiln_asm.so

all: $(TARGET) $(TARGET_SO) $(BIN_DIR)/kiln_bench_cabi

$(TARGET): $(CABI_OBJS) | $(LIB_DIR)
	$(AR) rcs $@ $^

$(TARGET_SO): $(CABI_OBJS) $(VERSION_SCRIPT) | $(LIB_DIR)
	$(LD) $(LDFLAGS_SO) -o $@ $(CABI_OBJS)

check-so: $(TARGET_SO)
	@if $(READELF) -d $(TARGET_SO) | grep -q 'NEEDED'; then \
		echo "ERROR: $(TARGET_SO) has dynamic NEEDED dependencies!" >&2; \
		$(READELF) -d $(TARGET_SO) >&2; \
		exit 1; \
	fi
	@if $(READELF) -d $(TARGET_SO) | grep -q 'TEXTREL'; then \
		echo "ERROR: $(TARGET_SO) has DT_TEXTREL!" >&2; \
		$(READELF) -d $(TARGET_SO) >&2; \
		exit 1; \
	fi
	@if $(READELF) --wide --dyn-syms $(TARGET_SO) | awk '$$4 == "FUNC" && $$7 != "UND" && $$8 !~ /^kiln_asm_/' | grep -q .; then \
		echo "ERROR: $(TARGET_SO) exports unexpected non-kiln_asm_* symbols!" >&2; \
		$(READELF) --wide --dyn-syms $(TARGET_SO) >&2; \
		exit 1; \
	fi
	@echo "Verified: $(TARGET_SO) has zero NEEDED, zero TEXTREL, and exports only kiln_asm_* C-ABI symbols"

$(BIN_DIR)/test_conformance: tests/test_conformance.c $(TARGET) include/kiln_asm.h | $(BIN_DIR)
	$(CC) $(CFLAGS) -o $@ tests/test_conformance.c $(TARGET)

$(BIN_DIR)/test_conformance_so: tests/test_conformance.c $(TARGET_SO) include/kiln_asm.h | $(BIN_DIR)
	$(CC) $(CFLAGS) -o $@ tests/test_conformance.c -L$(LIB_DIR) -lkiln_asm -Wl,-rpath,'$$ORIGIN/../lib'

$(BIN_DIR)/example_roundtrip: examples/roundtrip.c $(TARGET) include/kiln_asm.h | $(BIN_DIR)
	$(CC) $(CFLAGS) -o $@ examples/roundtrip.c $(TARGET)

$(BIN_DIR)/kiln_bench_cabi: bench/bench_cabi.c $(TARGET) include/kiln_asm.h | $(BIN_DIR)
	$(CC) $(CFLAGS) -o $@ bench/bench_cabi.c $(TARGET)

example: $(BIN_DIR)/example_roundtrip

test: $(BIN_DIR)/test_conformance $(BIN_DIR)/test_conformance_so check-so
	./$(BIN_DIR)/test_conformance
	./$(BIN_DIR)/test_conformance_so

GEN_DIR     := build/gen
GEN_SCHEMAS := point message id_tensors complex_record
GEN_OBJS    := $(patsubst %,$(GEN_DIR)/%.o,$(GEN_SCHEMAS))
GEN_SO      := $(GEN_DIR)/libkiln_gen_test.so

test-codegen: $(TARGET)
	@mkdir -p $(GEN_DIR) $(BIN_DIR)
	./codegen/gld-kilngen-asm --prefix gen --emit-map \
		$(patsubst %,--schema tests/schemas/%.json,$(GEN_SCHEMAS)) \
		--out $(GEN_DIR)
	@for s in $(GEN_SCHEMAS); do \
		$(AS) $(ASFLAGS) -o $(GEN_DIR)/$$s.o $(GEN_DIR)/$$s.s; \
	done
	$(CC) $(CFLAGS) -I $(GEN_DIR) -o $(BIN_DIR)/test_codegen tests/test_codegen.c $(GEN_OBJS) $(TARGET)
	./$(BIN_DIR)/test_codegen
	$(LD) -shared -Bsymbolic --version-script=$(GEN_DIR)/point.map -z noexecstack -z relro -z now \
		-soname libkiln_gen_test.so -o $(GEN_SO) $(GEN_OBJS) \
		--whole-archive $(TARGET) --no-whole-archive
	@if $(READELF) -d $(GEN_SO) | grep -qE 'NEEDED|TEXTREL'; then \
		echo "ERROR: $(GEN_SO) has NEEDED or TEXTREL!" >&2; \
		$(READELF) -d $(GEN_SO) >&2; \
		exit 1; \
	fi
	$(CC) $(CFLAGS) -I $(GEN_DIR) -o $(BIN_DIR)/test_codegen_so tests/test_codegen.c \
		-L$(GEN_DIR) -lkiln_gen_test -Wl,-rpath,'$$ORIGIN/../$(GEN_DIR)'
	./$(BIN_DIR)/test_codegen_so
	python3 tests/test_codegen_cli.py $(GEN_SO)

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
