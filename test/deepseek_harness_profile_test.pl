:- begin_tests(deepseek_harness_profile).

:- use_module(library(readutil)).

test(profile_uses_only_base_and_headless_deepseek_bundles) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile/package.json',
                        Package,
                        []),
    assertion(sub_string(Package, _, _, _, '"@deepseek-ai/dsh-base"')),
    assertion(sub_string(Package, _, _, _, '"@deepseek-ai/dsh-headless"')),
    assertion(\+ sub_string(Package, _, _, _, '"@deepseek-ai/dsh-web-app"')).

test(stock_semantic_owners_are_fail_closed) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile/cordis.patch.yml',
                        Patch,
                        []),
    forall(member(Id,
                  [ "llm",
                    "agent-loop",
                    "agent-default-model",
                    "settings",
                    "credentials",
                    "llm-deepseek",
                    "tools",
                    "sandbox",
                    "approval",
                    "permission",
                    "agent-instructions",
                    "skill",
                    "commands",
                    "compaction-basic",
                    "command-compact",
                    "tool-result-pruner",
                    "session-persistence-jsonl",
                    "session-title",
                    "session-title-llm",
                    "subagent",
                    "workflow-worker-thread",
                    "web",
                    "web-search-deepseek",
                    "tool-web",
                    "code-runtime",
                    "headless-runner"
                  ]),
           ( format(string(Needle),
                    '- id: ~s\n  disabled: true',
                    [Id]),
             assertion(sub_string(Patch, _, _, _, Needle))
           )).

test(headless_profile_preserves_only_required_dsh_spine) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile/cordis.patch.yml',
                        Patch,
                        []),
    forall(member(Id, ["session", "agent", "headless-startup"]),
           ( format(string(Disabled),
                    '- id: ~s\n  disabled: true',
                    [Id]),
             assertion(\+ sub_string(Patch, _, _, _, Disabled))
           )),
    assertion(sub_string(Patch,
                         _, _, _,
                         "- id: prolog-agent-factory\n      name: '@prolog-rlm/dsh-agent-factory'")),
    assertion(sub_string(Patch,
                         _, _, _,
                         "- id: prolog-headless-runner\n      name: '@prolog-rlm/dsh-agent-factory/headless'")),
    assertion(sub_string(Patch,
                         _, _, _,
                         "inject: [headlessStartup, agents]" )).

:- end_tests(deepseek_harness_profile).
