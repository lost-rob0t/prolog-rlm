:- module(rlm_project_grammar_pack,
          [ rlm_project_grammar_pack_ready/0,
            project_standard_grammar/3,
            project_standard_grammar_pack_register/3,
            project_grammar_pack_register/4
          ]).

/** <module> Inert standard and host-provided Tree-sitter grammar packs

Grammar-pack registration records trusted native-library metadata through
rlm_project_source.  It never loads or activates a grammar.  Hosts may register
additional languages with the same entry format; the standard list is only a
portable baseline for common project code and structured documents.
*/

:- use_module(library(apply)).
:- use_module(library(filesex)).
:- use_module(rlm_project_source).

rlm_project_grammar_pack_ready.

project_standard_grammar(c, c, tree_sitter_c).
project_standard_grammar(lua, lua, tree_sitter_lua).
project_standard_grammar(tree_sitter_query, query, tree_sitter_query).
project_standard_grammar(python, python, tree_sitter_python).
project_standard_grammar(javascript, javascript, tree_sitter_javascript).
project_standard_grammar(markdown, markdown, tree_sitter_markdown).
project_standard_grammar(json, json, tree_sitter_json).
project_standard_grammar(org, org, tree_sitter_org).
project_standard_grammar(common_lisp, common_lisp, tree_sitter_commonlisp).
project_standard_grammar(nim, nim, tree_sitter_nim).

project_standard_grammar_pack_register(Registry, Directory, Outcome) :-
    findall(grammar_entry{language:Language,
                          file:File,
                          symbol:Symbol,
                          identity:standard_grammar(Language),
                          version:"nixpkgs-lock",
                          provenance:_{origin:prolog_rlm_standard_pack}},
            project_standard_grammar(Language, File, Symbol),
            Entries),
    project_grammar_pack_register(Registry, Directory, Entries, Outcome).

project_grammar_pack_register(Registry, Directory0, Entries, Outcome) :-
    catch(project_grammar_pack_register_(Registry,
                                         Directory0,
                                         Entries,
                                         Outcome),
          Exception,
          grammar_pack_exception(Exception, Outcome)).

project_grammar_pack_register_(Registry, Directory0, Entries, Outcome) :-
    normalize_directory(Directory0, Directory),
    (   is_list(Entries)
    ->  true
    ;   throw(grammar_pack_fault(invalid_entries(Entries)))
    ),
    with_mutex(rlm_project_source_registry,
               project_grammar_pack_register_locked(Registry,
                                                    Directory,
                                                    Entries,
                                                    Outcome)).

project_grammar_pack_register_locked(Registry, Directory, Entries, Outcome) :-
    maplist(validate_grammar_entry(Directory), Entries),
    transaction(maplist(register_grammar_entry(Registry, Directory),
                        Entries,
                        Results)),
    Outcome = ok(Results).

validate_grammar_entry(Directory, Entry) :-
    require_entry(Entry, _, FileName, _, _, _, _),
    directory_file_path(Directory, FileName, _).

register_grammar_entry(Registry, Directory, Entry, Result) :-
    require_entry(Entry,
                  Language,
                  FileName,
                  Symbol,
                  Identity,
                  Version,
                  Provenance),
    ensure_tree_sitter_language(Registry, Language, Entry, Provenance),
    directory_file_path(Directory, FileName, Library),
    Grammar = _{identity:Identity,
                library:Library,
                symbol:Symbol,
                abi:unknown,
                version:Version,
                provenance:Provenance},
    ts_grammar_register(Registry, Language, Grammar, RegisterOutcome),
    require_registration_success(Language, RegisterOutcome),
    Result = grammar_registration{language:Language,
                                  outcome:RegisterOutcome}.

require_registration_success(_, ok(_)) :- !.
require_registration_success(Language, Outcome) :-
    throw(grammar_pack_fault(grammar_register_failed(Language, Outcome))).

ensure_tree_sitter_language(Registry, Language, _, _) :-
    project_source_language_parser(Registry, Language, tree_sitter),
    !.
ensure_tree_sitter_language(Registry, Language, _, _) :-
    project_source_language_parser(Registry, Language, Existing),
    !,
    throw(grammar_pack_fault(parser_backend_conflict(Language, Existing))).
ensure_tree_sitter_language(Registry, Language, Entry, Provenance) :-
    (   get_dict(extensions, Entry, Extensions)
    ->  Meta = _{origin:grammar_pack,
                  extensions:Extensions,
                  provenance:Provenance}
    ;   Meta = _{origin:grammar_pack, provenance:Provenance}
    ),
    project_source_language_register(Registry,
                                     Language,
                                     tree_sitter,
                                     Meta,
                                     RegisterOutcome),
    (   RegisterOutcome = ok(_)
    ->  true
    ;   throw(grammar_pack_fault(language_register_failed(Language,
                                                          RegisterOutcome)))
    ).

require_entry(Entry,
              Language,
              FileName,
              Symbol,
              Identity,
              Version,
              Provenance) :-
    is_dict(Entry),
    get_dict(language, Entry, Language),
    atom(Language),
    get_dict(file, Entry, File0),
    normalize_file_name(File0, FileName),
    get_dict(symbol, Entry, Symbol),
    atom(Symbol),
    get_dict(identity, Entry, Identity),
    ground(Identity),
    get_dict(version, Entry, Version),
    (atom(Version); string(Version)),
    get_dict(provenance, Entry, Provenance),
    is_dict(Provenance),
    dict_pairs(Provenance, _, ProvenancePairs),
    maplist(ground_pair_value, ProvenancePairs),
    validate_entry_extensions(Entry),
    !.
require_entry(Entry, _, _, _, _, _, _) :-
    throw(grammar_pack_fault(invalid_entry(Entry))).

ground_pair_value(_-Value) :-
    ground(Value).

validate_entry_extensions(Entry) :-
    (   get_dict(extensions, Entry, Extensions)
    ->  is_list(Extensions),
        maplist(valid_extension, Extensions)
    ;   true
    ).

valid_extension(Value) :-
    (atom(Value); string(Value)),
    (   atom(Value)
    ->  Extension = Value
    ;   atom_string(Extension, Value)
    ),
    atom_concat('.', Suffix, Extension),
    Suffix \== '',
    \+ sub_atom(Suffix, _, _, _, '/'),
    \+ sub_atom(Suffix, _, _, _, '\\').

normalize_directory(Value, Directory) :-
    (   atom(Value)
    ->  Directory = Value
    ;   string(Value)
    ->  atom_string(Directory, Value)
    ;   throw(grammar_pack_fault(invalid_directory(Value)))
    ).

normalize_file_name(Value, FileName) :-
    (   atom(Value)
    ->  FileName = Value
    ;   string(Value)
    ->  atom_string(FileName, Value)
    ;   fail
    ),
    \+ is_absolute_file_name(FileName),
    \+ sub_atom(FileName, _, _, _, '/'),
    \+ sub_atom(FileName, _, _, _, '\\'),
    FileName \== '..'.

grammar_pack_exception(grammar_pack_fault(Detail), error(Error)) :-
    !,
    fault_kind(Detail, Kind),
    Error = grammar_pack_error{kind:Kind, detail:Detail}.
grammar_pack_exception(Exception, error(Error)) :-
    Error = grammar_pack_error{kind:grammar_pack_exception,
                               exception:Exception}.

fault_kind(Detail, Kind) :-
    compound(Detail),
    !,
    functor(Detail, Kind, _).
fault_kind(Kind, Kind).
