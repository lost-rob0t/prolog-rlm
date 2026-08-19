:- begin_tests(deepseek_harness_profile).

:- use_module(library(readutil)).

test(stock_semantic_owners_are_fail_closed) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile/cordis.patch.yml',
                        Patch,
                        []),
    forall(member(Id,
                  [ "agent-loop",
                    "compaction-basic",
                    "command-compact",
                    "tool-result-pruner",
                    "session-title-llm"
                  ]),
           ( format(string(Needle),
                    '- id: ~s\n  disabled: true',
                    [Id]),
             assertion(sub_string(Patch, _, _, _, Needle))
           )).

test(profile_installs_only_prolog_agent_factory) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile/cordis.patch.yml',
                        Patch,
                        []),
    assertion(\+ sub_string(Patch, _, _, _, '@deepseek-ai/dsh-agent-loop')),
    assertion(sub_string(Patch,
                         _, _, _,
                         "- id: prolog-agent-factory\n  name: '@prolog-rlm/dsh-agent-factory'")),
    assertion(\+ sub_string(Patch,
                            _, _, _,
                            "name: '@deepseek-ai/dsh-compaction")),
    assertion(\+ sub_string(Patch,
                            _, _, _,
                            "name: '@deepseek-ai/dsh-session-title-first-prompt-llm'" )).

:- end_tests(deepseek_harness_profile).
