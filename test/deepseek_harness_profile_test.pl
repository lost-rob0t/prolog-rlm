:- begin_tests(deepseek_harness_profile).

:- use_module(library(readutil)).

test(profile_uses_only_base_and_headless_deepseek_bundles) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile/package.json',
                        Package,
                        []),
    assertion(sub_string(Package, _, _, _, '"@deepseek-ai/dsh-base"')),
    assertion(sub_string(Package, _, _, _, '"@deepseek-ai/dsh-headless"')),
    assertion(\+ sub_string(Package, _, _, _, '"@deepseek-ai/dsh-web-app"')).

test(base_bundle_keeps_only_agent_and_session_services) :-
    read_file_to_string('../agentProlog/deepseek-harness/upstream/packages/bundle/base/cordis.patch.yml',
                        Base,
                        []),
    read_file_to_string('../agentProlog/deepseek-harness/profile/cordis.patch.yml',
                        Profile,
                        []),
    patch_ids(Base, Ids),
    forall(( member(Id, Ids),
             \+ memberchk(Id, ["agent", "session"]) ),
           assertion(disabled_in_profile(Profile, Id))).

test(headless_bundle_keeps_only_argv_startup) :-
    read_file_to_string('../agentProlog/deepseek-harness/upstream/packages/bundle/headless/cordis.patch.yml',
                        Headless,
                        []),
    read_file_to_string('../agentProlog/deepseek-harness/profile/cordis.patch.yml',
                        Profile,
                        []),
    patch_ids(Headless, Ids),
    forall(( member(Id, Ids),
             Id \== "headless-startup" ),
           assertion(disabled_in_profile(Profile, Id))).

test(headless_profile_preserves_required_dsh_spine) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile/cordis.patch.yml',
                        Patch,
                        []),
    forall(member(Id, ["session", "agent", "headless-startup"]),
           assertion(\+ disabled_in_profile(Patch, Id))),
    assertion(sub_string(Patch,
                         _, _, _,
                         "- id: prolog-agent-factory\n      name: '@prolog-rlm/dsh-agent-factory'")),
    assertion(sub_string(Patch,
                         _, _, _,
                         "- id: prolog-headless-runner\n      name: '@prolog-rlm/dsh-agent-factory/headless'")),
    assertion(sub_string(Patch,
                         _, _, _,
                         "inject: [headlessStartup, agents]" )).

patch_ids(Text, Ids) :-
    split_string(Text, "\n", "\r", Lines),
    findall(Id,
            ( member(Line, Lines),
              normalize_space(string(Trimmed), Line),
              string_concat("- id: ", Id, Trimmed)
            ),
            Ids0),
    sort(Ids0, Ids).

disabled_in_profile(Profile, Id) :-
    format(string(Needle),
           '- id: ~s\n  disabled: true',
           [Id]),
    sub_string(Profile, _, _, _, Needle).

:- end_tests(deepseek_harness_profile).
