#include "rlm_tree_sitter_internal.h"

foreign_t raise_tree_sitter_error(const char *code, const char *detail)
{
    term_t formal_args = PL_new_term_refs(2);
    term_t formal = PL_new_term_ref();
    term_t outer_args = PL_new_term_refs(2);
    term_t exception = PL_new_term_ref();

    if (!formal_args || !formal || !outer_args || !exception) {
        return PL_resource_error("memory");
    }

    if (!PL_put_atom_chars(formal_args + 0, code) ||
        !PL_put_string_chars(formal_args + 1, detail) ||
        !PL_cons_functor_v(formal, functor_tree_sitter_error2, formal_args) ||
        !PL_put_term(outer_args + 0, formal) ||
        !PL_put_atom_chars(outer_args + 1, "rlm_tree_sitter") ||
        !PL_cons_functor_v(exception, functor_error2, outer_args)) {
        return FALSE;
    }

    return PL_raise_exception(exception);
}

foreign_t raise_wrong_thread(const char *kind, int owner_thread)
{
    char detail[160];
    int current_thread = PL_thread_self();

    snprintf(detail,
             sizeof(detail),
             "%s belongs to Prolog thread %d; current thread is %d",
             kind,
             owner_thread,
             current_thread);
    return raise_tree_sitter_error("wrong_thread", detail);
}

int get_utf8_text(term_t term, char **text, size_t *length)
{
    return PL_get_nchars(term,
                         length,
                         text,
                         CVT_ATOM | CVT_STRING | BUF_MALLOC | REP_UTF8 | CVT_EXCEPTION);
}

int get_language(term_t term, rlm_ts_language_resource **resource)
{
    void *data = NULL;
    size_t length = 0;
    PL_blob_t *type = NULL;

    if (!PL_get_blob(term, &data, &length, &type) ||
        type != &language_blob ||
        length != sizeof(rlm_ts_language_resource *) ||
        !data) {
        return PL_type_error("tree_sitter_language", term);
    }
    *resource = *(rlm_ts_language_resource **)data;
    if (!*resource) {
        return raise_tree_sitter_error("stale_handle", "language handle has no resource");
    }
    return TRUE;
}

int get_parser(term_t term, rlm_ts_parser_resource **resource)
{
    void *data = NULL;
    size_t length = 0;
    PL_blob_t *type = NULL;

    if (!PL_get_blob(term, &data, &length, &type) ||
        type != &parser_blob ||
        length != sizeof(rlm_ts_parser_resource *) ||
        !data) {
        return PL_type_error("tree_sitter_parser", term);
    }
    *resource = *(rlm_ts_parser_resource **)data;
    if (!*resource) {
        return raise_tree_sitter_error("stale_handle", "parser handle has no resource");
    }
    return TRUE;
}

int get_tree(term_t term, rlm_ts_tree_resource **resource)
{
    void *data = NULL;
    size_t length = 0;
    PL_blob_t *type = NULL;

    if (!PL_get_blob(term, &data, &length, &type) ||
        type != &tree_blob ||
        length != sizeof(rlm_ts_tree_resource *) ||
        !data) {
        return PL_type_error("tree_sitter_tree", term);
    }
    *resource = *(rlm_ts_tree_resource **)data;
    if (!*resource) {
        return raise_tree_sitter_error("stale_handle", "tree handle has no resource");
    }
    return TRUE;
}

int get_node(term_t term, rlm_ts_node_resource **resource)
{
    void *data = NULL;
    size_t length = 0;
    PL_blob_t *type = NULL;

    if (!PL_get_blob(term, &data, &length, &type) ||
        type != &node_blob ||
        length != sizeof(rlm_ts_node_resource *) ||
        !data) {
        return PL_type_error("tree_sitter_node", term);
    }
    *resource = *(rlm_ts_node_resource **)data;
    if (!*resource || !(*resource)->tree) {
        return raise_tree_sitter_error("stale_handle", "node handle has no owning tree");
    }
    return TRUE;
}

int require_open_parser(rlm_ts_parser_resource *resource)
{
    if (!resource->open || !resource->parser) {
        return raise_tree_sitter_error("closed_parser", "parser handle is closed");
    }
    if (PL_thread_self() != resource->owner_thread) {
        return raise_wrong_thread("parser", resource->owner_thread);
    }
    return TRUE;
}

int require_open_tree(rlm_ts_tree_resource *resource)
{
    bool open;
    int owner_thread;

    pthread_mutex_lock(&resource->lock);
    open = resource->open && resource->tree != NULL;
    owner_thread = resource->owner_thread;
    pthread_mutex_unlock(&resource->lock);
    if (!open) {
        return raise_tree_sitter_error("closed_tree", "tree handle is closed");
    }
    if (PL_thread_self() != owner_thread) {
        return raise_wrong_thread("tree", owner_thread);
    }
    return TRUE;
}

int require_open_node(rlm_ts_node_resource *resource)
{
    return require_open_tree(resource->tree);
}

int unify_language(term_t term, rlm_ts_language_resource *resource)
{
    rlm_ts_language_resource *pointer = resource;
    return PL_unify_blob(term, &pointer, sizeof(pointer), &language_blob);
}

int unify_parser(term_t term, rlm_ts_parser_resource *resource)
{
    rlm_ts_parser_resource *pointer = resource;
    return PL_unify_blob(term, &pointer, sizeof(pointer), &parser_blob);
}

int unify_tree(term_t term, rlm_ts_tree_resource *resource)
{
    rlm_ts_tree_resource *pointer = resource;
    return PL_unify_blob(term, &pointer, sizeof(pointer), &tree_blob);
}

int unify_node(term_t term, rlm_ts_tree_resource *tree, TSNode node)
{
    rlm_ts_node_resource *resource;
    rlm_ts_node_resource *pointer;

    if (ts_node_is_null(node)) {
        return FALSE;
    }

    resource = calloc(1, sizeof(*resource));
    if (!resource) {
        return PL_resource_error("memory");
    }
    resource->node = node;
    resource->tree = tree;
    tree_retain_node(tree);

    pointer = resource;
    if (!PL_unify_blob(term, &pointer, sizeof(pointer), &node_blob)) {
        return FALSE;
    }
    return TRUE;
}

int unify_point(term_t term, TSPoint point)
{
    term_t args = PL_new_term_refs(2);
    term_t value = PL_new_term_ref();

    if (!args || !value) {
        return PL_resource_error("memory");
    }
    if (!PL_put_integer(args + 0, (int64_t)point.row) ||
        !PL_put_integer(args + 1, (int64_t)point.column) ||
        !PL_cons_functor_v(value, functor_point2, args)) {
        return FALSE;
    }
    return PL_unify(term, value);
}
