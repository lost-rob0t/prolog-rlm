:- begin_tests(rlm_skill_completion).

:- use_module('../prolog/rlm_skill').
:- use_module('../prolog/rlm_skill_completion', []).
:- use_module('../prolog/rlm_completion', []).
:- use_module('support/skill_test_support').

:- dynamic skill_completion_test_directory/1.
:- prolog_load_context(directory, TestDirectory),
   assertz(skill_completion_test_directory(TestDirectory)).

fixture_catalog(Catalog) :-
    skill_completion_test_directory(TestDir),
    directory_file_path(TestDir, 'fixtures/skills', Root),
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)).

test(low_level_completion_inherits_prolog_skill_activation,
     [setup(skill_test_support:reset_capture)]) :-
    fixture_catalog(Catalog),
    Options = [ planner_handler(skill_test_support:capture_planner),
                capabilities([rlm, model(openrouter)]),
                child_capabilities([model(openrouter)]),
                skill_catalog(Catalog),
                skill_min_score(20)
              ],
    rlm_completion:rlm_completion(
        "Build this feature test first with integration tests",
        text("opaque"),
        Options,
        Outcome),
    assertion(Outcome = ok(Result)),
    assertion(Result.value == "skill-ok"),
    skill_test_support:captured_prompt(Prompt),
    assertion(sub_string(Prompt, _, _, _, "TDD_SKILL_MARKER")),
    assertion(\+ sub_string(Prompt, _, _, _, "GRILL_SKILL_MARKER")).

test(precompiled_marker_does_not_duplicate_skill_prompt,
     [setup(skill_test_support:reset_capture)]) :-
    fixture_catalog(Catalog),
    BaseOptions = [ planner_handler(skill_test_support:capture_planner),
                    capabilities([rlm, model(openrouter)]),
                    child_capabilities([model(openrouter)]),
                    skill_catalog(Catalog),
                    skill_min_score(20)
                  ],
    rlm_skill_completion:skill_completion_options(
        "Build this feature test first with integration tests",
        BaseOptions,
        ok(Prepared)),
    rlm_completion:rlm_completion(
        "Build this feature test first with integration tests",
        text("opaque"),
        Prepared.options,
        Outcome),
    assertion(Outcome = ok(_)),
    skill_test_support:captured_prompt(Prompt),
    findall(Start,
            sub_string(Prompt, Start, _, _, "TDD_SKILL_MARKER"),
            Starts),
    assertion(Starts = [_]).

:- end_tests(rlm_skill_completion).
