:- begin_tests(rlm_skill).

:- use_module('../prolog/rlm_skill').
:- use_module('../prolog/rlm_completion').
:- use_module('support/skill_test_support').

selected_names(Compilation, Names) :-
    findall(Name,
            ( member(Selection, Compilation.selected),
              Name = Selection.name
            ),
            Names).

rejection_reason(Compilation, Name, Reason) :-
    member(Rejection, Compilation.rejected),
    Rejection.name == Name,
    member(Reason, Rejection.reasons).

test(lexical_match_selects_only_relevant_skill,
     [ setup(skill_test_support:fixture_open(Root, Catalog)),
       cleanup(skill_test_support:fixture_close(Root))
     ]) :-
    skill_compile(Catalog,
                  "review this diff please",
                  [],
                  ok(Compilation)),
    selected_names(Compilation, Names),
    assertion(Names == ['code-review']),
    skill_render(Compilation, Rendered),
    assertion(sub_string(Rendered, _, _, _, "REVIEW_BODY_SENTINEL")),
    assertion(\+ sub_string(Rendered, _, _, _, "TDD_BODY_SENTINEL")).

test(explicit_only_skill_does_not_activate_lexically,
     [ setup(skill_test_support:fixture_open(Root, Catalog)),
       cleanup(skill_test_support:fixture_close(Root))
     ]) :-
    skill_compile(Catalog,
                  "implement this requested change",
                  [],
                  ok(Compilation)),
    selected_names(Compilation, Names),
    assertion(\+ memberchk(implement, Names)),
    assertion(rejection_reason(Compilation,
                               implement,
                               explicit_selection_required)).

test(explicit_selection_activates_explicit_only_skill,
     [ setup(skill_test_support:fixture_open(Root, Catalog)),
       cleanup(skill_test_support:fixture_close(Root))
     ]) :-
    skill_compile(Catalog,
                  "implement this requested change",
                  [explicit_skills([implement])],
                  ok(Compilation)),
    selected_names(Compilation, Names),
    assertion(memberchk(implement, Names)),
    assertion(sub_string(Compilation.rendered,
                         _, _, _,
                         "IMPLEMENT_BODY_SENTINEL")).

test(negation_suppresses_ordinary_activation,
     [ setup(skill_test_support:fixture_open(Root, Catalog)),
       cleanup(skill_test_support:fixture_close(Root))
     ]) :-
    skill_compile(Catalog,
                  "review this diff but do not use code review",
                  [],
                  ok(Compilation)),
    selected_names(Compilation, Names),
    assertion(\+ memberchk('code-review', Names)),
    assertion(rejection_reason(Compilation,
                               'code-review',
                               negated_by_input)).

test(required_dependencies_close_transitively_before_parent,
     [ setup(skill_test_support:fixture_open(Root, Catalog)),
       cleanup(skill_test_support:fixture_close(Root))
     ]) :-
    skill_compile(Catalog,
                  "please diagnose bug in the runtime",
                  [],
                  ok(Compilation)),
    selected_names(Compilation, Names),
    assertion(Names == [tdd, diagnose]),
    assertion(sub_string(Compilation.rendered,
                         _, _, _,
                         "TDD_BODY_SENTINEL")),
    assertion(sub_string(Compilation.rendered,
                         _, _, _,
                         "DIAGNOSE_BODY_SENTINEL")).

test(compilation_fingerprint_is_stable,
     [ setup(skill_test_support:fixture_open(Root, Catalog)),
       cleanup(skill_test_support:fixture_close(Root))
     ]) :-
    skill_compile(Catalog,
                  "review this diff please",
                  [],
                  ok(A)),
    skill_compile(Catalog,
                  "review this diff please",
                  [],
                  ok(B)),
    assertion(A.fingerprint == B.fingerprint).

test(explicit_selection_fails_closed_on_skill_prompt_budget,
     [ setup(skill_test_support:fixture_open(Root, Catalog)),
       cleanup(skill_test_support:fixture_close(Root))
     ]) :-
    skill_compile(Catalog,
                  "review this diff",
                  [ explicit_skills(['code-review']),
                    max_skill_prompt_tokens(1)
                  ],
                  error(Error)),
    assertion(Error.phase == compile),
    assertion(Error.kind == rejected),
    assertion(Error.detail = explicit_skill_budget_exceeded('code-review',
                                                             _,
                                                             1)).

test(skill_resources_are_confined_to_skill_directory,
     [ setup(skill_test_support:fixture_open(Root, Catalog)),
       cleanup(skill_test_support:fixture_close(Root))
     ]) :-
    skill_resource_read(Catalog,
                        'code-review',
                        'guide.md',
                        ok(Resource)),
    assertion(Resource.text == "RESOURCE_SENTINEL\n"),
    skill_resource_read(Catalog,
                        'code-review',
                        '../tdd/SKILL.md',
                        error(Error)),
    assertion(Error.phase == resource),
    assertion(Error.kind == rejected),
    assertion(Error.detail = resource_path_escape(_)).

test(completion_injects_host_selected_skill_before_planner,
     [ setup(skill_test_support:fixture_open(Root, Catalog)),
       cleanup(skill_test_support:fixture_close(Root))
     ]) :-
    Options = [ planner_handler(skill_test_support:capture_skill_planner("REVIEW_BODY_SENTINEL")),
                capabilities([rlm, model(openrouter)]),
                child_capabilities([model(openrouter)]),
                skill_catalog(Catalog)
              ],
    rlm_completion("review this diff",
                   text("opaque"),
                   Options,
                   ok(Result)),
    assertion(Result.value == "skill-ok"),
    assertion(Result.prompt_compilation.skills.selected \== []).

test(completion_without_catalog_preserves_empty_skill_path) :-
    Options = [ planner_handler(skill_test_support:capture_no_skill_planner),
                capabilities([rlm, model(openrouter)]),
                child_capabilities([model(openrouter)])
              ],
    rlm_completion("review this diff",
                   text("opaque"),
                   Options,
                   ok(Result)),
    assertion(Result.value == "no-skill-ok"),
    assertion(\+ get_dict(prompt_compilation, Result, _)).

:- end_tests(rlm_skill).
