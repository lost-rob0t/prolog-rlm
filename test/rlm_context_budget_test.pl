:- begin_tests(rlm_context_budget).

:- use_module('../prolog/rlm_context_budget').

test(backtracking_selects_highest_utility_pack_under_hard_cap) :-
    Units = [ context_unit{id:a,
                           section:warm,
                           mandatory:false,
                           variants:[context_variant{kind:full,
                                                     tokens:60,
                                                     utility:50,
                                                     value:a}]},
              context_unit{id:b,
                           section:warm,
                           mandatory:false,
                           variants:[context_variant{kind:full,
                                                     tokens:40,
                                                     utility:45,
                                                     value:b}]},
              context_unit{id:c,
                           section:warm,
                           mandatory:false,
                           variants:[context_variant{kind:full,
                                                     tokens:20,
                                                     utility:30,
                                                     value:c}]}
            ],
    Sections = [context_section{name:system,
                                visibility:model,
                                tokens:20}],
    Policy = context_policy{max_context_tokens:100,
                            provider_context_tokens:1000,
                            reserve_output_tokens:10,
                            safety_margin_tokens:5,
                            min_recent_turns:0,
                            overflow:deny},
    context_pack(Units, Sections, Policy, ok(Pack)),
    findall(Id, member(context_selection{id:Id}, Pack.selected), Ids),
    assertion(Ids == [b,c]),
    assertion(Pack.utility =:= 75),
    assertion(Pack.ledger.total_tokens =:= 95),
    assertion(Pack.ledger.remaining_tokens =:= 5).

test(provider_physical_window_is_a_hard_upper_bound) :-
    Policy = context_policy{max_context_tokens:300000,
                            provider_context_tokens:100000,
                            reserve_output_tokens:10000,
                            safety_margin_tokens:5000,
                            min_recent_turns:0,
                            overflow:deny},
    context_pack([], [], Policy, ok(Pack)),
    assertion(Pack.ledger.limit =:= 100000),
    assertion(Pack.ledger.operator_limit =:= 300000),
    assertion(Pack.ledger.provider_limit =:= 100000).

test(operator_working_cap_wins_over_large_provider_window) :-
    Policy = context_policy{max_context_tokens:300000,
                            provider_context_tokens:1000000,
                            reserve_output_tokens:32000,
                            safety_margin_tokens:8000,
                            min_recent_turns:0,
                            overflow:deny},
    context_pack([], [], Policy, ok(Pack)),
    assertion(Pack.ledger.limit =:= 300000),
    assertion(Pack.ledger.total_tokens =:= 40000),
    assertion(Pack.ledger.remaining_tokens =:= 260000).

test(host_only_metadata_is_measured_but_not_charged_to_model_window) :-
    Sections = [ context_section{name:mcp_tool_schema,
                                 visibility:model,
                                 tokens:80},
                 context_section{name:mcp_connection_config,
                                 visibility:host,
                                 tokens:5000}
               ],
    Policy = context_policy{max_context_tokens:100,
                            provider_context_tokens:100,
                            reserve_output_tokens:10,
                            safety_margin_tokens:5,
                            min_recent_turns:0,
                            overflow:deny},
    context_pack([], Sections, Policy, ok(Pack)),
    assertion(Pack.ledger.visible_fixed_tokens =:= 80),
    assertion(Pack.ledger.host_only_metadata_tokens =:= 5000),
    assertion(Pack.ledger.total_tokens =:= 95).

test(mandatory_unit_cannot_be_silently_dropped) :-
    Units = [context_unit{id:current_turn,
                          section:conversation,
                          mandatory:true,
                          variants:[context_variant{kind:verbatim,
                                                    tokens:90,
                                                    utility:100,
                                                    value:current}]}],
    Policy = context_policy{max_context_tokens:100,
                            provider_context_tokens:100,
                            reserve_output_tokens:10,
                            safety_margin_tokens:5,
                            min_recent_turns:1,
                            overflow:deny},
    context_pack(Units, [], Policy, error(Error)),
    assertion(Error.phase == pack).

test(estimated_token_counts_are_explicitly_marked) :-
    token_count_text("abcdefgh", [], ok(Count)),
    assertion(Count.method == estimated),
    assertion(Count.tokens > 0).

:- end_tests(rlm_context_budget).
