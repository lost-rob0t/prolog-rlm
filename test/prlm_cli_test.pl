/*  prlm_cli_test.pl — black-box plunit suite for the prlm CLI script.

    Every test runs bin/prlm.pl as a fresh SWI-Prolog subprocess
    (exactly the documented invocation form) and asserts on the
    (exit code, single-line JSON body) pair.

    Run:
      cat > /tmp/prlm_run_cli.pl <<'EOF'
      :- use_module(library(plunit)).
      :- ensure_loaded('test/prlm_cli_test.pl').
      run :- run_tests(prlm_cli), halt.
      :- initialization(run, main).
      EOF
      swipl -q -s /tmp/prlm_run_cli.pl
*/

:- use_module(library(plunit)).
:- use_module(library(process)).
:- use_module(library(http/json)).

% Script path resolved relative to THIS file, never the CWD.
:- dynamic cli_script_path/1.

:- prolog_load_context(source, TestSrc),
   file_directory_name(TestSrc, TestDir),
   atomic_list_concat([TestDir, '/../bin/prlm.pl'], ScriptRel),
   absolute_file_name(ScriptRel, CliScript),
   assertz(cli_script_path(CliScript)).

% ------------------------------------------------------------------
% Helpers
% ------------------------------------------------------------------

run_cli(Args, ExitCode, Body) :-
    run_cli_lines(Args, ExitCode, Lines),
    first_json_line(Lines, Body).

run_cli_lines(Args, ExitCode, Lines) :-
    cli_script_path(Script),
    % Child stderr is discarded: consult warnings from the prlm modules
    % are irrelevant to the CLI contract and would only interleave with
    % this process's own plunit progress output. The asserted surface is
    % stdout + the exit code.
    process_create(path(swipl),
                   ['-q', '-s', Script, '--' | Args],
                   [stdout(pipe(SOut)), stderr(null), process(PID)]),
    read_stream_lines(SOut, Lines),
    close(SOut),
    process_wait(PID, exit(ExitCode)).

read_stream_lines(S, []) :-
    at_end_of_stream(S),
    !.
read_stream_lines(S, [Line|Lines]) :-
    read_line_to_string(S, Line0),
    (   Line0 == end_of_file
    ->  Lines = []
    ;   Line = Line0,
        read_stream_lines(S, Lines)
    ).

first_json_line([], none) :- !.
first_json_line([Line|Lines], Body) :-
    (   string(Line) -> atom_string(LineAtom, Line) ; LineAtom = Line ),
    (   LineAtom \== ''
    ->  (   catch(atom_json_dict(LineAtom, Dict, []), _, fail)
        ->  Body = Dict
        ;   Body = LineAtom
        )
    ;   first_json_line(Lines, Body)
    ).

% JSON strings arrive as SWI strings; normalize to atoms for compares.
json_atom(S, A) :- string(S), !, atom_string(A, S).
json_atom(A, A).

body_atom(Body, Key, Atom) :-
    get_dict(Key, Body, Value),
    json_atom(Value, Atom).

body_atom_member(Body, Key, Wanted) :-
    get_dict(Key, Body, List),
    is_list(List),
    once(( member(Value, List),
           json_atom(Value, Wanted) )).

% ------------------------------------------------------------------
% Tests
% ------------------------------------------------------------------

:- begin_tests(prlm_cli).

test(help_no_args_exits_zero_with_subcommands, []) :-
    run_cli([], Code, Body),
    Code == 0,
    get_dict(subcommands, Body, Subs),
    is_list(Subs),
    length(Subs, N),
    N >= 5.

test(help_subcommand_exits_zero, []) :-
    run_cli([help], Code, Body),
    Code == 0,
    body_atom_member(Body, subcommands, help),
    body_atom_member(Body, subcommands, demo).

test(demo_exits_zero_and_demo_ok, []) :-
    run_cli([demo], Code, Body),
    Code == 0,
    body_atom(Body, demo, ok),
    get_dict(steps, Body, Steps),
    is_list(Steps),
    length(Steps, NSteps),
    NSteps >= 5.

test(stage0_exits_zero_with_solutions, []) :-
    run_cli([stage0], Code, Body),
    Code == 0,
    body_atom(Body, stage0, ok),
    get_dict(solutions, Body, N),
    integer(N),
    N >= 1.

test(unknown_subcommand_exits_two, []) :-
    run_cli([definitely_not_a_subcommand], Code, Body),
    Code == 2,
    body_atom(Body, error, unknown_subcommand).

test(run_tolerant_outcome_or_module_absent, []) :-
    run_cli([run, '--mode', direct, '--goal', 'yield_step(done)'],
            Code, Body),
    (   body_atom(Body, error, rlm_module_absent)
    ->  Code == 3                            % parallel agent not landed yet
    ;   body_atom(Body, run, ok)
    ->  Code == 0                            % completed outcome
    ;   false                                % exit code must match body
    ).

test(run_bad_mode_is_usage_error, []) :-
    run_cli([run, '--mode', bogus_mode, '--goal', x], Code, Body),
    Code == 2,
    body_atom(Body, error, bad_usage).

test(run_missing_goal_is_usage_error, []) :-
    run_cli([run, '--mode', direct], Code, Body),
    Code == 2,
    body_atom(Body, error, bad_usage).

test(stage1_tolerant_ok_or_module_absent, []) :-
    run_cli([stage1], Code, Body),
    (   body_atom(Body, error, selfhost_module_absent)
    ->  Code == 3
    ;   body_atom(Body, stage1, ok)
    ->  Code == 0
    ;   false
    ).

test(stage2_tolerant_ok_or_module_absent, []) :-
    run_cli([stage2], Code, Body),
    (   body_atom(Body, error, selfhost_module_absent)
    ->  Code == 3
    ;   body_atom(Body, stage2, ok)
    ->  Code == 0
    ;   false
    ).

test(selfhost_exit_code_matches_body, []) :-
    run_cli([selfhost], Code, Body),
    (   body_atom(Body, error, selfhost_module_absent)
    ->  Code == 3                            % module absent
    ;   body_atom(Body, selfhost, ok)
    ->  Code == 0                            % gate passed
    ;   get_dict(selfhost, Body, _)
    ->  Code == 1                            % gate report + failure
    ;   false
    ).

test(mcp_tolerant_surface_or_module_absent, []) :-
    run_cli([mcp], Code, Body),
    (   body_atom(Body, error, mcp_module_absent)
    ->  Code == 3
    ;   get_dict(mcp, Body, _)
    ->  Code == 0
    ;   false
    ).

test(usage_tolerant_report_or_module_absent, []) :-
    run_cli([usage], Code, Body),
    (   body_atom(Body, error, usage_module_absent)
    ->  Code == 3
    ;   get_dict(usage, Body, _)
    ->  Code == 0
    ;   false
    ).

test(rsi_dry_tolerant_or_module_absent, []) :-
    run_cli([rsi, '--dry'], Code, Body),
    (   body_atom(Body, error, rsi_module_absent)
    ->  Code == 3
    ;   body_atom(Body, rsi, dry)
    ->  Code == 0
    ;   false
    ).

test(rsi_without_dry_is_usage_error, []) :-
    run_cli([rsi], Code, Body),
    Code == 2,
    body_atom(Body, error, rsi_requires_dry).

test(events_emits_three_canonical_types, []) :-
    run_cli([events], Code, Body),
    Code == 0,
    get_dict(events, Body, Types),
    is_list(Types),
    length(Types, 3),
    body_atom_member(Body, events, specification),
    body_atom_member(Body, events, tool_call),
    body_atom_member(Body, events, completion).

test(stdout_is_single_json_line, []) :-
    run_cli_lines([demo], Code, Lines),
    Code == 0,
    length(Lines, 1).

:- end_tests(prlm_cli).
