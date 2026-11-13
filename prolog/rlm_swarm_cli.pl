:- module(rlm_swarm_cli,
          [ pswarm_run/2,
            pswarm_execute/2,
            pswarm_cli_usage/1
          ]).

/** <module> pswarm command-line facade for rlm-swarm

Composes public swarm APIs only. The argv parser is a thin tokenizer over
the shared rlm_cli_args layer whose output feeds swarm_config_normalize/4 —
the same normalizer the config file uses — so there is one configuration
authority and no second parser (RLM-DESIGN-574-a, slice 1).

Slice-1 command surface: `pswarm config` and `pswarm help`. Any other
subcommand exits 2; when the remaining argv requests an unsupported
feature (currently `--web true`), the fault names that feature instead of
silently dropping it (resolved vote Q12).

Exit codes: 0 success, 2 config/CLI error.
*/

:- use_module(rlm_cli_args).
:- use_module(rlm_swarm_config).
:- use_module(rlm_trace).
:- use_module(library(lists)).

pswarm_run(Argv0, Outcome) :-
    catch(( normalize_argv(Argv0, Argv),
            pswarm_dispatch(Argv, Session),
            Outcome = ok(Session)
          ),
          Exception,
          pswarm_exception(Exception, Outcome)).

pswarm_execute(Argv, ExitCode) :-
    pswarm_run(Argv, Outcome),
    execute_outcome(Outcome, ExitCode).

execute_outcome(ok(Session), 0) :-
    !,
    emit_session(Session).
execute_outcome(error(Error), 2) :-
    format(user_error, 'pswarm error: ~q~n', [Error]),
    pswarm_cli_usage(Usage),
    format(user_error, '~s', [Usage]).

/* Dispatch -------------------------------------------------------------- */

pswarm_dispatch([], Session) :-
    !,
    help_session(Session).
pswarm_dispatch([help|_], Session) :-
    !,
    help_session(Session).
pswarm_dispatch(['--help'|_], Session) :-
    !,
    help_session(Session).
pswarm_dispatch([config|Rest], Session) :-
    !,
    config_session(Rest, Session).
pswarm_dispatch([Subcommand|Rest], _) :-
    fail_closed_subcommand(Subcommand, Rest).

% Any subcommand outside the slice-1 surface exits 2. When the remaining
% argv parses into an effective config that requests an unsupported
% feature, the fault names that feature: a requested unsupported
% capability must be rejected explicitly, never silently dropped.
fail_closed_subcommand(_, Rest) :-
    catch(( parse_swarm_args(Rest, 1, _, CliFields, _),
            swarm_config_normalize(none, CliFields, Effective, _) ),
          _, fail),
    memberchk(Feature, Effective.unsupported),
    !,
    throw(pswarm_fault(unsupported_feature(Feature))).
fail_closed_subcommand(Subcommand, _) :-
    throw(pswarm_fault(unknown_subcommand(Subcommand))).

/* Commands -------------------------------------------------------------- */

help_session(Session) :-
    pswarm_cli_usage(Usage),
    Session = pswarm_session{command:help,
                             status:pass,
                             summary:Usage,
                             payload:_{usage:Usage},
                             output:_{json:false}}.

config_session(Rest, Session) :-
    parse_swarm_args(Rest, 1, FileInput, CliFieldsRev, Json),
    reverse(CliFieldsRev, CliFields),
    swarm_config_normalize(FileInput, CliFields, Effective, _Provenance),
    swarm_config_redact(Effective, Redacted),
    config_summary(Redacted, Summary),
    Session = pswarm_session{command:config,
                             status:pass,
                             summary:Summary,
                             payload:Redacted,
                             output:_{json:Json}}.

config_summary(Redacted, Summary) :-
    dict_pairs(Redacted, _, Pairs),
    with_output_to(string(Summary),
                   ( format('pswarm config:~n', []),
                     forall(member(Key-Value, Pairs),
                            format('  ~w=~q~n', [Key, Value]))
                   )).

emit_session(Session) :-
    (   Session.output.json == true
    ->  trace_envelope(Session.command, Session.payload, Envelope),
        trace_json(Envelope, Json),
        format('~s~n', [Json])
    ;   format('~s', [Session.summary])
    ).

/* Argument tokenizing ---------------------------------------------------- */

% Canonical option keys. The misspelling aliases (--enable-gaurdrail,
% --backround, --deamon) are documented, not hidden, and map to the same
% option key (resolved vote Q1; RLM-DESIGN-574-a flag table).
pswarm_option('-c', cap_usd).
pswarm_option('-n', n).
pswarm_option('--min-agents', min_agents).
pswarm_option('--max-agents', max_agents).
pswarm_option('--rate', rate).
pswarm_option('--spend-rate', spend_rate).
pswarm_option('--kb', kb).
pswarm_option('--enable-guardrail', enable_guardrail).
pswarm_option('--enable-gaurdrail', enable_guardrail).
pswarm_option('--web', web).
pswarm_option('--console', console).
pswarm_option('--background', background).
pswarm_option('--backround', background).
pswarm_option('--daemon', daemon).
pswarm_option('--deamon', daemon).

% parse_swarm_args(+Tokens, +Index0, -FileInput, -CliFields, -Json) where
% Index0 is the 0-based argv position of Tokens' head, so provenance records
% cli(ArgIndex) for the winning occurrence's flag token.
parse_swarm_args(Tokens, Index0, FileInput, CliFields, Json) :-
    parse_swarm_args(Tokens, Index0, none, [], false, FileInput, CliFields, Json).

parse_swarm_args([], _, FileInput, Fields, Json, FileInput, Fields, Json).
parse_swarm_args(['--config', Value|Rest], Index0, _, Fields0, Json0,
                 FileInput, Fields, Json) :-
    !,
    cli_text_arg(Value, Path),
    swarm_config_read_file(Path, File1),
    Next is Index0 + 2,
    parse_swarm_args(Rest, Next, File1, Fields0, Json0, FileInput, Fields, Json).
parse_swarm_args(['--json'|Rest], Index0, File0, Fields0, _,
                 FileInput, Fields, Json) :-
    !,
    Next is Index0 + 1,
    parse_swarm_args(Rest, Next, File0, Fields0, true, FileInput, Fields, Json).
parse_swarm_args([Flag|Rest], Index0, File0, Fields0, Json0,
                 FileInput, Fields, Json) :-
    pswarm_option(Flag, Field),
    !,
    option_value(Flag, Field, Rest, Index0, Value, Rest1, Next),
    parse_swarm_args(Rest1, Next, File0,
                     [cli_field(Field, Value, Index0)|Fields0], Json0,
                     FileInput, Fields, Json).
parse_swarm_args([Token|_], _, _, _, _, _, _, _) :-
    atom(Token),
    sub_atom(Token, 0, 2, _, '--'),
    !,
    throw(cli_fault(unknown_option(Token))).
parse_swarm_args([Token|_], _, _, _, _, _, _, _) :-
    throw(cli_fault(unexpected_argument(Token))).

% A guardrail flag is bare (= all) unless followed by a value token; every
% other option requires an explicit value token.
option_value(_, enable_guardrail, Rest, Index0, Value, Rest1, Next) :-
    !,
    (   Rest = [Token|RestTail],
        \+ pswarm_flag_token(Token)
    ->  Value = Token,
        Rest1 = RestTail,
        Next is Index0 + 2
    ;   Value = all,
        Rest1 = Rest,
        Next is Index0 + 1
    ).
option_value(_, _, [Value|Rest], Index0, Value, Rest, Next) :-
    !,
    Next is Index0 + 2.
option_value(Flag, _, [], _, _, _, _) :-
    throw(cli_fault(missing_option_value(Flag))).

pswarm_flag_token('--config').
pswarm_flag_token('--json').
pswarm_flag_token(Token) :-
    pswarm_option(Token, _).

% Tokens are normalized for flag matching; typed values (numbers) pass
% through untouched because cli_field values are the typed results of the
% shared rlm_cli_args validators.
normalize_argv([], []).
normalize_argv([Number|Rest0], [Number|Rest]) :-
    number(Number),
    !,
    normalize_argv(Rest0, Rest).
normalize_argv([Arg0|Rest0], [Arg|Rest]) :-
    cli_atom_arg(Arg0, Arg),
    normalize_argv(Rest0, Rest).

/* Errors and usage ------------------------------------------------------- */

pswarm_exception(pswarm_fault(Detail), error(Error)) :-
    !,
    Error = pswarm_error{kind:invalid_pswarm_request,
                         detail:Detail,
                         message:"pswarm rejected the request"}.
pswarm_exception(swarm_config_fault(Detail), error(Error)) :-
    !,
    Error = pswarm_error{kind:invalid_swarm_config,
                         detail:Detail,
                         message:"pswarm rejected the swarm configuration"}.
pswarm_exception(cli_fault(Detail), error(Error)) :-
    !,
    Error = pswarm_error{kind:invalid_cli_request,
                         detail:Detail,
                         message:"pswarm rejected the request"}.
pswarm_exception(Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = pswarm_error{kind:exception,
                         exception:Safe,
                         message:"pswarm raised an exception"}.

pswarm_cli_usage(Usage) :-
    Lines = [
        "pswarm - rlm-swarm supervisor CLI",
        "",
        "Usage:",
        "  pswarm config [--config FILE] [--json] [options]",
        "  pswarm help",
        "",
        "Swarm options (CLI over config file over defaults):",
        "  -c USD                        Lifetime spend cap (default 0.10)",
        "  -n N                          Agent population (required)",
        "  --min-agents N                Lower population bound (default 1)",
        "  --max-agents N                Upper population bound (default 64)",
        "  --rate N                      Requests per minute (default 60)",
        "  --spend-rate USD/min|hr|day|week|year",
        "                                Per-window spend quota; repeatable,",
        "                                one quota per window",
        "  --kb PATH                     Knowledge-base path (type-validated)",
        "  --enable-guardrail [CLASSES]  Bare flag enables all guardrails;",
        "                                CLASSES is a comma list",
        "  --enable-gaurdrail [...]      Documented misspelling alias",
        "  --web true|false              Boolean only; true is recorded as an",
        "                                unsupported feature until web parity",
        "                                lands and every command fails closed",
        "  --console PATH                Console path (follow-on parity)",
        "  --background true|false       Daemonize in the background",
        "  --backround true|false        Documented misspelling alias",
        "  --daemon true|false           Run as a daemon",
        "  --deamon true|false           Documented misspelling alias",
        "",
        "Config file: exactly one ground swarm_config(1, [...]) term,",
        "for example swarm_config(1, [cap_usd(0.10), n(4), rate(12)]).",
        "",
        "Unknown options, unknown fields, non-ground or multiple config",
        "terms, contradictory bounds, and invalid values exit 2.",
        "",
        "Examples:",
        "  pswarm config -n 4 --json",
        "  pswarm config --config swarm.pl -c 0.20",
        ""
    ],
    atomics_to_string(Lines, "\n", Usage).
