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
                    "tool-result-pruner"
                  ]),
           ( format(string(Needle),
                    '- id: ~s\n  disabled: true',
                    [Id]),
             assertion(sub_string(Patch, _, _, _, Needle))
           )).

test(profile_does_not_install_fallback_agent) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile/cordis.patch.yml',
                        Patch,
                        []),
    assertion(\+ sub_string(Patch, _, _, _, '@deepseek-ai/dsh-agent-loop')),
    assertion(\+ sub_string(Patch, _, _, _, 'name:')).

:- end_tests(deepseek_harness_profile).
