#include "rlm_tree_sitter_internal.h"

static const char *query_error_name(TSQueryError error)
{
    switch (error) {
    case TSQueryErrorSyntax:
        return "syntax";
    case TSQueryErrorNodeType:
        return "node_type";
    case TSQueryErrorField:
        return "field";
    case TSQueryErrorCapture:
        return "capture";
    case TSQueryErrorStructure:
        return "structure";
    case TSQueryErrorLanguage:
        return "language";
    case TSQueryErrorNone:
    default:
        return "unknown";
    }
}

static foreign_t raise_query_compile_error(TSQueryError error,
                                           uint32_t offset)
{
    term_t compile_args = PL_new_term_refs(2);
    term_t compile_error = PL_new_term_ref();
    term_t outer_args = PL_new_term_refs(2);
    term_t exception = PL_new_term_ref();

    if (!compile_args || !compile_error || !outer_args || !exception) {
        return PL_resource_error("memory");
    }
    if (!PL_put_atom_chars(compile_args + 0, query_error_name(error)) ||
        !PL_put_integer(compile_args + 1, offset) ||
        !PL_cons_functor_v(compile_error, functor_query_compile2, compile_args) ||
        !PL_put_term(outer_args + 0, compile_error) ||
        !PL_put_atom_chars(outer_args + 1, "rlm_tree_sitter") ||
        !PL_cons_functor_v(exception, functor_tree_sitter_error2, outer_args)) {
        return FALSE;
    }
    return PL_raise_exception(exception);
}

static int unify_query(term_t term, rlm_ts_query_resource *resource)
{
    rlm_ts_query_resource *pointer = resource;
    return PL_unify_blob(term, &pointer, sizeof(pointer), &query_blob);
}

static int unify_query_cursor(term_t term,
                              rlm_ts_query_cursor_resource *resource)
{
    rlm_ts_query_cursor_resource *pointer = resource;
    return PL_unify_blob(term,
                         &pointer,
                         sizeof(pointer),
                         &query_cursor_blob);
}

static int query_is_open(rlm_ts_query_resource *resource,
                         const TSQuery **query)
{
    int open;

    pthread_mutex_lock(&resource->lock);
    open = resource->open && resource->query != NULL;
    if (open && query) {
        *query = resource->query;
    }
    pthread_mutex_unlock(&resource->lock);
    if (!open) {
        return raise_tree_sitter_error("closed_query", "query handle is closed");
    }
    return TRUE;
}

static int get_u32(term_t term, const char *domain, uint32_t *value)
{
    int64_t integer;

    if (!PL_get_int64_ex(term, &integer)) {
        return FALSE;
    }
    if (integer < 0 || (uint64_t)integer > UINT32_MAX) {
        return PL_domain_error(domain, term);
    }
    *value = (uint32_t)integer;
    return TRUE;
}

static int get_point(term_t term, TSPoint *point)
{
    term_t row = PL_new_term_ref();
    term_t column = PL_new_term_ref();
    functor_t functor;

    if (!row || !column ||
        !PL_get_functor(term, &functor) ||
        functor != functor_point2 ||
        !PL_get_arg(1, term, row) ||
        !PL_get_arg(2, term, column) ||
        !get_u32(row, "tree_sitter_point", &point->row) ||
        !get_u32(column, "tree_sitter_point", &point->column)) {
        return FALSE;
    }
    return TRUE;
}

static int unify_string(term_t term, const char *value, uint32_t length)
{
    if (!value) {
        return FALSE;
    }
    return PL_unify_string_nchars(term, (size_t)length, value);
}

foreign_t pl_ts_query_compile(term_t language_term,
                              term_t source_term,
                              term_t query_term)
{
    rlm_ts_language_resource *language;
    rlm_ts_query_resource *resource;
    const TSLanguage *native_language = NULL;
    char *source = NULL;
    size_t source_length = 0;
    uint32_t error_offset = 0;
    TSQueryError error_type = TSQueryErrorNone;
    TSQuery *query;

    if (!get_language(language_term, &language)) {
        return FALSE;
    }
    if (!get_utf8_text(source_term, &source, &source_length)) {
        return FALSE;
    }
    if (source_length > UINT32_MAX) {
        PL_free(source);
        return PL_representation_error("tree_sitter_query_length");
    }
    if (!language_retain(language, true, &native_language)) {
        PL_free(source);
        return raise_tree_sitter_error("closed_language",
                                       "cannot compile a query against a closed language");
    }
    query = ts_query_new(native_language,
                         source,
                         (uint32_t)source_length,
                         &error_offset,
                         &error_type);
    PL_free(source);
    if (!query) {
        language_release(language);
        return raise_query_compile_error(error_type, error_offset);
    }

    resource = calloc(1, sizeof(*resource));
    if (!resource) {
        ts_query_delete(query);
        language_release(language);
        return PL_resource_error("memory");
    }
    if (pthread_mutex_init(&resource->lock, NULL) != 0) {
        ts_query_delete(query);
        language_release(language);
        free(resource);
        return PL_resource_error("memory");
    }
    resource->query = query;
    resource->language = language;
    resource->blob_alive = true;
    resource->open = true;
    return unify_query(query_term, resource);
}

foreign_t pl_ts_query_close(term_t query_term, term_t status_term)
{
    rlm_ts_query_resource *resource;
    TSQuery *query = NULL;
    rlm_ts_language_resource *language = NULL;

    if (!get_query(query_term, &resource)) {
        return FALSE;
    }
    pthread_mutex_lock(&resource->lock);
    if (!resource->open) {
        pthread_mutex_unlock(&resource->lock);
        return PL_unify_atom_chars(status_term, "already_closed");
    }
    resource->open = false;
    if (resource->dependents == 0) {
        query = resource->query;
        language = resource->language;
        resource->query = NULL;
        resource->language = NULL;
    }
    pthread_mutex_unlock(&resource->lock);
    if (query) {
        ts_query_delete(query);
    }
    if (language) {
        language_release(language);
    }
    return PL_unify_atom_chars(status_term, "closed");
}

foreign_t pl_ts_query_pattern_count(term_t query_term, term_t count_term)
{
    rlm_ts_query_resource *resource;
    uint32_t count;

    if (!get_query(query_term, &resource)) {
        return FALSE;
    }
    pthread_mutex_lock(&resource->lock);
    if (!resource->open || !resource->query) {
        pthread_mutex_unlock(&resource->lock);
        return raise_tree_sitter_error("closed_query", "query handle is closed");
    }
    count = ts_query_pattern_count(resource->query);
    pthread_mutex_unlock(&resource->lock);
    return PL_unify_integer(count_term, count);
}

foreign_t pl_ts_query_capture_count(term_t query_term, term_t count_term)
{
    rlm_ts_query_resource *resource;
    uint32_t count;

    if (!get_query(query_term, &resource)) {
        return FALSE;
    }
    pthread_mutex_lock(&resource->lock);
    if (!resource->open || !resource->query) {
        pthread_mutex_unlock(&resource->lock);
        return raise_tree_sitter_error("closed_query", "query handle is closed");
    }
    count = ts_query_capture_count(resource->query);
    pthread_mutex_unlock(&resource->lock);
    return PL_unify_integer(count_term, count);
}

foreign_t pl_ts_query_string_count(term_t query_term, term_t count_term)
{
    rlm_ts_query_resource *resource;
    uint32_t count;

    if (!get_query(query_term, &resource)) {
        return FALSE;
    }
    pthread_mutex_lock(&resource->lock);
    if (!resource->open || !resource->query) {
        pthread_mutex_unlock(&resource->lock);
        return raise_tree_sitter_error("closed_query", "query handle is closed");
    }
    count = ts_query_string_count(resource->query);
    pthread_mutex_unlock(&resource->lock);
    return PL_unify_integer(count_term, count);
}

foreign_t pl_ts_query_capture_name(term_t query_term,
                                   term_t id_term,
                                   term_t name_term)
{
    rlm_ts_query_resource *resource;
    uint32_t id;
    uint32_t count;
    uint32_t length = 0;
    const char *name;
    int result;

    if (!get_query(query_term, &resource) ||
        !get_u32(id_term, "tree_sitter_query_capture", &id)) {
        return FALSE;
    }
    pthread_mutex_lock(&resource->lock);
    if (!resource->open || !resource->query) {
        pthread_mutex_unlock(&resource->lock);
        return raise_tree_sitter_error("closed_query", "query handle is closed");
    }
    count = ts_query_capture_count(resource->query);
    if (id >= count) {
        pthread_mutex_unlock(&resource->lock);
        return PL_domain_error("tree_sitter_query_capture", id_term);
    }
    name = ts_query_capture_name_for_id(resource->query, id, &length);
    result = unify_string(name_term, name, length);
    pthread_mutex_unlock(&resource->lock);
    return result;
}

static const char *quantifier_name(TSQuantifier quantifier)
{
    switch (quantifier) {
    case TSQuantifierZero:
        return "zero";
    case TSQuantifierZeroOrOne:
        return "zero_or_one";
    case TSQuantifierZeroOrMore:
        return "zero_or_more";
    case TSQuantifierOne:
        return "one";
    case TSQuantifierOneOrMore:
        return "one_or_more";
    default:
        return "unknown";
    }
}

foreign_t pl_ts_query_capture_quantifier(term_t query_term,
                                         term_t pattern_term,
                                         term_t capture_term,
                                         term_t quantifier_term)
{
    rlm_ts_query_resource *resource;
    uint32_t pattern;
    uint32_t capture;
    uint32_t pattern_count;
    uint32_t capture_count;
    TSQuantifier quantifier;

    if (!get_query(query_term, &resource) ||
        !get_u32(pattern_term, "tree_sitter_query_pattern", &pattern) ||
        !get_u32(capture_term, "tree_sitter_query_capture", &capture)) {
        return FALSE;
    }
    pthread_mutex_lock(&resource->lock);
    if (!resource->open || !resource->query) {
        pthread_mutex_unlock(&resource->lock);
        return raise_tree_sitter_error("closed_query", "query handle is closed");
    }
    pattern_count = ts_query_pattern_count(resource->query);
    capture_count = ts_query_capture_count(resource->query);
    if (pattern >= pattern_count || capture >= capture_count) {
        pthread_mutex_unlock(&resource->lock);
        return PL_domain_error("tree_sitter_query_capture", capture_term);
    }
    quantifier = ts_query_capture_quantifier_for_id(resource->query,
                                                     pattern,
                                                     capture);
    pthread_mutex_unlock(&resource->lock);
    return PL_unify_atom_chars(quantifier_term, quantifier_name(quantifier));
}

foreign_t pl_ts_query_string_value(term_t query_term,
                                   term_t id_term,
                                   term_t value_term)
{
    rlm_ts_query_resource *resource;
    uint32_t id;
    uint32_t count;
    uint32_t length = 0;
    const char *value;
    int result;

    if (!get_query(query_term, &resource) ||
        !get_u32(id_term, "tree_sitter_query_string", &id)) {
        return FALSE;
    }
    pthread_mutex_lock(&resource->lock);
    if (!resource->open || !resource->query) {
        pthread_mutex_unlock(&resource->lock);
        return raise_tree_sitter_error("closed_query", "query handle is closed");
    }
    count = ts_query_string_count(resource->query);
    if (id >= count) {
        pthread_mutex_unlock(&resource->lock);
        return PL_domain_error("tree_sitter_query_string", id_term);
    }
    value = ts_query_string_value_for_id(resource->query, id, &length);
    result = unify_string(value_term, value, length);
    pthread_mutex_unlock(&resource->lock);
    return result;
}

static const char *predicate_step_type(TSQueryPredicateStepType type)
{
    switch (type) {
    case TSQueryPredicateStepTypeCapture:
        return "capture";
    case TSQueryPredicateStepTypeString:
        return "string";
    case TSQueryPredicateStepTypeDone:
        return "done";
    default:
        return "unknown";
    }
}

static int unify_predicate_steps(term_t output,
                                 const TSQueryPredicateStep *steps,
                                 uint32_t count)
{
    term_t list = PL_new_term_ref();
    term_t head = PL_new_term_ref();
    term_t args = PL_new_term_refs(2);
    term_t value = PL_new_term_ref();
    uint32_t index;

    if (!list || !head || !args || !value || !PL_put_nil(list)) {
        return PL_resource_error("memory");
    }
    for (index = count; index > 0; index--) {
        const TSQueryPredicateStep *step = &steps[index - 1];
        if (!PL_put_atom_chars(args + 0, predicate_step_type(step->type)) ||
            !PL_put_integer(args + 1, step->value_id) ||
            !PL_cons_functor_v(value, functor_query_predicate_step2, args) ||
            !PL_cons_list(head, value, list) ||
            !PL_put_term(list, head)) {
            return FALSE;
        }
    }
    return PL_unify(output, list);
}

foreign_t pl_ts_query_predicates(term_t query_term,
                                 term_t pattern_term,
                                 term_t predicates_term)
{
    rlm_ts_query_resource *resource;
    uint32_t pattern;
    uint32_t count;
    const TSQueryPredicateStep *steps;
    int result;

    if (!get_query(query_term, &resource) ||
        !get_u32(pattern_term, "tree_sitter_query_pattern", &pattern)) {
        return FALSE;
    }
    pthread_mutex_lock(&resource->lock);
    if (!resource->open || !resource->query) {
        pthread_mutex_unlock(&resource->lock);
        return raise_tree_sitter_error("closed_query", "query handle is closed");
    }
    if (pattern >= ts_query_pattern_count(resource->query)) {
        pthread_mutex_unlock(&resource->lock);
        return PL_domain_error("tree_sitter_query_pattern", pattern_term);
    }
    steps = ts_query_predicates_for_pattern(resource->query, pattern, &count);
    result = unify_predicate_steps(predicates_term, steps, count);
    pthread_mutex_unlock(&resource->lock);
    return result;
}

foreign_t pl_ts_query_cursor_create(term_t cursor_term)
{
    rlm_ts_query_cursor_resource *resource = calloc(1, sizeof(*resource));

    if (!resource) {
        return PL_resource_error("memory");
    }
    resource->cursor = ts_query_cursor_new();
    if (!resource->cursor) {
        free(resource);
        return PL_resource_error("memory");
    }
    resource->owner_thread = PL_thread_self();
    resource->open = true;
    return unify_query_cursor(cursor_term, resource);
}

foreign_t pl_ts_query_cursor_close(term_t cursor_term, term_t status_term)
{
    rlm_ts_query_cursor_resource *resource;
    rlm_ts_query_resource *query;
    rlm_ts_tree_resource *tree;

    if (!get_query_cursor(cursor_term, &resource)) {
        return FALSE;
    }
    if (!resource->open) {
        return PL_unify_atom_chars(status_term, "already_closed");
    }
    if (PL_thread_self() != resource->owner_thread) {
        return raise_wrong_thread("query cursor", resource->owner_thread);
    }
    ts_query_cursor_delete(resource->cursor);
    resource->cursor = NULL;
    resource->open = false;
    query = resource->query;
    tree = resource->tree;
    resource->query = NULL;
    resource->tree = NULL;
    query_release(query);
    tree_release_node(tree);
    return PL_unify_atom_chars(status_term, "closed");
}

foreign_t pl_ts_query_cursor_exec(term_t cursor_term,
                                  term_t query_term,
                                  term_t node_term)
{
    rlm_ts_query_cursor_resource *cursor;
    rlm_ts_query_resource *query;
    rlm_ts_node_resource *node;
    const TSQuery *native_query = NULL;
    rlm_ts_query_resource *old_query;
    rlm_ts_tree_resource *old_tree;
    bool query_changed;

    if (!get_query_cursor(cursor_term, &cursor) ||
        !require_open_query_cursor(cursor) ||
        !get_query(query_term, &query) ||
        !get_node(node_term, &node) ||
        !require_open_node(node)) {
        return FALSE;
    }
    query_changed = cursor->query != query;
    if (query_changed) {
        if (!query_retain(query, &native_query)) {
            return raise_tree_sitter_error("closed_query", "query handle is closed");
        }
    } else {
        if (!query_is_open(query, &native_query)) {
            return FALSE;
        }
    }
    if (PL_handle_signals() < 0) {
        if (query_changed) {
            query_release(query);
        }
        return FALSE;
    }
    tree_retain_node(node->tree);
    ts_query_cursor_exec(cursor->cursor, native_query, node->node);
    old_query = cursor->query;
    old_tree = cursor->tree;
    cursor->query = query;
    cursor->tree = node->tree;
    if (query_changed) {
        query_release(old_query);
    }
    tree_release_node(old_tree);
    return TRUE;
}

foreign_t pl_ts_query_cursor_set_byte_range(term_t cursor_term,
                                            term_t start_term,
                                            term_t end_term)
{
    rlm_ts_query_cursor_resource *resource;
    uint32_t start;
    uint32_t end;

    if (!get_query_cursor(cursor_term, &resource) ||
        !require_open_query_cursor(resource) ||
        !get_u32(start_term, "tree_sitter_byte_range", &start) ||
        !get_u32(end_term, "tree_sitter_byte_range", &end)) {
        return FALSE;
    }
    if (!ts_query_cursor_set_byte_range(resource->cursor, start, end)) {
        return PL_domain_error("tree_sitter_byte_range", start_term);
    }
    return TRUE;
}

foreign_t pl_ts_query_cursor_set_point_range(term_t cursor_term,
                                             term_t start_term,
                                             term_t end_term)
{
    rlm_ts_query_cursor_resource *resource;
    TSPoint start;
    TSPoint end;

    if (!get_query_cursor(cursor_term, &resource) ||
        !require_open_query_cursor(resource) ||
        !get_point(start_term, &start) ||
        !get_point(end_term, &end)) {
        return FALSE;
    }
    if (!ts_query_cursor_set_point_range(resource->cursor, start, end)) {
        return PL_domain_error("tree_sitter_point_range", start_term);
    }
    return TRUE;
}

foreign_t pl_ts_query_cursor_set_match_limit(term_t cursor_term,
                                             term_t limit_term)
{
    rlm_ts_query_cursor_resource *resource;
    uint32_t limit;

    if (!get_query_cursor(cursor_term, &resource) ||
        !require_open_query_cursor(resource) ||
        !get_u32(limit_term, "tree_sitter_match_limit", &limit)) {
        return FALSE;
    }
    ts_query_cursor_set_match_limit(resource->cursor, limit);
    return TRUE;
}

foreign_t pl_ts_query_cursor_did_exceed_match_limit(term_t cursor_term)
{
    rlm_ts_query_cursor_resource *resource;

    if (!get_query_cursor(cursor_term, &resource) ||
        !require_open_query_cursor(resource)) {
        return FALSE;
    }
    return ts_query_cursor_did_exceed_match_limit(resource->cursor) ? TRUE : FALSE;
}

static int unify_match(term_t match_term,
                       rlm_ts_query_cursor_resource *cursor,
                       const TSQueryMatch *match)
{
    term_t captures = PL_new_term_ref();
    term_t head = PL_new_term_ref();
    term_t capture_args = PL_new_term_refs(2);
    term_t capture = PL_new_term_ref();
    term_t match_args = PL_new_term_refs(3);
    term_t value = PL_new_term_ref();
    uint32_t index;

    if (!captures || !head || !capture_args || !capture ||
        !match_args || !value || !PL_put_nil(captures)) {
        return PL_resource_error("memory");
    }
    for (index = match->capture_count; index > 0; index--) {
        const TSQueryCapture *item = &match->captures[index - 1];
        if (!PL_put_integer(capture_args + 0, item->index) ||
            !unify_node(capture_args + 1, cursor->tree, item->node) ||
            !PL_cons_functor_v(capture, functor_query_capture2, capture_args) ||
            !PL_cons_list(head, capture, captures) ||
            !PL_put_term(captures, head)) {
            return FALSE;
        }
    }
    if (!PL_put_integer(match_args + 0, match->id) ||
        !PL_put_integer(match_args + 1, match->pattern_index) ||
        !PL_put_term(match_args + 2, captures) ||
        !PL_cons_functor_v(value, functor_query_match3, match_args)) {
        return FALSE;
    }
    return PL_unify(match_term, value);
}

foreign_t pl_ts_query_next_match(term_t cursor_term, term_t match_term)
{
    rlm_ts_query_cursor_resource *resource;
    TSQueryMatch match;

    if (!get_query_cursor(cursor_term, &resource) ||
        !require_open_query_cursor(resource)) {
        return FALSE;
    }
    if (PL_handle_signals() < 0 ||
        !ts_query_cursor_next_match(resource->cursor, &match)) {
        return FALSE;
    }
    if (PL_handle_signals() < 0) {
        return FALSE;
    }
    return unify_match(match_term, resource, &match);
}

foreign_t pl_ts_query_next_capture(term_t cursor_term,
                                   term_t match_term,
                                   term_t capture_index_term)
{
    rlm_ts_query_cursor_resource *resource;
    TSQueryMatch match;
    uint32_t capture_index;

    if (!get_query_cursor(cursor_term, &resource) ||
        !require_open_query_cursor(resource)) {
        return FALSE;
    }
    if (PL_handle_signals() < 0 ||
        !ts_query_cursor_next_capture(resource->cursor,
                                       &match,
                                       &capture_index)) {
        return FALSE;
    }
    if (PL_handle_signals() < 0 ||
        !unify_match(match_term, resource, &match)) {
        return FALSE;
    }
    return PL_unify_integer(capture_index_term, capture_index);
}
