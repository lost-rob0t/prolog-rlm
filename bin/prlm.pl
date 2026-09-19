#!/usr/bin/env swipl
/*  prlm — command-line entrypoint of the Prolog-RLM language.

    Usage:  swipl -q -s bin/prlm.pl -- <subcommand> [args]

    Contract:
      * every subcommand prints exactly ONE line of JSON on stdout;
      * exit codes: 0 ok, 1 gate/runtime failure, 2 usage error,
        3 optional module absent;
      * all I/O lives in this file (upper prlm_* modules never write
        to stdout);
      * modules are located relative to THIS script's directory
        (the sibling prolog directory), never relative to the process
        CWD.

    Optional modules (prlm_selfhost, prlm_rlm, prlm_usage,
    prlm_mcp_export, prlm_rsi, prlm_learn) may not be present while
    parallel agents build them. Every use is guarded with
    current_predicate/2 style checks; when absent the subcommand
    degrades to {"error":"<name>_module_absent"} with exit 3.
*/

:- initialization(main, main).

% ------------------------------------------------------------------
% Script-relative module location (never depend on the CWD)
% ------------------------------------------------------------------

:- dynamic cli_prolog_dir_/1.

:- prolog_load_context(source, Src),
   file_directory_name(Src, BinDir0),
   absolute_file_name(BinDir0, BinDir),
   atomic_list_concat([BinDir, '/../prolog'], PrologRel),
   absolute_file_name(PrologRel, PrologDir),
   assertz(cli_prolog_dir_(PrologDir)).

cli_prolog_dir(D) :-
    cli_prolog_dir_(D).

cli_prolog_file(M, Path) :-
    cli_prolog_dir(D),
    atomic_list_concat([D, '/', M, '.pl'], Path).

% ------------------------------------------------------------------
% Module loading
% ------------------------------------------------------------------

cli_load_required(M) :-
    cli_prolog_file(M, Path),
    use_module(Path).

cli_load_optional(M) :-
    cli_prolog_file(M, Path),
    exists_file(Path),
    catch(use_module(Path), _, fail).

cli_module_file_exists(M) :-
    cli_prolog_file(M, Path),
    exists_file(Path).

% Guard: module loaded AND predicate indicator present, checked BEFORE
% any call into the optional module.
cli_has_pred(M, Name/Arity) :-
    cli_load_optional(M),
    current_predicate(M:Name/Arity).

cli_ensure_core :-
    cli_load_required(prlm_kernel),
    cli_load_required(prlm_session).

% ------------------------------------------------------------------
% JSON output (single line) and term coercion
% ------------------------------------------------------------------

cli_print_json(Dict0) :-
    cli_jsonable(Dict0, Dict),
    json_write_dict(current_output, Dict, [width(0), nl(false)]),
    nl(current_output).

cli_jsonable(X, J) :-
    (   var(X)
    ->  J = '$_unbound_'
    ;   is_dict(X)
    ->  dict_pairs(X, _, Pairs0),
        cli_jsonable_pairs(Pairs0, Pairs),
        dict_create(J, json, Pairs)
    ;   is_list(X)
    ->  maplist(cli_jsonable, X, Js),
        J = Js
    ;   atom(X)
    ->  J = X
    ;   string(X)
    ->  J = X
    ;   number(X)
    ->  J = X
    ;   compound(X)
    ->  (   catch(term_to_atom(X, A), _, fail)
        ->  J = A
        ;   J = '$_opaque_term_'
        )
    ;   J = '$_opaque_term_'
    ).

cli_jsonable_pairs([], []).
cli_jsonable_pairs([K-V0|Rest0], [K-V|Rest]) :-
    cli_jsonable(V0, V),
    cli_jsonable_pairs(Rest0, Rest).

cli_text_atom(A, A) :- atom(A), !.
cli_text_atom(S, A) :- string(S), !, atom_string(A, S).
cli_text_atom(X, X).

% ------------------------------------------------------------------
% Subcommand routing
% ------------------------------------------------------------------

cli_subcommands([demo, stage0, stage1, stage2, selfhost, run,
                 mcp, usage, rsi, events, help]).

cli_route([], Code) :- !, cli_cmd_help(Code).
cli_route([help|_], Code) :- !, cli_cmd_help(Code).
cli_route([demo], Code) :- !, cli_cmd_demo(Code).
cli_route([stage0], Code) :- !, cli_cmd_stage0(Code).
cli_route([stage1|_], Code) :- !, cli_cmd_stage1(Code).
cli_route([stage2|_], Code) :- !, cli_cmd_stage2(Code).
cli_route([selfhost|_], Code) :- !, cli_cmd_selfhost(Code).
cli_route([run|Rest], Code) :- !, cli_cmd_run(Rest, Code).
cli_route([mcp|_], Code) :- !, cli_cmd_mcp(Code).
cli_route([usage|_], Code) :- !, cli_cmd_usage(Code).
cli_route([rsi|Rest], Code) :- !, cli_cmd_rsi(Rest, Code).
cli_route([events], Code) :- !, cli_cmd_events(Code).

cli_dispatch(Argv, Code) :-
    cli_route(Argv, Code),
    !.
cli_dispatch(Argv, 2) :-
    (   Argv = [First|_]
    ->  cli_jsonable(First, FJ)
    ;   FJ = ''
    ),
    cli_subcommands(Subs),
    cli_print_json(_{error: unknown_subcommand,
                     subcommand: FJ,
                     subcommands: Subs}).

cli_run(Argv, Code) :-
    catch(cli_dispatch(Argv, Code),
          Error,
          (   cli_crash_json(Error),
              Code = 1
          )),
    !.
cli_run(_, 1) :-
    !,
    cli_print_json(_{error: internal_error}).

main(Argv) :-
    cli_run(Argv, Code),
    flush_output(current_output),
    halt(Code).

cli_crash_json(Error) :-
    catch((   cli_jsonable(Error, J),
              cli_print_json(_{error: internal_error, detail: J})
          ),
          _,
          (   catch(message_to_string(Error, Msg), _, Msg = unprintable),
              (   string(Msg) ; atom(Msg)
              ->  cli_print_json(_{error: internal_error, detail: Msg})
              ;   cli_print_json(_{error: internal_error})
              )
          )).

% ------------------------------------------------------------------
% help
% ------------------------------------------------------------------

cli_cmd_help(Code) :-
    cli_subcommands(Subs),
    cli_print_json(_{subcommands: Subs,
                     usage: 'swipl -q -s bin/prlm.pl -- <subcommand> [args]',
                     exit_codes: _{ok: 0,
                                   gate_or_runtime_failure: 1,
                                   usage_error: 2,
                                   module_absent: 3}}),
    Code = 0.

% ------------------------------------------------------------------
% demo — deterministic end-to-end walkthrough (no network, no model)
% ------------------------------------------------------------------

cli_cmd_demo(Code) :-
    cli_ensure_core,
    cli_load_required(prlm_tools),
    cli_load_required(prlm_providers),
    prlm_session:prlm_session_new([authority(allow_session)], Session),
    prlm_tools:prlm_tools_default(Session),
    prlm_providers:prlm_provider_register(Session, echo, echo),
    prlm_providers:prlm_model_call(
        Session, echo,
        [msg(user, 'verify_step(ancestor_tom_bob)')], _{}, Proposal),
    prlm_providers:prlm_validate_proposal(Session, Proposal, Op),
    prlm_tools:prlm_tool_call(Session, [], kv_put,
                              args{key: greeting, value: 'hello-prlm'},
                              PutResult),
    prlm_tools:prlm_tool_call(Session, [], kv_get,
                              args{key: greeting}, GetResult),
    (   get_dict(status, PutResult, ok),
        get_dict(status, GetResult, ok),
        get_dict(value, GetResult, Value)
    ->  Roundtrip = Value
    ;   Roundtrip = mismatch
    ),
    prlm_session:prlm_session_destroy(Session),
    cli_jsonable(Op, OpJ),
    cli_jsonable(Roundtrip, RJ),
    cli_print_json(_{demo: ok,
                     steps: [session_new,
                             tools_default,
                             provider_register,
                             model_call,
                             validate_proposal,
                             kv_put,
                             kv_get],
                     proposal_op: OpJ,
                     kv_roundtrip: RJ}),
    Code = 0.

% ------------------------------------------------------------------
% stage0 — the kernel engine answering a recursive query
% ------------------------------------------------------------------

cli_stage0_source_lines(
    ['parent(tom, bob).',
     'parent(tom, liz).',
     'parent(bob, ann).',
     'parent(ann, jim).',
     'ancestor(X, Y) :- parent(X, Y).',
     'ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).']).

cli_cmd_stage0(Code) :-
    cli_load_required(prlm_kernel),
    cli_stage0_source_lines(Lines),
    atomic_list_concat(Lines, '\n', Src),
    prlm_kernel:prlm_engine_new([], Engine),
    prlm_kernel:prlm_consult_source(Engine, user, Src, '<cli-stage0>'),
    prlm_kernel:prlm_query_solutions(Engine, 'ancestor(tom, Who)', 100, Rows),
    length(Rows, N),
    prlm_kernel:prlm_engine_destroy(Engine),
    cli_print_json(_{stage0: ok,
                     solutions: N,
                     query: 'ancestor(tom, Who)'}),
    Code = 0.

% ------------------------------------------------------------------
% stage1 / stage2 / selfhost — guarded on prlm_selfhost
% ------------------------------------------------------------------

cli_cmd_stage1(Code) :-
    (   cli_has_pred(prlm_selfhost, prlm_stage1_new/1)
    ->  prlm_selfhost:prlm_stage1_new(Result),
        cli_stage_modules(Result, Modules),
        cli_print_json(_{stage1: ok, modules: Modules}),
        Code = 0
    ;   cli_print_json(_{error: selfhost_module_absent}),
        Code = 3
    ).

cli_cmd_stage2(Code) :-
    (   cli_has_pred(prlm_selfhost, prlm_stage2_new/1)
    ->  prlm_selfhost:prlm_stage2_new(Result),
        cli_stage_modules(Result, Modules),
        cli_print_json(_{stage2: ok, modules: Modules}),
        Code = 0
    ;   cli_print_json(_{error: selfhost_module_absent}),
        Code = 3
    ).

cli_stage_modules(Result, Modules) :-
    (   var(Result)
    ->  Modules = []
    ;   is_list(Result)
    ->  cli_module_names(Result, Modules)
    ;   is_dict(Result),
        get_dict(modules, Result, Ms)
    ->  cli_stage_modules(Ms, Modules)
    ;   Modules = []
    ).

cli_module_names([], []).
cli_module_names([X|Xs], [A|As]) :-
    (   atom(X)
    ->  A = X
    ;   string(X)
    ->  atom_string(A, X)
    ;   A = X
    ),
    cli_module_names(Xs, As).

:- dynamic cli_gate_error/2.

cli_cmd_selfhost(Code) :-
    retractall(cli_gate_error(_, _)),
    (   cli_has_pred(prlm_selfhost, prlm_selfhost_gate/1)
    ->  catch((   prlm_selfhost:prlm_stage1_new(GateEngine),
                  prlm_selfhost:prlm_selfhost_verify(GateEngine, Report),
                  prlm_selfhost:prlm_selfhost_gate(Report)
              ),
              prlm_error(T, I),
              assertz(cli_gate_error(T, I))),
        (   cli_gate_error(T, I)
        ->  cli_jsonable(T, TJ),
            cli_jsonable(I, IJ),
            cli_print_json(_{selfhost: error, type: TJ, info: IJ}),
            Code = 1
        ;   get_dict(equivalence, Report, ok)
        ->  cli_jsonable(Report, RJ),
            cli_print_json(_{selfhost: ok, report: RJ}),
            Code = 0
        ;   (   var(Report) -> Report = selfhost_report{} ; true ),
            cli_jsonable(Report, RJ),
            cli_print_json(_{selfhost: failed, report: RJ}),
            Code = 1
        )
    ;   cli_print_json(_{error: selfhost_module_absent}),
        Code = 3
    ).

% The gate report contract: a dict with ok:true, or status ok/pass/passed,
% or the atoms true/ok. Anything else fails the gate closed.
cli_gate_passed(Report) :-
    (   Report == true
    ;   Report == ok
    ;   is_dict(Report),
        (   get_dict(ok, Report, true)
        ->  true
        ;   get_dict(status, Report, S),
            cli_text_atom(S, A),
            memberchk(A, [ok, pass, passed])
        )
    ).

% ------------------------------------------------------------------
% run --mode <mode> --goal "<text>" — guarded on prlm_rlm
% ------------------------------------------------------------------

% CLI mode names -> engine mode atoms (prlm_run_spec validates these).
cli_mode_spec_atom(direct, direct).
cli_mode_spec_atom(symbolic, symbolic).
cli_mode_spec_atom('symbolic-recursive', symbolic_recursive).
cli_mode_spec_atom(auto, auto).

cli_mode_cmdline(direct, '/direct').
cli_mode_cmdline(symbolic, '/symbolic').
cli_mode_cmdline('symbolic-recursive', '/symbolic-recursive').
cli_mode_cmdline(auto, '/auto').

cli_opt_value([Flag, Value|_], Flag, Value) :- !.
cli_opt_value([_|T], Flag, Value) :-
    cli_opt_value(T, Flag, Value).

cli_parse_run(Args, Mode, GoalText) :-
    cli_opt_value(Args, '--mode', Mode0),
    cli_opt_value(Args, '--goal', GoalText),
    cli_mode_spec_atom(Mode0, Mode).

cli_spec_id(Id) :-
    get_time(T),
    format(atom(Id), 'cli_spec_~w', [T]).

% Candidate calling conventions, tried in order. The documented contract
% (docs/prlm-language.md, CLI reference) is the first clause:
%   prlm_run_spec(+Session, +spec{id, goal, mode}, -Outcome)
% with the goal parsed untrusted via the kernel's parse-only
% prlm_read_goal/3. Fallback: prlm_mode_command/3 command lines like
% "/direct <goal text>".
cli_run_outcome(Session, Mode, GoalText, Outcome) :-
    prlm_kernel:prlm_read_goal(GoalText, Goal, _),
    cli_spec_id(Id),
    cli_call_or_fail(
        prlm_rlm:prlm_run_spec(Session,
                               spec{id: Id, goal: Goal, mode: Mode},
                               Outcome)).
cli_run_outcome(Session, Mode, GoalText, Outcome) :-
    cli_mode_cmdline(Mode, CmdPrefix),
    atom_concat(CmdPrefix, ' ', Cmd0),
    atom_concat(Cmd0, GoalText, CmdLine),
    cli_call_or_fail(prlm_rlm:prlm_mode_command(Session, CmdLine, Outcome)).

cli_call_or_fail(Goal) :-
    catch(call(Goal), _, fail).

cli_cmd_run(Args, Code) :-
    (   cli_parse_run(Args, Mode, GoalText)
    ->  cli_ensure_core,
        cli_load_optional(prlm_rlm),
        prlm_session:prlm_session_new([authority(allow_session)], Session),
        (   cli_run_outcome(Session, Mode, GoalText, Outcome)
        ->  prlm_session:prlm_session_destroy(Session),
            cli_jsonable(GoalText, GJ),
            cli_jsonable(Outcome, OJ),
            cli_print_json(_{run: ok,
                             mode: Mode,
                             goal: GJ,
                             outcome: OJ}),
            Code = 0
        ;   cli_module_file_exists(prlm_rlm)
        ->  prlm_session:prlm_session_destroy(Session),
            cli_print_json(_{error: rlm_run_failed}),
            Code = 1
        ;   prlm_session:prlm_session_destroy(Session),
            cli_print_json(_{error: rlm_module_absent}),
            Code = 3
        )
    ;   cli_print_json(_{error: bad_usage,
                         subcommand: run,
                         usage: 'run --mode <direct|symbolic|symbolic-recursive|auto> --goal "<text>"'}),
        Code = 2
    ).

% ------------------------------------------------------------------
% mcp — guarded on prlm_mcp_export; demo engine with mcp_export/1
% ------------------------------------------------------------------

cli_mcp_demo_lines(
    [':- module(cli_mcp_demo, [double/2, double_schema/1]).',
     ':- mcp_export(double/2).',
     'double(X, Y) :- Y is X * 2.',
     'double_schema(schema([arg(x, integer)])).']).

cli_mcp_surface(Engine, _Session, Surface) :-
    cli_call_or_fail(prlm_mcp_export:prlm_mcp_surface(Engine, Surface)).
cli_mcp_surface(_Engine, Session, Surface) :-
    cli_call_or_fail(prlm_mcp_export:prlm_mcp_surface(Session, Surface)).

cli_cmd_mcp(Code) :-
    (   cli_load_optional(prlm_mcp_export)
    ->  cli_ensure_core,
        prlm_session:prlm_session_new([authority(allow_session)], Session),
        prlm_session:prlm_session_engine(Session, Engine),
        cli_mcp_demo_lines(Lines),
        atomic_list_concat(Lines, '\n', Src),
        (   catch(prlm_kernel:prlm_consult_source(Engine, cli_mcp_demo, Src,
                                                  '<cli-mcp>'),
                  _, fail)
        ->  (   cli_mcp_surface(Engine, Session, Surface)
            ->  cli_jsonable(Surface, SJ),
                cli_print_json(_{mcp: SJ}),
                Code = 0
            ;   cli_print_json(_{error: mcp_surface_failed}),
                Code = 1
            )
        ;   cli_print_json(_{error: mcp_export_unsupported}),
            Code = 1
        ),
        prlm_session:prlm_session_destroy(Session)
    ;   cli_print_json(_{error: mcp_module_absent}),
        Code = 3
    ).

% ------------------------------------------------------------------
% usage — guarded on prlm_usage; synthetic events, ingest + report
% ------------------------------------------------------------------

% Contract: prlm_usage_ingest(+Session, -UsageId) aggregates the event
% stream; prlm_usage_report(+UsageId, -Report) renders the aggregate.
cli_usage_report(Session, Report) :-
    cli_call_or_fail(prlm_usage:prlm_usage_ingest(Session, UsageId)),
    cli_call_or_fail(prlm_usage:prlm_usage_report(UsageId, Report)).
cli_usage_report(Session, Report) :-
    cli_call_or_fail(prlm_usage:prlm_usage_ingest(Session)),
    cli_call_or_fail(prlm_usage:prlm_usage_latest(UsageId)),
    cli_call_or_fail(prlm_usage:prlm_usage_report(UsageId, Report)).

cli_cmd_usage(Code) :-
    (   cli_load_optional(prlm_usage)
    ->  cli_ensure_core,
        prlm_session:prlm_session_new([authority(allow_session)], Session),
        get_time(T),
        prlm_session:prlm_event_emit(Session, model_call,
            _{provider: echo, model: none, messages_count: 2,
              tokens_in: 24, tokens_out: 12, status: ok, time: T}),
        prlm_session:prlm_event_emit(Session, tool_call,
            _{tool: kv_get, args: _{}, effects: [read]}),
        prlm_session:prlm_event_emit(Session, observation,
            _{tool: kv_get, status: ok, duration_ms: 1}),
        prlm_session:prlm_event_emit(Session, completion,
            _{status: ok}),
        (   cli_usage_report(Session, Report)
        ->  cli_jsonable(Report, RJ),
            cli_print_json(_{usage: RJ}),
            Code = 0
        ;   cli_print_json(_{error: usage_report_failed}),
            Code = 1
        ),
        prlm_session:prlm_session_destroy(Session)
    ;   cli_print_json(_{error: usage_module_absent}),
        Code = 3
    ).

% ------------------------------------------------------------------
% rsi — guarded on prlm_rsi; only the --dry form is offered
% ------------------------------------------------------------------

cli_cmd_rsi(Rest, Code) :-
    (   memberchk('--dry', Rest)
    ->  (   cli_load_optional(prlm_rsi)
        ->  cli_print_json(_{rsi: dry,
                             note: 'experiments run in isolated workspaces'}),
            Code = 0
        ;   cli_print_json(_{error: rsi_module_absent}),
            Code = 3
        )
    ;   cli_print_json(_{error: rsi_requires_dry,
                         note: 'experiments run in isolated workspaces; pass --dry'}),
        Code = 2
    ).

% ------------------------------------------------------------------
% events — fresh session, three canonical events, their types
% ------------------------------------------------------------------

cli_cmd_events(Code) :-
    cli_ensure_core,
    prlm_session:prlm_session_new([authority(allow_session)], Session),
    prlm_session:prlm_event_emit(Session, specification,
                                 _{goal: cli_events_demo}),
    prlm_session:prlm_event_emit(Session, tool_call,
                                 _{tool: kv_get, args: _{}}),
    prlm_session:prlm_event_emit(Session, completion, _{status: ok}),
    prlm_session:prlm_events(Session, 1, Events),
    maplist(cli_event_type, Events, Types),
    prlm_session:prlm_session_destroy(Session),
    cli_print_json(_{events: Types}),
    Code = 0.

cli_event_type(Event, Type) :-
    get_dict(type, Event, Type).
