SWIPL ?= swipl
SWIPL_LD ?= swipl-ld
PKG_CONFIG ?= pkg-config

SHARED_OBJECT_EXTENSION := $(shell $(SWIPL) -q -g "current_prolog_flag(shared_object_extension,E),write(E),halt.")

TREE_SITTER_CFLAGS := $(shell $(PKG_CONFIG) --cflags tree-sitter)
TREE_SITTER_LIBS := $(shell $(PKG_CONFIG) --libs tree-sitter)

FOREIGN_DIR := foreign
TREE_SITTER_FOREIGN := $(FOREIGN_DIR)/rlm_tree_sitter.$(SHARED_OBJECT_EXTENSION)
TREE_SITTER_SOURCES := \
	c/rlm_tree_sitter.c \
	c/rlm_tree_sitter_support.c \
	c/rlm_tree_sitter_lifetime.c \
	c/rlm_tree_sitter_language.c \
	c/rlm_tree_sitter_parser.c \
	c/rlm_tree_sitter_node.c

.PHONY: all install research-approval tree-sitter-ffi tree-sitter-test-grammars tree-sitter-test clean

# SWI's pack installer invokes both the default build and `make install` when a
# Makefile is present. The core Prolog pack has no mandatory generated/native
# artifacts, so both phases intentionally succeed without compiling optional
# parser support.
all:
	@true

install: all
	@true

research-approval:
	$(SWIPL) -q -s scripts/validate_research_approval.pl

tree-sitter-ffi: $(TREE_SITTER_FOREIGN)

$(TREE_SITTER_FOREIGN): $(TREE_SITTER_SOURCES) c/rlm_tree_sitter_internal.h
	@mkdir -p $(FOREIGN_DIR)
	$(SWIPL_LD) -shared -o $@ $(TREE_SITTER_SOURCES) $(TREE_SITTER_CFLAGS) $(TREE_SITTER_LIBS) -pthread -ldl

tree-sitter-test-grammars:
	./scripts/build-tree-sitter-test-grammars.sh

tree-sitter-test: tree-sitter-ffi tree-sitter-test-grammars
	$(SWIPL) -q -s test/run_tree_sitter_tests.pl

clean:
	rm -f $(TREE_SITTER_FOREIGN)
	rm -rf test/fixtures/tree-sitter
