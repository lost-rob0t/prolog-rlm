:- begin_tests(rlm_skill).

:- use_module('../prolog/rlm_skill').
:- use_module('../prolog/rlm', [rlm_completion/4]).
:- use_module('support/skill_test_support').
:- use_module(library(filesex)).

:- dynamic skill_test_directory/1.
:- prolog_load_context(directory, TestDirectory),
   assertz(skill_test_directory(TestDirectory)).

fixture_root(Root) :-
    skill_test_directory(TestDir),
    directory_file_path(TestDir, 'fixtures/skills', Root).

fixture_catalog(Catalog) :-
    fixture_root(Root),
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)).

selected_names(Compiled, Names) :-
    findall(Name,
            ( member(Selection, Compiled.selected),
              Name = Selection.name
            ),
            Names).

test(loader_discovers_metadata_without_loading_body) :-
    fixture_catalog(Catalog),
    skill_catalog_skill(Catalog, tdd, Tdd),
    skill_catalog_skill(Catalog, 'grill-me', Grill),
    assertion(Tdd.invocation == automatic),
    assertion(Grill.invocation == explicit_user),
    assertion(Tdd.description \== ""),
    assertion(\+ get_dict(instructions, Tdd, _)).

test(prolog_auto_activates_matching_skill_only) :-
    fixture_catalog(Catalog),
    skill_compile(Catalog,
                  "Build this feature test first with integration tests",
                  [skill_min_score(20)],
                  ok(Compiled)),
    selected_names(Compiled, Names),
    assertion(memberchk(tdd, Names)),
    assertion(\+ memberchk('grill-me', Names)),
    assertion(\+ memberchk(unrelated, Names)).

test(explicit_user_skill_is_not_auto_activated) :-
    fixture_catalog(Catalog),
    skill_compile(Catalog,
                  "Interview me relentlessly about this design",
                  [skill_min_score(20)],
                  ok(Compiled)),
    selected_names(Compiled, Names),
    assertion(\+ memberchk('grill-me', Names)).

test(trusted_explicit_selection_activates_explicit_user_skill) :-
    fixture_catalog(Catalog),
    skill_compile(Catalog,
                  "Interview me about this design",
                  [ explicit_skills(['grill-me']),
                    skill_min_score(20)
                  ],
                  ok(Compiled)),
    selected_names(Compiled, Names),
    assertion(memberchk('grill-me', Names)).

test(negation_suppresses_automatic_activation) :-
    fixture_catalog(Catalog),
    skill_compile(Catalog,
                  "Do not use tdd; build this feature test first",
                  [skill_min_score(20)],
                  ok(Compiled)),
    selected_names(Compiled, Names),
    assertion(\+ memberchk(tdd, Names)),
    member(Rejection, Compiled.rejected),
    Rejection.name == tdd,
    assertion(Rejection.reason == negated_by_input).

test(required_dependency_closes_transitively) :-
    fixture_catalog(Catalog),
    Rules = [requires(tdd, 'diagnosing-bugs')],
    skill_compile(Catalog,
                  "Build this feature test first",
                  [ skill_rules(Rules),
                    skill_min_score(20)
                  ],
                  ok(Compiled)),
    selected_names(Compiled, Names),
    assertion(memberchk(tdd, Names)),
    assertion(memberchk('diagnosing-bugs', Names)).

test(compilation_fingerprint_is_stable) :-
    fixture_catalog(Catalog),
    Options = [skill_min_score(20)],
    skill_compile(Catalog,
                  "Debug this failing regression",
                  Options,
                  ok(First)),
    skill_compile(Catalog,
                  "Debug this failing regression",
                  Options,
                  ok(Second)),
    assertion(First.fingerprint == Second.fingerprint).

test(selected_body_and_resources_are_lazy_then_rendered) :-
    fixture_catalog(Catalog),
    skill_compile(Catalog,
                  "Build this feature test first with integration tests",
                  [skill_min_score(20)],
                  ok(Compiled)),
    skill_prompt_fragment(Compiled, Prompt),
    assertion(sub_string(Prompt, _, _, _, "TDD_SKILL_MARKER")),
    assertion(sub_string(Prompt, _, _, _, "TDD_RESOURCE_MARKER")),
    assertion(\+ sub_string(Prompt, _, _, _, "GRILL_SKILL_MARKER")),
    assertion(\+ sub_string(Prompt, _, _, _, "UNRELATED_SKILL_MARKER")).

test(nested_shell_resource_is_lazy_and_rendered_only_after_selection,
     [setup(nested_resource_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)),
    skill_catalog_skill(Catalog, 'script-skill', Skill),
    member(Resource, Skill.resources),
    assertion(Resource.name == 'scripts/template.sh'),
    assertion(\+ get_dict(content, Resource, _)),
    skill_compile(Catalog,
                  "script skill",
                  [ explicit_skills(['script-skill']),
                    skill_min_score(9999)
                  ],
                  ok(Compiled)),
    skill_prompt_fragment(Compiled, Prompt),
    assertion(sub_string(Prompt, _, _, _, "NESTED_SCRIPT_RESOURCE_MARKER")),
    assertion(sub_string(Prompt, _, _, _, "resources (inert text)")).

test(resource_read_is_confined_to_skill_directory) :-
    fixture_catalog(Catalog),
    skill_catalog_skill(Catalog, tdd, Skill),
    skill_read_resource(Skill, "tests.md", ok(Content)),
    assertion(sub_string(Content, _, _, _, "TDD_RESOURCE_MARKER")),
    skill_read_resource(Skill, "../../../outside.txt", error(Error)),
    assertion(Error.phase == resource),
    assertion(Error.kind == skill_fault).

test(completion_injects_prolog_selected_skill_before_planner,
     [setup(skill_test_support:reset_capture)]) :-
    fixture_catalog(Catalog),
    Options = [ planner_handler(skill_test_support:capture_planner),
                capabilities([rlm, model(openrouter)]),
                child_capabilities([model(openrouter)]),
                skill_catalog(Catalog),
                skill_min_score(20)
              ],
    rlm_completion("Build this feature test first with integration tests",
                   text("opaque"),
                   Options,
                   Outcome),
    assertion(Outcome = ok(Result)),
    assertion(Result.value == "skill-ok"),
    skill_test_support:captured_prompt(Prompt),
    assertion(sub_string(Prompt, _, _, _, "TDD_SKILL_MARKER")),
    assertion(\+ sub_string(Prompt, _, _, _, "GRILL_SKILL_MARKER")).

test(completion_skill_catalog_none_preserves_caller_instruction,
     [setup(skill_test_support:reset_capture)]) :-
    Options = [ planner_handler(skill_test_support:capture_planner),
                capabilities([rlm, model(openrouter)]),
                child_capabilities([model(openrouter)]),
                skill_catalog(none),
                planner_instruction("CALLER_INSTRUCTION_SENTINEL")
              ],
    rlm_completion("Build this parser feature test first",
                   text("opaque"),
                   Options,
                   Outcome),
    assertion(Outcome = ok(Result)),
    assertion(Result.value == "skill-ok"),
    skill_test_support:captured_prompt(Prompt),
    assertion(sub_string(Prompt, _, _, _, "CALLER_INSTRUCTION_SENTINEL")),
    assertion(\+ sub_string(Prompt, _, _, _, "## Skill:")),
    assertion(\+ sub_string(Prompt, _, _, _, "# Test-Driven Development")).

test(default_distribution_auto_activates_without_model_routing,
     [setup((skill_default_catalog_reset,
             skill_test_support:reset_capture))]) :-
    Options = [ planner_handler(skill_test_support:capture_planner),
                capabilities([rlm, model(openrouter)]),
                child_capabilities([model(openrouter)]),
                skill_min_score(40)
              ],
    rlm_completion("Build this parser feature test first",
                   text("opaque"),
                   Options,
                   Outcome),
    assertion(Outcome = ok(Result)),
    assertion(Result.value == "skill-ok"),
    skill_test_support:captured_prompt(Prompt),
    assertion(sub_string(Prompt, _, _, _, "## Skill: tdd")),
    assertion(sub_string(Prompt, _, _, _, "# Test-Driven Development")),
    assertion(\+ sub_string(Prompt, _, _, _, "## Skill: grill-me")).

test(default_distribution_wrapper_dependency_is_prolog_resolved,
     [setup((skill_default_catalog_reset,
             skill_test_support:reset_capture))]) :-
    Options = [ planner_handler(skill_test_support:capture_planner),
                capabilities([rlm, model(openrouter)]),
                child_capabilities([model(openrouter)]),
                explicit_skills(['grill-me']),
                skill_min_score(9999)
              ],
    rlm_completion("opaque",
                   text("opaque"),
                   Options,
                   Outcome),
    assertion(Outcome = ok(Result)),
    assertion(Result.value == "skill-ok"),
    skill_test_support:captured_prompt(Prompt),
    assertion(sub_string(Prompt, _, _, _, "## Skill: grill-me")),
    assertion(sub_string(Prompt, _, _, _, "## Skill: grilling")),
    assertion(sub_string(Prompt, _, _, _,
                         "legacy references inside a skill to a `Skill` tool are inert text")).

nested_resource_fixture(Root) :-
    tmp_file(skill_nested_resource, Root),
    make_directory(Root),
    directory_file_path(Root, 'script-skill', SkillDir),
    make_directory(SkillDir),
    directory_file_path(SkillDir, 'SKILL.md', SkillFile),
    write_text_file(SkillFile,
                    "---\nname: script-skill\ndescription: Script skill fixture.\n---\nSCRIPT_SKILL_BODY\n"),
    directory_file_path(SkillDir, scripts, ScriptsDir),
    make_directory(ScriptsDir),
    directory_file_path(ScriptsDir, 'template.sh', ScriptFile),
    write_text_file(ScriptFile,
                    "#!/bin/sh\n# NESTED_SCRIPT_RESOURCE_MARKER\n").

write_text_file(Path, Text) :-
    setup_call_cleanup(
        open(Path, write, Stream, [encoding(utf8)]),
        format(Stream, '~s', [Text]),
        close(Stream)).

:- end_tests(rlm_skill).