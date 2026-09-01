#include "rlm_tree_sitter_internal.h"

PL_blob_t language_blob;
PL_blob_t parser_blob;
PL_blob_t tree_blob;
PL_blob_t node_blob;

functor_t functor_error2;
functor_t functor_tree_sitter_error2;
functor_t functor_point2;

install_t install(void)
{
    language_blob.magic = PL_BLOB_MAGIC;
    language_blob.flags = 0;
    language_blob.name = "rlm_tree_sitter_language";
    language_blob.release = release_language_blob;

    parser_blob.magic = PL_BLOB_MAGIC;
    parser_blob.flags = 0;
    parser_blob.name = "rlm_tree_sitter_parser";
    parser_blob.release = release_parser_blob;

    tree_blob.magic = PL_BLOB_MAGIC;
    tree_blob.flags = 0;
    tree_blob.name = "rlm_tree_sitter_tree";
    tree_blob.release = release_tree_blob;

    node_blob.magic = PL_BLOB_MAGIC;
    node_blob.flags = 0;
    node_blob.name = "rlm_tree_sitter_node";
    node_blob.release = release_node_blob;

    PL_register_blob_type(&language_blob);
    PL_register_blob_type(&parser_blob);
    PL_register_blob_type(&tree_blob);
    PL_register_blob_type(&node_blob);

    functor_error2 = PL_new_functor(PL_new_atom("error"), 2);
    functor_tree_sitter_error2 = PL_new_functor(PL_new_atom("tree_sitter_error"), 2);
    functor_point2 = PL_new_functor(PL_new_atom("point"), 2);

    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_runtime_abi", 2,
                                  (pl_function_t)pl_ts_runtime_abi, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_language_load", 3,
                                  (pl_function_t)pl_ts_language_load, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_language_abi", 2,
                                  (pl_function_t)pl_ts_language_abi, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_language_close", 2,
                                  (pl_function_t)pl_ts_language_close, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_parser_create", 1,
                                  (pl_function_t)pl_ts_parser_create, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_parser_set_language", 3,
                                  (pl_function_t)pl_ts_parser_set_language, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_parser_close", 2,
                                  (pl_function_t)pl_ts_parser_close, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_parse_string", 3,
                                  (pl_function_t)pl_ts_parse_string, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_tree_root", 2,
                                  (pl_function_t)pl_ts_tree_root, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_tree_close", 2,
                                  (pl_function_t)pl_ts_tree_close, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_type", 2,
                                  (pl_function_t)pl_ts_node_type, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_named", 1,
                                  (pl_function_t)pl_ts_node_named, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_has_error", 1,
                                  (pl_function_t)pl_ts_node_has_error, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_is_error", 1,
                                  (pl_function_t)pl_ts_node_is_error, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_is_missing", 1,
                                  (pl_function_t)pl_ts_node_is_missing, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_start_byte", 2,
                                  (pl_function_t)pl_ts_node_start_byte, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_end_byte", 2,
                                  (pl_function_t)pl_ts_node_end_byte, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_start_point", 2,
                                  (pl_function_t)pl_ts_node_start_point, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_end_point", 2,
                                  (pl_function_t)pl_ts_node_end_point, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_child_count", 2,
                                  (pl_function_t)pl_ts_node_child_count, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_named_child_count", 2,
                                  (pl_function_t)pl_ts_node_named_child_count, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_child", 3,
                                  (pl_function_t)pl_ts_node_child, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_child_field_name", 3,
                                  (pl_function_t)pl_ts_node_child_field_name, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_named_child", 3,
                                  (pl_function_t)pl_ts_node_named_child, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_named_child_field_name", 3,
                                  (pl_function_t)pl_ts_node_named_child_field_name, 0);
    PL_register_foreign_in_module("rlm_tree_sitter", "$ts_node_field", 3,
                                  (pl_function_t)pl_ts_node_field, 0);
}

install_t uninstall(void)
{
    PL_unregister_blob_type(&node_blob);
    PL_unregister_blob_type(&tree_blob);
    PL_unregister_blob_type(&parser_blob);
    PL_unregister_blob_type(&language_blob);
}
