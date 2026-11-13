:- begin_tests(rlm_swarm_cli).

:- use_module('../prolog/rlm_swarm_cli').
:- use_module(library(lists)).
:- use_module(library(process)).

/* config subcommand: one normalizer behind the facade ------------------- */

test(pswarm_config_emits_effective_config) :-
    pswarm_run([config, '-n', 4], ok(Session)),
    assertion(Session.command == config),
    assertion(Session.status == pass),
    assertion(Session.payload.n == 4),
    assertion(Session.payload.cap_usd == 0.10),
    assertion(Session.payload.min_agents == 1),
    assertion(Session.payload.max_agents == 64),
    assertion(Session.payload.rate == 60).

test(pswarm_config_without_n_is_a_config_error) :-
    pswarm_run([config], error(Error)),
    assertion(Error.kind == invalid_swarm_config),
    assertion(Error.detail == missing_required_field(n)).

test(pswarm_config_file_and_cli_precedence_end_to_end) :-
    tmp_file_stream(text, Path, Stream),
    format(Stream, 'swarm_config(1, [cap_usd(0.50), n(4)]).~n', []),
    close(Stream),
    setup_call_cleanup(
        true,
        ( pswarm_run([config, '--config', Path, '-c', '0.20'], ok(Session)),
          assertion(Session.payload.cap_usd == 0.20),
          assertion(Session.payload.n == 4) ),
        delete_file(Path)).

test(pswarm_config_spend_rate_flag_reaches_effective_config) :-
    pswarm_run([config, '-n', 4, '--spend-rate', '0.50/day'], ok(Session)),
    assertion(Session.payload.spend_rate ==
              [spend_rate{usd:0.5, window_minutes:1440}]).

test(pswarm_config_missing_option_value_fails_closed) :-
    pswarm_run([config, '-n'], error(Error)),
    assertion(Error.kind == invalid_cli_request),
    assertion(Error.detail == missing_option_value('-n')).

test(pswarm_config_rejects_unexpected_positional) :-
    pswarm_run([config, '-n', 4, junk], error(Error)),
    assertion(Error.detail == unexpected_argument(junk)).

test(pswarm_config_web_true_parses_and_records_the_marker) :-
    pswarm_run([config, '-n', 4, '--web', true], ok(Session)),
    assertion(Session.payload.web == false),
    assertion(Session.payload.unsupported == [web]).

/* Aliases map to canonical option keys ----------------------------------- */

test(swarm_config_gaurdrail_and_corrected_spelling_are_one_option) :-
    pswarm_run([config, '-n', 4, '--enable-gaurdrail', 'kb,tools'],
               ok(Misspelled)),
    pswarm_run([config, '-n', 4, '--enable-guardrail', 'kb,tools'],
               ok(Canonical)),
    assertion(Misspelled.payload.enable_guardrail == [kb,tools]),
    assertion(Canonical.payload.enable_guardrail == [kb,tools]),
    pswarm_run([config, '-n', 4, '--enable-guardrail'], ok(Bare)),
    assertion(Bare.payload.enable_guardrail == [all]),
    pswarm_run([config,
                '-n', 4,
                '--enable-gaurdrail', 'kb',
                '--enable-guardrail', 'mcp'],
               ok(Both)),
    assertion(Both.payload.enable_guardrail == [kb,mcp]).

test(swarm_config_backround_deamon_aliases_map_to_canonical_keys) :-
    pswarm_run([config, '-n', 4, '--backround', true], ok(Backround)),
    pswarm_run([config, '-n', 4, '--background', true], ok(Background)),
    assertion(Backround.payload.background == true),
    assertion(Background.payload.background == true),
    pswarm_run([config, '-n', 4, '--deamon', true], ok(Deamon)),
    pswarm_run([config, '-n', 4, '--daemon', true], ok(Daemon)),
    assertion(Deamon.payload.daemon == true),
    assertion(Daemon.payload.daemon == true).

/* Unknown flags and subcommands fail closed ------------------------------ */

test(pswarm_unknown_flag_fails_exit_2) :-
    pswarm_run([config, '-n', 4, '--wat'], error(Error)),
    assertion(Error.kind == invalid_cli_request),
    assertion(Error.detail == unknown_option('--wat')).

test(pswarm_unknown_subcommand_fails) :-
    pswarm_run([bogus], error(Error)),
    assertion(Error.kind == invalid_pswarm_request),
    assertion(Error.detail == unknown_subcommand(bogus)).

test(pswarm_unknown_subcommand_with_valid_config_still_fails) :-
    pswarm_run([run, '-n', 4], error(Error)),
    assertion(Error.detail == unknown_subcommand(run)).

/* Unsupported features fault by name, never silently no-op (vote Q12) --- */

test(pswarm_run_with_web_enabled_fails_closed_on_the_feature) :-
    pswarm_run([run, '-n', 4, '--web', true], error(Error)),
    assertion(Error.kind == invalid_pswarm_request),
    assertion(Error.detail == unsupported_feature(web)).

/* help documents the canonical flags and the aliases --------------------- */

test(pswarm_help_documents_aliases_and_flags) :-
    pswarm_run([help], ok(Session)),
    assertion(Session.status == pass),
    pswarm_cli_usage(Usage),
    assertion(sub_string(Usage, _, _, _, "pswarm config")),
    assertion(sub_string(Usage, _, _, _, "--enable-guardrail")),
    assertion(sub_string(Usage, _, _, _, "--enable-gaurdrail")),
    assertion(sub_string(Usage, _, _, _, "--backround")),
    assertion(sub_string(Usage, _, _, _, "--deamon")),
    assertion(sub_string(Usage, _, _, _, "--spend-rate")).

/* JSON emission reuses the rlm_trace envelope ---------------------------- */

test(pswarm_config_json_reuses_the_trace_envelope) :-
    with_output_to(string(Json),
                   pswarm_execute([config, '-n', 4, '--json'], 0)),
    assertion(sub_string(Json, _, _, _, '"schema":"prolog-rlm.trace.v1"')),
    assertion(sub_string(Json, _, _, _, '"name":"config"')),
    assertion(sub_string(Json, _, _, _, '"n":4')),
    assertion(sub_string(Json, _, _, _, '"cap_usd":0.1')),
    assertion(sub_string(Json, _, _, _, '"web":false')).

/* Fresh swipl process fixtures ------------------------------------------- */

run_pswarm(Args, ExitCode, Stdout) :-
    absolute_file_name('bin/pswarm.pl', Script, [access(read)]),
    append(['-q', '-s', Script, '--'], Args, ProcessArguments),
    setup_call_cleanup(
        process_create(path(swipl), ProcessArguments,
                       [process(Pid), stdout(pipe(Out))]),
        ( read_line_to_string(Out, Stdout),
          process_wait(Pid, ExitCode) ),
        close(Out)).

test(pswarm_fresh_process_config_error_exit_2_and_effective_json_exit_0,
     [condition(swipl_on_path)]) :-
    run_pswarm([config, '--json'], ConfigErrorStatus, _Ignored),
    assertion(ConfigErrorStatus == exit(2)),
    run_pswarm([config, '-n', 4, '--json'], JsonStatus, Json),
    assertion(JsonStatus == exit(0)),
    assertion(sub_string(Json, _, _, _, '"schema":"prolog-rlm.trace.v1"')),
    assertion(sub_string(Json, _, _, _, '"n":4')).

test(pswarm_fresh_process_unknown_flag_exit_2, [condition(swipl_on_path)]) :-
    run_pswarm([config, '-n', 4, '--wat'], Status, _Ignored),
    assertion(Status == exit(2)).

test(pswarm_fresh_process_help_exit_0, [condition(swipl_on_path)]) :-
    run_pswarm([help], Status, _Ignored),
    assertion(Status == exit(0)).

swipl_on_path :-
    absolute_file_name(path(swipl), _, [access(execute)]).

:- end_tests(rlm_swarm_cli).
