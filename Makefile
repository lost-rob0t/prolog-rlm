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

.PHONY: all tree-sitter-ffi tree-sitter-test-grammars tree-sitter-test clean

# The core SWI pack has no mandatory native build. Tree-sitter is an optional,
# host-loaded parser boundary with explicit development dependencies; building
# it remains opt-in through the dedicated target below.
all:
	@true

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
