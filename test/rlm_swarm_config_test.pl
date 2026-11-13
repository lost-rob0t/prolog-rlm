:- begin_tests(rlm_swarm_config).

:- use_module('../prolog/rlm_swarm_config').

/* Defaults and schema version ----------------------------------------- */

test(swarm_config_default_cap_is_0_10_and_matches_schema_version_1) :-
    swarm_config_schema_version(1),
    swarm_config_default(Default),
    assertion(Default.cap_usd == 0.10),
    assertion(Default.n == none),
    assertion(Default.min_agents == 1),
    assertion(Default.max_agents == 64),
    assertion(Default.rate == 60),
    assertion(Default.spend_rate == []),
    assertion(Default.kb == none),
    assertion(Default.enable_guardrail == []),
    assertion(Default.web == false),
    assertion(Default.console == none),
    assertion(Default.background == false),
    assertion(Default.daemon == false),
    assertion(Default.unsupported == []).

/* Unknown fields and invalid values fail closed ----------------------- */

test(swarm_config_rejects_unknown_field_in_file_layer,
     [throws(swarm_config_fault(unknown_field(wat)))]) :-
    swarm_config_normalize(file("f", pos, swarm_config(1, [wat(1)])), [], _, _).

test(swarm_config_rejects_unknown_field_in_cli_layer,
     [throws(swarm_config_fault(unknown_field(wat)))]) :-
    swarm_config_normalize(none, [cli_field(wat, 1, 0)], _, _).

test(swarm_config_rejects_unknown_schema_version,
     [throws(swarm_config_fault(unsupported_schema_version(2, 1)))]) :-
    swarm_config_normalize(file("f", pos, swarm_config(2, [n(1)])), [], _, _).

test(swarm_config_rejects_non_swarm_config_file_term,
     [throws(swarm_config_fault(invalid_config_term(other(1))))]) :-
    swarm_config_normalize(file("f", pos, other(1)), [], _, _).

test(swarm_config_rejects_invalid_field_value,
     [throws(swarm_config_fault(invalid_field_value(rate, zero)))]) :-
    swarm_config_normalize(none,
                           [cli_field(n, 1, 0), cli_field(rate, zero, 1)],
                           _, _).

test(swarm_config_rejects_non_integer_agent_count,
     [throws(swarm_config_fault(invalid_field_value(n, 2.5)))]) :-
    swarm_config_normalize(none, [cli_field(n, 2.5, 0)], _, _).

/* File reading: exactly one ground swarm_config term ------------------- */

write_config_file(Content, Path) :-
    tmp_file_stream(text, Path, Stream),
    format(Stream, '~s', [Content]),
    close(Stream).

test(swarm_config_rejects_non_ground_file_term,
     [throws(swarm_config_fault(non_ground_config_term))]) :-
    write_config_file("swarm_config(1, [cap_usd(X)]).\n", Path),
    setup_call_cleanup(true,
                       swarm_config_read_file(Path, _),
                       delete_file(Path)).

test(swarm_config_rejects_multiple_file_terms,
     [throws(swarm_config_fault(multiple_config_terms))]) :-
    write_config_file("swarm_config(1, [n(1)]).\nswarm_config(1, [n(2)]).\n", Path),
    setup_call_cleanup(true,
                       swarm_config_read_file(Path, _),
                       delete_file(Path)).

test(swarm_config_rejects_empty_file,
     [throws(swarm_config_fault(empty_config_file))]) :-
    write_config_file("\n", Path),
    setup_call_cleanup(true,
                       swarm_config_read_file(Path, _),
                       delete_file(Path)).

test(swarm_config_rejects_malformed_file_syntax,
     [throws(swarm_config_fault(malformed_config_term(_)))]) :-
    write_config_file("swarm_config(1, [n(4)\n", Path),
    setup_call_cleanup(true,
                       swarm_config_read_file(Path, _),
                       delete_file(Path)).

/* Precedence: CLI over file over defaults, with provenance ------------- */

test(swarm_config_precedence_cli_over_file_over_defaults_with_provenance) :-
    write_config_file("swarm_config(1, [cap_usd(0.50), n(4)]).\n", Path),
    setup_call_cleanup(
        true,
        ( swarm_config_read_file(Path, FileInput),
          swarm_config_normalize(FileInput,
                                 [cli_field(cap_usd, 0.20, 2)],
                                 Effective,
                                 Provenance)
        ),
        delete_file(Path)),
    assertion(Effective.cap_usd == 0.20),
    assertion(Effective.n == 4),
    assertion(Effective.min_agents == 1),
    assertion(Effective.max_agents == 64),
    assertion(Provenance.cap_usd == cli(2)),
    Provenance.n = file(Path, TermPos),
    assertion(ground(TermPos)),
    assertion(Provenance.min_agents == default).

test(swarm_config_scalar_last_wins_within_layer_provenance_records_occurrence) :-
    swarm_config_normalize(none,
                           [cli_field(n, 2, 0),
                            cli_field(cap_usd, 0.50, 1),
                            cli_field(cap_usd, 0.30, 2)],
                           Effective,
                           Provenance),
    assertion(Effective.cap_usd == 0.30),
    assertion(Provenance.cap_usd == cli(2)),
    swarm_config_normalize(none,
                           [cli_field(n, 2, 0), cli_field(cap_usd, 0.50, 1)],
                           EffectiveOne,
                           ProvenanceOne),
    assertion(EffectiveOne.cap_usd == 0.50),
    assertion(ProvenanceOne.cap_usd == cli(1)).

/* Guardrails: union across layers, bare means all ---------------------- */

test(swarm_config_guardrails_union_across_layers_bare_means_all) :-
    swarm_config_normalize(none,
                           [cli_field(n, 2, 0),
                            cli_field(enable_guardrail, 'kb,tools', 1),
                            cli_field(enable_guardrail, all, 2)],
                           Effective,
                           _),
    assertion(Effective.enable_guardrail == [all,kb,tools]),
    swarm_config_normalize(none,
                           [cli_field(n, 2, 0),
                            cli_field(enable_guardrail, all, 1)],
                           EffectiveBare,
                           _),
    assertion(EffectiveBare.enable_guardrail == [all]).

test(swarm_config_guardrails_union_file_and_cli_layers) :-
    swarm_config_normalize(file("f", pos,
                                swarm_config(1, [n(4), enable_guardrail('kb')])),
                           [cli_field(enable_guardrail, 'mcp', 3)],
                           Effective,
                           Provenance),
    assertion(Effective.enable_guardrail == [kb,mcp]),
    Provenance.enable_guardrail == [cli(3), file("f", pos)].

test(swarm_config_rejects_invalid_guardrail_class,
     [throws(swarm_config_fault(invalid_guardrail_class("kb, tools")))]) :-
    swarm_config_normalize(none,
                           [cli_field(enable_guardrail, "kb, tools", 1)],
                           _, _).

test(swarm_guardrail_class_vocabulary_is_syntactic_only) :-
    swarm_guardrail_class(all),
    swarm_guardrail_class('kb,tools'),
    swarm_guardrail_class("kb_2,tool-3"),
    \+ swarm_guardrail_class('kb, tools'),
    \+ swarm_guardrail_class('kb,,tools'),
    \+ swarm_guardrail_class('kb/../../etc'),
    \+ swarm_guardrail_class(42).

/* Spend rates ---------------------------------------------------------- */

test(swarm_config_spend_rate_units_parse) :-
    swarm_spend_rate_parse("0.50/min", spend_rate{usd:0.5, window_minutes:1}),
    swarm_spend_rate_parse("0.50/hr", spend_rate{usd:0.5, window_minutes:60}),
    swarm_spend_rate_parse("0.50/day", spend_rate{usd:0.5, window_minutes:1440}),
    swarm_spend_rate_parse("0.50/week", spend_rate{usd:0.5, window_minutes:10080}),
    swarm_spend_rate_parse("0.50/year", spend_rate{usd:0.5, window_minutes:525600}).

test(swarm_config_spend_rate_rejects_unknown_unit,
     [throws(swarm_config_fault(unknown_spend_rate_unit("fortnight",
                                                        "0.50/fortnight")))]) :-
    swarm_spend_rate_parse("0.50/fortnight", _).

test(swarm_config_spend_rate_rejects_malformed_amount,
     [throws(swarm_config_fault(malformed_spend_rate("-1.00/day")))]) :-
    swarm_spend_rate_parse("-1.00/day", _).

test(swarm_config_spend_rate_rejects_missing_unit,
     [throws(swarm_config_fault(malformed_spend_rate("0.50")))]) :-
    swarm_spend_rate_parse("0.50", _).

test(swarm_config_spend_rate_last_wins_within_layer_strictest_across_layers) :-
    swarm_config_normalize(none,
                           [cli_field(n, 2, 0),
                            cli_field(spend_rate, "1.00/day", 1),
                            cli_field(spend_rate, "2.00/day", 2),
                            cli_field(spend_rate, "0.25/hr", 3)],
                           Effective,
                           Provenance),
    assertion(Effective.spend_rate ==
              [spend_rate{usd:0.25, window_minutes:60},
               spend_rate{usd:2.0, window_minutes:1440}]),
    assertion(Provenance.spend_rate == [cli(2), cli(3)]).

test(swarm_config_spend_rate_strictest_wins_across_layers) :-
    swarm_config_normalize(file("f", pos,
                                swarm_config(1, [n(4),
                                                 spend_rate("0.50/day"),
                                                 spend_rate("2.00/hr")])),
                           [cli_field(spend_rate, "0.75/day", 1)],
                           Effective,
                           _),
    assertion(Effective.spend_rate ==
              [spend_rate{usd:2.0, window_minutes:60},
               spend_rate{usd:0.5, window_minutes:1440}]).

/* Contradictions fail closed ------------------------------------------- */

test(swarm_config_contradictory_bounds_fail,
     [throws(swarm_config_fault(contradictory_bounds(min_agents, 2, 8)))]) :-
    swarm_config_normalize(none,
                           [cli_field(n, 8, 0),
                            cli_field(min_agents, 8, 1),
                            cli_field(max_agents, 2, 2)],
                           _, _).

test(swarm_config_n_outside_bounds_fail,
     [throws(swarm_config_fault(n_outside_bounds(2, 5, 64)))]) :-
    swarm_config_normalize(none,
                           [cli_field(n, 2, 0), cli_field(min_agents, 5, 1)],
                           _, _).

test(swarm_config_n_is_required,
     [throws(swarm_config_fault(missing_required_field(n)))]) :-
    swarm_config_normalize(none, [], _, _).

/* Web is boolean-only and unsupported until parity lands ---------------- */

test(swarm_config_web_true_records_unsupported_feature_marker) :-
    swarm_config_normalize(none,
                           [cli_field(n, 2, 0), cli_field(web, true, 1)],
                           Effective, _),
    assertion(Effective.web == false),
    assertion(Effective.unsupported == [web]),
    swarm_config_normalize(none,
                           [cli_field(n, 2, 0), cli_field(web, false, 1)],
                           EffectiveOff, _),
    assertion(EffectiveOff.web == false),
    assertion(EffectiveOff.unsupported == []).

test(swarm_config_rejects_non_boolean_web,
     [throws(swarm_config_fault(invalid_field_value(web, sometimes)))]) :-
    swarm_config_normalize(none, [cli_field(web, sometimes, 1)], _, _).

/* Redaction ------------------------------------------------------------- */

test(swarm_config_redacted_output_is_deterministic_and_stable_tagged) :-
    swarm_config_normalize(none,
                           [cli_field(n, 4, 0), cli_field(kb, 'kb/', 1)],
                           Effective,
                           _),
    swarm_config_redact(Effective, Redacted1),
    swarm_config_redact(Effective, Redacted2),
    assertion(Redacted1 == Redacted2),
    swarm_config_redact(Redacted1, Redacted3),
    assertion(Redacted3 == Redacted1),
    dict_pairs(Redacted1, Tag, _),
    assertion(Tag == swarm_config),
    assertion(Redacted1.kb == "kb/"),
    assertion(Redacted1.n == 4),
    assertion(Redacted1.cap_usd == 0.10),
    assertion(Redacted1.web == false),
    assertion(Redacted1.background == false),
    assertion(Redacted1.daemon == false).

test(swarm_config_redact_strips_unexpected_keys,
     [throws(swarm_config_fault(unknown_field(provenance)))]) :-
    swarm_config_default(Default),
    WithProvenance = Default.put(provenance, some_provenance_map),
    swarm_config_redact(WithProvenance, _).

:- end_tests(rlm_swarm_config).
