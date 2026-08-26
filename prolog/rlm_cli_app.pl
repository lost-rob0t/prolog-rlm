:- module(rlm_cli_app,
          [ cli_execute/2,
            cli_run/2,
            cli_usage/1,
            ide_launch_spec/2
          ]).

/** <module> Bundled prolog-rlm reference harness

This is the application composition layer for the shipped `prolog-rlm` binary.
Reusable runtime semantics stay in library modules.  The reference IDE is
DeepSeek Harness used strictly as a renderer/workspace over
`prolog_agent_ui_v1`; DSH is not an agent loop, context compiler, provider,
tool runtime, history authority, compactor, subagent runtime, or verifier.
*/

:- use_module(rlm_cli, []).
:- use_module(rlm_trace, []).

cli_run([run,'--help'|_], Outcome) :-
    !,
    help_outcome(run, Outcome).
cli_run([ide,'--help'|_], Outcome) :-
    !,
    help_outcome(ide, Outcome).
cli_run([run|Rest], Outcome) :-
    !,
    rlm_cli:cli_run([rlm|Rest], BaseOutcome),
    relabel_run_outcome(BaseOutcome, Outcome).
cli_run([ide|Rest], Outcome) :-
    !,
    ide_outcome(Rest, Outcome).
cli_run(Args, Outcome) :-
    rlm_cli:cli_run(Args, Outcome).

cli_execute(Argv, ExitCode) :-
    cli_run(Argv, Outcome),
    execute_outcome(Outcome, ExitCode).

execute_outcome(ok(Session), ExitCode) :-
    !,
    emit_session(Session),
    (   Session.status == pass
    ->  ExitCode = 0
    ;   ExitCode = 1
    ).
execute_outcome(error(Error), 2) :-
    format(user_error, 'prolog-rlm error: ~q~n', [Error]),
    cli_usage(Usage),
    format(user_error, '~s', [Usage]).

relabel_run_outcome(ok(Session0), ok(Session)) :-
    !,
    put_dict(command, Session0, run, Session).
relabel_run_outcome(error(Error), error(Error)).

help_outcome(Scope, ok(Session)) :-
    cli_usage(Usage),
    app_output(Output),
    Session = cli_session{command:help(Scope),
                          status:pass,
                          summary:Usage,
                          payload:_{usage:Usage},
                          output:Output}.

ide_outcome(Rest, Outcome) :-
    catch(( ide_project(Rest, Project),
            ide_launch_spec(Project, Spec),
            app_output(Output),
            format(string(Summary),
                   'DeepSeek Harness IDE contract ready for ~s; adapter wiring pending on #231~n',
                   [Spec.project_root]),
            Session = cli_session{command:ide,
                                  status:fail,
                                  summary:Summary,
                                  payload:Spec.put(_{kind:adapter_not_wired,
                                                    issue:231}),
                                  output:Output},
            Outcome = ok(Session)
          ),
          Exception,
          app_exception(Exception, Outcome)).

ide_project([], '.') :- !.
ide_project([Project], Project) :- !.
ide_project(Values, _) :-
    throw(cli_fault(too_many_arguments(project, Values))).

ide_launch_spec(Project0, Spec) :-
    path_atom(Project0, ProjectArg),
    absolute_file_name(ProjectArg,
                       Project,
                       [ file_type(directory),
                         access(read),
                         file_errors(fail),
                         solutions(first)
                       ]),
    !,
    atom_string(Project, ProjectText),
    Spec = ide_launch{
               renderer:deepseek_harness,
               protocol:prolog_agent_ui_v1,
               project_root:ProjectText,
               semantic_runtime:prolog_rlm,
               dsh_agent_loop:false,
               dsh_context_compiler:false,
               dsh_provider_runtime:false,
               dsh_tool_runtime:false,
               dsh_compaction:false,
               dsh_history_authority:false
           }.
ide_launch_spec(Project, _) :-
    throw(cli_fault(invalid_project_directory(Project))).

path_atom(Value, Value) :- atom(Value), !.
path_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
path_atom(Value, _) :- throw(cli_fault(invalid_project_directory(Value))).

app_output(_{json:false, view:false}).

emit_session(Session) :-
    (   Session.command == ide
    ->  format('~s', [Session.summary])
    ;   emit_delegated_session(Session)
    ).

emit_delegated_session(Session) :-
    Output = Session.output,
    (   Output.json == true
    ->  rlm_trace:trace_envelope(Session.command, Session.payload, Envelope),
        rlm_trace:trace_json(Envelope, Json),
        format('~s~n', [Json])
    ;   Output.view == true
    ->  rlm_trace:trace_view(Session.payload, View),
        format('~s', [View])
    ;   format('~s', [Session.summary])
    ).

cli_usage(Usage) :-
    rlm_cli:cli_usage(CoreUsage),
    Lines = [
        "Reference harness:",
        "  prolog-rlm run TASK [RLM/provider options]",
        "      One-shot/headless canonical RLM task; exits when the run finishes.",
        "  prolog-rlm ide [PROJECT]",
        "      DeepSeek Harness reference IDE over prolog_agent_ui_v1.",
        "      Prolog-RLM remains the semantic runtime and authority owner.",
        "",
        CoreUsage
    ],
    atomics_to_string(Lines, "\n", Usage).

app_exception(cli_fault(Detail), error(Error)) :-
    !,
    Error = cli_error{kind:invalid_cli_request,
                      detail:Detail,
                      message:"prolog-rlm reference CLI rejected the request"}.
app_exception(Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = cli_error{kind:exception,
                      exception:Safe,
                      message:"prolog-rlm reference CLI raised an exception"}.
