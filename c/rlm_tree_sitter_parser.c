#include "rlm_tree_sitter_internal.h"

foreign_t pl_ts_parser_create(term_t parser_term)
{
    rlm_ts_parser_resource *resource = calloc(1, sizeof(*resource));

    if (!resource) {
        return PL_resource_error("memory");
    }
    resource->parser = ts_parser_new();
    if (!resource->parser) {
        free(resource);
        return PL_resource_error("memory");
    }
    resource->owner_thread = PL_thread_self();
    resource->open = true;
    return unify_parser(parser_term, resource);
}

foreign_t pl_ts_parser_set_language(term_t parser_term,
                                    term_t language_term,
                                    term_t status_term)
{
    rlm_ts_parser_resource *parser;
    rlm_ts_language_resource *language;
    rlm_ts_language_resource *previous;
    const TSLanguage *native_language = NULL;

    if (!get_parser(parser_term, &parser) || !require_open_parser(parser)) {
        return FALSE;
    }
    if (!get_language(language_term, &language)) {
        return FALSE;
    }
    if (!language_retain(language, true, &native_language)) {
        return raise_tree_sitter_error("closed_language",
                                       "cannot retain closed language handle");
    }
    if (!ts_parser_set_language(parser->parser, native_language)) {
        language_release(language);
        return raise_tree_sitter_error("incompatible_language_abi",
                                       "Tree-sitter rejected the grammar ABI");
    }

    previous = parser->language;
    parser->language = language;
    language_release(previous);
    return PL_unify_atom_chars(status_term, "configured");
}

foreign_t pl_ts_parser_close(term_t parser_term, term_t status_term)
{
    rlm_ts_parser_resource *resource;

    if (!get_parser(parser_term, &resource)) {
        return FALSE;
    }
    if (!resource->open) {
        return PL_unify_atom_chars(status_term, "already_closed");
    }
    if (PL_thread_self() != resource->owner_thread) {
        return raise_wrong_thread("parser", resource->owner_thread);
    }

    ts_parser_delete(resource->parser);
    resource->parser = NULL;
    resource->open = false;
    language_release(resource->language);
    resource->language = NULL;
    return PL_unify_atom_chars(status_term, "closed");
}

foreign_t pl_ts_parse_string(term_t parser_term, term_t source_term, term_t tree_term)
{
    rlm_ts_parser_resource *parser;
    rlm_ts_tree_resource *resource;
    char *source = NULL;
    size_t source_length = 0;
    TSTree *tree;

    if (!get_parser(parser_term, &parser) || !require_open_parser(parser)) {
        return FALSE;
    }
    if (!parser->language) {
        return raise_tree_sitter_error("parser_without_language",
                                       "parser has no language configured");
    }
    if (!get_utf8_text(source_term, &source, &source_length)) {
        return FALSE;
    }
    if (source_length > UINT32_MAX) {
        PL_free(source);
        return PL_representation_error("tree_sitter_source_length");
    }

    tree = ts_parser_parse_string(parser->parser,
                                  NULL,
                                  source,
                                  (uint32_t)source_length);
    PL_free(source);
    if (!tree) {
        return raise_tree_sitter_error("parse_failed",
                                       "Tree-sitter returned NULL while parsing source");
    }

    resource = calloc(1, sizeof(*resource));
    if (!resource) {
        ts_tree_delete(tree);
        return PL_resource_error("memory");
    }
    if (pthread_mutex_init(&resource->lock, NULL) != 0) {
        ts_tree_delete(tree);
        free(resource);
        return PL_resource_error("memory");
    }
    if (!language_retain(parser->language, false, NULL)) {
        ts_tree_delete(tree);
        pthread_mutex_destroy(&resource->lock);
        free(resource);
        return raise_tree_sitter_error("language_lifetime",
                                       "parser language could not be retained for tree lifetime");
    }
    resource->tree = tree;
    resource->language = parser->language;
    resource->owner_thread = parser->owner_thread;
    resource->blob_alive = true;
    resource->open = true;
    return unify_tree(tree_term, resource);
}

foreign_t pl_ts_tree_root(term_t tree_term, term_t node_term)
{
    rlm_ts_tree_resource *tree;

    if (!get_tree(tree_term, &tree) || !require_open_tree(tree)) {
        return FALSE;
    }
    return unify_node(node_term, tree, ts_tree_root_node(tree->tree));
}

foreign_t pl_ts_tree_close(term_t tree_term, term_t status_term)
{
    rlm_ts_tree_resource *resource;

    if (!get_tree(tree_term, &resource)) {
        return FALSE;
    }
    if (!resource->open) {
        return PL_unify_atom_chars(status_term, "already_closed");
    }
    if (PL_thread_self() != resource->owner_thread) {
        return raise_wrong_thread("tree", resource->owner_thread);
    }

    {
        TSTree *tree;
        rlm_ts_language_resource *language;
        pthread_mutex_lock(&resource->lock);
        tree = resource->tree;
        language = resource->language;
        resource->tree = NULL;
        resource->language = NULL;
        resource->open = false;
        pthread_mutex_unlock(&resource->lock);
        ts_tree_delete(tree);
        language_release(language);
    }
    return PL_unify_atom_chars(status_term, "closed");
}
