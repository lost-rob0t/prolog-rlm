:- module(rlm_tree_sitter,
          [ rlm_tree_sitter_ready/0,
            ts_runtime_abi/2,
            ts_language_load/3,
            ts_language_abi/2,
            ts_language_compatible/2,
            ts_language_close/2,
            ts_parser_create/1,
            ts_parser_set_language/3,
            ts_parser_close/2,
            ts_parse_string/3,
            ts_tree_root/2,
            ts_tree_close/2,
            ts_node_type/2,
             ts_node_named/1,
             ts_node_has_error/1,
             ts_node_is_error/1,
             ts_node_is_missing/1,
            ts_node_start_byte/2,
            ts_node_end_byte/2,
            ts_node_start_point/2,
             ts_node_end_point/2,
             ts_node_child_count/2,
             ts_node_named_child_count/2,
             ts_node_child/3,
             ts_node_child_field_name/3,
             ts_node_named_child/3,
             ts_node_named_child_field_name/3,
            ts_node_field/3
          ]).

/** <module> Direct SWI-Prolog Tree-sitter binding

This module is the deliberately small native parser boundary tracked by #94.
It binds SWI-Prolog directly to libtree-sitter through the SWI foreign language
interface. Language-specific extraction, Project facts, query packs, SPEC and
VERIFY do not live here.

Grammar shared libraries are host-trusted native code. Loading one may execute
native library initializers, so this predicate is an operator/runtime API and
must not be exposed as ambient model authority. Later grammar registries narrow
which host-provided libraries are selectable.

Parser and tree handles are thread-affine. A handle must be used from the
SWI-Prolog thread that created it. Cross-thread access raises a structured
`tree_sitter_error(wrong_thread, _)` instead of sharing mutable Tree-sitter
objects unsafely.
*/

:- use_module(library(shlib)).

:- prolog_load_context(directory, ModuleDirectory),
   directory_file_path(ModuleDirectory, '../foreign', ForeignDirectory),
   current_prolog_flag(shared_object_extension, Extension),
   atomic_list_concat([rlm_tree_sitter, Extension], '.', FileName),
   directory_file_path(ForeignDirectory, FileName, ForeignLibrary),
   use_foreign_library(ForeignLibrary).

rlm_tree_sitter_ready :-
    ts_runtime_abi(Minimum, Maximum),
    integer(Minimum),
    integer(Maximum),
    Minimum =< Maximum.

ts_runtime_abi(Minimum, Maximum) :-
    '$ts_runtime_abi'(Minimum, Maximum).

ts_language_load(LibraryPath, EntrySymbol, Language) :-
    '$ts_language_load'(LibraryPath, EntrySymbol, Language).

ts_language_abi(Language, Abi) :-
    '$ts_language_abi'(Language, Abi).

ts_language_compatible(Language, Outcome) :-
    catch(( ts_language_abi(Language, Abi),
            ts_runtime_abi(Minimum, Maximum),
            (   between(Minimum, Maximum, Abi)
            ->  Outcome = ok(compatible(Abi, Minimum, Maximum))
            ;   Outcome = error(incompatible_language_abi(Abi,
                                                          Minimum,
                                                          Maximum))
            )
          ),
          Exception,
          Outcome = error(Exception)).

ts_language_close(Language, Outcome) :-
    '$ts_language_close'(Language, Status),
    Outcome = ok(Status).

ts_parser_create(Parser) :-
    '$ts_parser_create'(Parser).

ts_parser_set_language(Parser, Language, Outcome) :-
    '$ts_parser_set_language'(Parser, Language, Status),
    Outcome = ok(Status).

ts_parser_close(Parser, Outcome) :-
    '$ts_parser_close'(Parser, Status),
    Outcome = ok(Status).

ts_parse_string(Parser, Source, Tree) :-
    '$ts_parse_string'(Parser, Source, Tree).

ts_tree_root(Tree, Node) :-
    '$ts_tree_root'(Tree, Node).

ts_tree_close(Tree, Outcome) :-
    '$ts_tree_close'(Tree, Status),
    Outcome = ok(Status).

ts_node_type(Node, Type) :-
    '$ts_node_type'(Node, Type).

ts_node_named(Node) :-
    '$ts_node_named'(Node).

ts_node_has_error(Node) :-
    '$ts_node_has_error'(Node).

ts_node_is_error(Node) :-
    '$ts_node_is_error'(Node).

ts_node_is_missing(Node) :-
    '$ts_node_is_missing'(Node).

ts_node_start_byte(Node, Byte) :-
    '$ts_node_start_byte'(Node, Byte).

ts_node_end_byte(Node, Byte) :-
    '$ts_node_end_byte'(Node, Byte).

ts_node_start_point(Node, Point) :-
    '$ts_node_start_point'(Node, Point).

ts_node_end_point(Node, Point) :-
    '$ts_node_end_point'(Node, Point).

ts_node_child_count(Node, Count) :-
    '$ts_node_child_count'(Node, Count).

ts_node_named_child_count(Node, Count) :-
    '$ts_node_named_child_count'(Node, Count).

ts_node_child(Node, Index, Child) :-
    '$ts_node_child'(Node, Index, Child).

ts_node_child_field_name(Node, Index, FieldName) :-
    '$ts_node_child_field_name'(Node, Index, FieldName).

ts_node_named_child(Node, Index, Child) :-
    '$ts_node_named_child'(Node, Index, Child).

ts_node_named_child_field_name(Node, Index, FieldName) :-
    '$ts_node_named_child_field_name'(Node, Index, FieldName).

ts_node_field(Node, FieldName, Child) :-
    '$ts_node_field'(Node, FieldName, Child).
