#ifndef RLM_TREE_SITTER_INTERNAL_H
#define RLM_TREE_SITTER_INTERNAL_H

#define _POSIX_C_SOURCE 200809L

#include <SWI-Prolog.h>
#include <tree_sitter/api.h>

#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if TREE_SITTER_LANGUAGE_VERSION >= 15
#define RLM_TS_LANGUAGE_ABI(language) ts_language_abi_version(language)
#else
#define RLM_TS_LANGUAGE_ABI(language) ts_language_version(language)
#endif

typedef const TSLanguage *(*rlm_ts_language_entry)(void);

typedef struct rlm_ts_language_resource {
    pthread_mutex_t lock;
    void *library;
    const TSLanguage *language;
    unsigned int abi;
    unsigned int dependents;
    bool blob_alive;
    bool public_open;
} rlm_ts_language_resource;

typedef struct rlm_ts_parser_resource {
    TSParser *parser;
    rlm_ts_language_resource *language;
    int owner_thread;
    bool open;
} rlm_ts_parser_resource;

typedef struct rlm_ts_tree_resource {
    pthread_mutex_t lock;
    TSTree *tree;
    rlm_ts_language_resource *language;
    unsigned int node_refs;
    int owner_thread;
    bool blob_alive;
    bool open;
} rlm_ts_tree_resource;

typedef struct rlm_ts_node_resource {
    TSNode node;
    rlm_ts_tree_resource *tree;
    const char **named_fields;
    uint32_t named_field_count;
} rlm_ts_node_resource;

extern PL_blob_t language_blob;
extern PL_blob_t parser_blob;
extern PL_blob_t tree_blob;
extern PL_blob_t node_blob;

extern functor_t functor_error2;
extern functor_t functor_tree_sitter_error2;
extern functor_t functor_point2;

foreign_t raise_tree_sitter_error(const char *code, const char *detail);
foreign_t raise_wrong_thread(const char *kind, int owner_thread);
int get_utf8_text(term_t term, char **text, size_t *length);

bool language_abi_supported(unsigned int abi);
bool language_retain(rlm_ts_language_resource *resource,
                     bool require_public_open,
                     const TSLanguage **language);
void language_release(rlm_ts_language_resource *resource);
bool language_snapshot_open(rlm_ts_language_resource *resource,
                            const TSLanguage **language,
                            unsigned int *abi);
bool language_close_public(rlm_ts_language_resource *resource);
void tree_retain_node(rlm_ts_tree_resource *resource);

int release_language_blob(atom_t atom);
int release_parser_blob(atom_t atom);
int release_tree_blob(atom_t atom);
int release_node_blob(atom_t atom);

int get_language(term_t term, rlm_ts_language_resource **resource);
int get_parser(term_t term, rlm_ts_parser_resource **resource);
int get_tree(term_t term, rlm_ts_tree_resource **resource);
int get_node(term_t term, rlm_ts_node_resource **resource);
int require_open_parser(rlm_ts_parser_resource *resource);
int require_open_tree(rlm_ts_tree_resource *resource);
int require_open_node(rlm_ts_node_resource *resource);
int unify_language(term_t term, rlm_ts_language_resource *resource);
int unify_parser(term_t term, rlm_ts_parser_resource *resource);
int unify_tree(term_t term, rlm_ts_tree_resource *resource);
int unify_node(term_t term, rlm_ts_tree_resource *tree, TSNode node);
int unify_point(term_t term, TSPoint point);

foreign_t pl_ts_runtime_abi(term_t minimum, term_t maximum);
foreign_t pl_ts_language_load(term_t path_term, term_t symbol_term, term_t language_term);
foreign_t pl_ts_language_abi(term_t language_term, term_t abi_term);
foreign_t pl_ts_language_close(term_t language_term, term_t status_term);
foreign_t pl_ts_parser_create(term_t parser_term);
foreign_t pl_ts_parser_set_language(term_t parser_term,
                                    term_t language_term,
                                    term_t status_term);
foreign_t pl_ts_parser_close(term_t parser_term, term_t status_term);
foreign_t pl_ts_parse_string(term_t parser_term, term_t source_term, term_t tree_term);
foreign_t pl_ts_tree_root(term_t tree_term, term_t node_term);
foreign_t pl_ts_tree_close(term_t tree_term, term_t status_term);
foreign_t pl_ts_node_type(term_t node_term, term_t type_term);
foreign_t pl_ts_node_named(term_t node_term);
foreign_t pl_ts_node_has_error(term_t node_term);
foreign_t pl_ts_node_is_error(term_t node_term);
foreign_t pl_ts_node_is_missing(term_t node_term);
foreign_t pl_ts_node_start_byte(term_t node_term, term_t byte_term);
foreign_t pl_ts_node_end_byte(term_t node_term, term_t byte_term);
foreign_t pl_ts_node_start_point(term_t node_term, term_t point_term);
foreign_t pl_ts_node_end_point(term_t node_term, term_t point_term);
foreign_t pl_ts_node_child_count(term_t node_term, term_t count_term);
foreign_t pl_ts_node_named_child_count(term_t node_term, term_t count_term);
foreign_t pl_ts_node_child(term_t node_term, term_t index_term, term_t child_term);
foreign_t pl_ts_node_child_field_name(term_t node_term,
                                          term_t index_term,
                                          term_t field_term);
foreign_t pl_ts_node_named_child(term_t node_term,
                                     term_t index_term,
                                     term_t child_term);
foreign_t pl_ts_node_named_child_field_name(term_t node_term,
                                                term_t index_term,
                                                term_t field_term);
foreign_t pl_ts_node_field(term_t node_term, term_t field_term, term_t child_term);

#endif
