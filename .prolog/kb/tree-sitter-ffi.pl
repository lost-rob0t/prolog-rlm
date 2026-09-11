/* Verified discoveries about the Tree-sitter FFI and query engine. */

% Latent #97/#94 FFI defect found by the #98 semantic layer (2026-09-10):
% unify_match in c/rlm_tree_sitter_query.c reused the capture argument slot
% across capture iterations, so PL_unify_blob compared the first capture's
% blob against the second and every multi-capture match failed silently.
% All #97 tests used single-capture patterns, which is why it was latent.
% Fix: PL_put_variable(capture_args + 1) before each unify_node call.
ffi_defect(multi_capture_matches_dropped,
           'c/rlm_tree_sitter_query.c unify_match',
           'matches with 2+ captures never reached Prolog',
           'PL_put_variable(capture_args + 1) before each unify_node').
ffi_regression_test(multi_capture_matches_publish_every_capture,
                    'test/rlm_tree_sitter_query_test.pl').

% Field-constrained query patterns work through the FFI (tree-sitter 0.25.10
% runtime, ABI 13-15 grammars verified); the earlier 0-match observation was
% caused by the same unify_match defect, not by field support.
ffi_supports(field_queries).

% Common-lisp grammar shapes used by the semantic adapter:
% top-level forms are list_lit; def* forms are a defun node whose
% defun_header children are defun_keyword, sym_lit(name), params.
% Calls need a following element so parameter lists are not calls; the
% keyword node inside defun_keyword carries the def* keyword text.
cl_grammar(shape, 'list_lit with defun/defun_header/defun_keyword').