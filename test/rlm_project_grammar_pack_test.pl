:- begin_tests(rlm_project_grammar_pack).

:- use_module('../prolog/rlm_project_source').
:- use_module('../prolog/rlm_project_grammar_pack').

test(standard_pack_covers_code_and_structured_documents) :-
    forall(member(Language,
                  [python, javascript, markdown, json, org, common_lisp, nim]),
           project_standard_grammar(Language, _, _)).

test(standard_pack_registration_is_inert_registry_data) :-
    setup_call_cleanup(
        project_source_registry_create(Registry),
        ( project_standard_grammar_pack_register(Registry,
                                                 '/trusted/grammar-pack',
                                                 ok(Results)),
          assertion(length(Results, 10)),
          ts_grammar(Registry, markdown, Markdown),
          assertion(Markdown.state == configured),
          assertion(Markdown.library == "/trusted/grammar-pack/markdown"),
          ts_grammar(Registry, common_lisp, CommonLisp),
          assertion(CommonLisp.symbol == tree_sitter_commonlisp)
        ),
        project_source_registry_destroy(Registry)
    ).

test(custom_pack_accepts_another_language_without_core_changes) :-
    setup_call_cleanup(
        project_source_registry_create(Registry),
        ( Entry = grammar_entry{language:custom_data,
                                file:custom_data,
                                symbol:tree_sitter_custom_data,
                                identity:package(custom_data, "1"),
                                version:"1",
                                extensions:['.custom-data'],
                                provenance:_{origin:test}},
          project_grammar_pack_register(Registry,
                                        '/trusted/custom-pack',
                                        [Entry],
                                        ok([Registration])),
          assertion(Registration.language == custom_data),
          assertion(Registration.outcome = ok(grammar_ref(custom_data, _))),
          project_source_language_parser(Registry,
                                         custom_data,
                                         tree_sitter)
        ),
        project_source_registry_destroy(Registry)
    ).

test(pack_rejects_path_escape) :-
    setup_call_cleanup(
        project_source_registry_create(Registry),
        ( Entry = grammar_entry{language:bad,
                                file:'../bad.so',
                                symbol:tree_sitter_bad,
                                identity:bad,
                                version:"1",
                                provenance:_{}},
          project_grammar_pack_register(Registry,
                                        '/trusted/pack',
                                        [Entry],
                                        error(Error)),
          assertion(Error.kind == invalid_entry),
          assertion(\+ ts_grammar(Registry, bad, _))
        ),
        project_source_registry_destroy(Registry)
    ).

test(invalid_later_entry_does_not_partially_register_pack) :-
    setup_call_cleanup(
        project_source_registry_create(Registry),
        ( Valid = grammar_entry{language:first_custom,
                                file:first_custom,
                                symbol:tree_sitter_first_custom,
                                identity:first_custom,
                                version:"1",
                                provenance:_{}},
          Invalid = grammar_entry{language:bad,
                                  file:'../bad.so',
                                  symbol:tree_sitter_bad,
                                  identity:bad,
                                  version:"1",
                                  provenance:_{}},
          project_grammar_pack_register(Registry,
                                        '/trusted/pack',
                                        [Valid, Invalid],
                                        error(Error)),
          assertion(Error.kind == invalid_entry),
          assertion(\+ ts_grammar(Registry, first_custom, _)),
          assertion(\+ project_source_language_parser(Registry,
                                                      first_custom,
                                                      _))
        ),
        project_source_registry_destroy(Registry)
    ).

test(invalid_later_extensions_do_not_partially_register_pack) :-
    setup_call_cleanup(
        project_source_registry_create(Registry),
        ( Valid = grammar_entry{language:first_custom,
                                file:first_custom,
                                symbol:tree_sitter_first_custom,
                                identity:first_custom,
                                version:"1",
                                provenance:_{}},
          Invalid = grammar_entry{language:bad_extensions,
                                  file:bad_extensions,
                                  symbol:tree_sitter_bad_extensions,
                                  identity:bad_extensions,
                                  version:"1",
                                  extensions:not_a_list,
                                  provenance:_{}},
          project_grammar_pack_register(Registry,
                                        '/trusted/pack',
                                        [Valid, Invalid],
                                        error(Error)),
          assertion(Error.kind == invalid_entry),
          assertion(\+ ts_grammar(Registry, first_custom, _))
        ),
        project_source_registry_destroy(Registry)
    ).

test(pack_rejects_windows_style_path_escape) :-
    setup_call_cleanup(
        project_source_registry_create(Registry),
        ( Entry = grammar_entry{language:bad,
                                file:'..\\bad.dll',
                                symbol:tree_sitter_bad,
                                identity:bad,
                                version:"1",
                                provenance:_{}},
          project_grammar_pack_register(Registry,
                                        '/trusted/pack',
                                        [Entry],
                                        error(Error)),
          assertion(Error.kind == invalid_entry)
        ),
        project_source_registry_destroy(Registry)
    ).

:- end_tests(rlm_project_grammar_pack).
