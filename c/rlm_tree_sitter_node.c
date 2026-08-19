#include "rlm_tree_sitter_internal.h"

foreign_t pl_ts_node_type(term_t node_term, term_t type_term)
{
    rlm_ts_node_resource *node;
    const char *type;

    if (!get_node(node_term, &node) || !require_open_node(node)) {
        return FALSE;
    }
    type = ts_node_type(node->node);
    if (!type) {
        return raise_tree_sitter_error("node_type", "Tree-sitter returned NULL node type");
    }
    return PL_unify_atom_chars(type_term, type);
}

foreign_t pl_ts_node_named(term_t node_term)
{
    rlm_ts_node_resource *node;

    if (!get_node(node_term, &node) || !require_open_node(node)) {
        return FALSE;
    }
    return ts_node_is_named(node->node) ? TRUE : FALSE;
}

foreign_t pl_ts_node_has_error(term_t node_term)
{
    rlm_ts_node_resource *node;

    if (!get_node(node_term, &node) || !require_open_node(node)) {
        return FALSE;
    }
    return ts_node_has_error(node->node) ? TRUE : FALSE;
}

foreign_t pl_ts_node_start_byte(term_t node_term, term_t byte_term)
{
    rlm_ts_node_resource *node;

    if (!get_node(node_term, &node) || !require_open_node(node)) {
        return FALSE;
    }
    return PL_unify_integer(byte_term, ts_node_start_byte(node->node));
}

foreign_t pl_ts_node_end_byte(term_t node_term, term_t byte_term)
{
    rlm_ts_node_resource *node;

    if (!get_node(node_term, &node) || !require_open_node(node)) {
        return FALSE;
    }
    return PL_unify_integer(byte_term, ts_node_end_byte(node->node));
}

foreign_t pl_ts_node_start_point(term_t node_term, term_t point_term)
{
    rlm_ts_node_resource *node;

    if (!get_node(node_term, &node) || !require_open_node(node)) {
        return FALSE;
    }
    return unify_point(point_term, ts_node_start_point(node->node));
}

foreign_t pl_ts_node_end_point(term_t node_term, term_t point_term)
{
    rlm_ts_node_resource *node;

    if (!get_node(node_term, &node) || !require_open_node(node)) {
        return FALSE;
    }
    return unify_point(point_term, ts_node_end_point(node->node));
}

foreign_t pl_ts_node_child_count(term_t node_term, term_t count_term)
{
    rlm_ts_node_resource *node;

    if (!get_node(node_term, &node) || !require_open_node(node)) {
        return FALSE;
    }
    return PL_unify_integer(count_term, ts_node_child_count(node->node));
}

foreign_t pl_ts_node_child(term_t node_term, term_t index_term, term_t child_term)
{
    rlm_ts_node_resource *node;
    int index;
    uint32_t count;
    TSNode child;

    if (!get_node(node_term, &node) || !require_open_node(node)) {
        return FALSE;
    }
    if (!PL_get_integer_ex(index_term, &index)) {
        return FALSE;
    }
    count = ts_node_child_count(node->node);
    if (index < 0 || (uint32_t)index >= count) {
        return PL_domain_error("tree_sitter_child_index", index_term);
    }
    child = ts_node_child(node->node, (uint32_t)index);
    return unify_node(child_term, node->tree, child);
}

foreign_t pl_ts_node_named_child(term_t node_term,
                                 term_t index_term,
                                 term_t child_term)
{
    rlm_ts_node_resource *node;
    int index;
    uint32_t count;
    TSNode child;

    if (!get_node(node_term, &node) || !require_open_node(node)) {
        return FALSE;
    }
    if (!PL_get_integer_ex(index_term, &index)) {
        return FALSE;
    }
    count = ts_node_named_child_count(node->node);
    if (index < 0 || (uint32_t)index >= count) {
        return PL_domain_error("tree_sitter_named_child_index", index_term);
    }
    child = ts_node_named_child(node->node, (uint32_t)index);
    return unify_node(child_term, node->tree, child);
}

foreign_t pl_ts_node_field(term_t node_term, term_t field_term, term_t child_term)
{
    rlm_ts_node_resource *node;
    char *field = NULL;
    size_t field_length = 0;
    TSNode child;

    if (!get_node(node_term, &node) || !require_open_node(node)) {
        return FALSE;
    }
    if (!get_utf8_text(field_term, &field, &field_length)) {
        return FALSE;
    }
    if (field_length > UINT32_MAX) {
        PL_free(field);
        return PL_representation_error("tree_sitter_field_name_length");
    }
    child = ts_node_child_by_field_name(node->node, field, (uint32_t)field_length);
    PL_free(field);
    if (ts_node_is_null(child)) {
        return FALSE;
    }
    return unify_node(child_term, node->tree, child);
}
