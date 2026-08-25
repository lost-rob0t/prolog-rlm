:- module(rlm_cli,
          [ rlm_cli_ready/0,
            cli_run/2,
            cli_execute/2,
            cli_usage/1
          ]).

/** <module> Command-line facade for prolog-rlm

The CLI only composes public runtime APIs. It does not duplicate provider,
context, agent, graph, MCP, or recursion runtimes.
*/

:- use_module(library(readutil)).
:- use_module(rlm_chain).
:- use_module(rlm_completion).
:- use_module(rlm_demo).
:- use_module(rlm_effect_migration).
:- use_module(rlm_trace).

rlm_cli_ready.

cli_run(Argv0, Outcome) :-
    catch(( normalize_argv(Argv0, Argv),
            cli_dispatch(Argv, Session0),
            maybe_export_trace(Session0, Session),
            Outcome = ok(Session)
          ),
          Exception,
          cli_exception(Exception, Outcome)).

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

/* Commands ------------------------------------------------------------- */

cli_dispatch([], Session) :-
    !,
    default_cli_options(Options),
    demo_session(all, Options, Session).
cli_dispatch([help|_], Session) :-
    !,
    help_session(help, Session).
cli_dispatch(['--help'|_], Session) :-
    !,
    help_session(help, Session).
cli_dispatch([Command|Rest], Session) :-
    cli_help_scope(Command, Rest, Scope),
    !,
    help_session(help(Scope), Session).
cli_dispatch([demo|Rest], Session) :-
    !,
    parse_cli_options(Rest, Options, Positionals),
    demo_name(Positionals, Name),
    demo_session(Name, Options, Session).
cli_dispatch([agent|Rest], Session) :-
    !,
    shortcut_demo(agent, Rest, Session).
cli_dispatch([graph|Rest], Session) :-
    !,
    shortcut_demo(graph, Rest, Session).
cli_dispatch([mcp|Rest], Session) :-
    !,
    shortcut_demo(mcp, Rest, Session).
cli_dispatch([direct|Rest], Session) :-
    !,
    parse_cli_options(Rest, Options, Positionals),
    positional_text(Positionals, prompt, Prompt),
    direct_session(Prompt, Options, Session).
cli_dispatch([rlm|Rest], Session) :-
    !,
    parse_cli_options(Rest, Options, Positionals),
    positional_text(Positionals, query, Query),
    rlm_session(Query, Options, Session).
cli_dispatch(['trace-view'|Rest], Session) :-
    !,
    parse_cli_options(Rest, Options, Positionals),
    single_positional(Positionals, trace_path, Path),
    trace_view_session(Path, Options, Session).
cli_dispatch(['effect-store',migrate|Rest], Session) :-
    !,
    effect_store_migration_session(Rest, Session).
cli_dispatch([Command|_], _) :-
    throw(cli_fault(unknown_command(Command))).

help_session(Command, Session) :-
    default_cli_options(Options),
    cli_usage(Usage),
    Session = cli_session{command:Command,
                          status:pass,
                          summary:Usage,
                          payload:_{usage:Usage},
                          output:Options}.

cli_help_scope('effect-store', [migrate|Rest], effect_store_migrate) :-
    memberchk('--help', Rest),
    !.
cli_help_scope('effect-store', Rest, 'effect-store') :-
    memberchk('--help', Rest),
    !.
cli_help_scope(Command, Rest, Command) :-
    memberchk(Command, [demo,agent,graph,mcp,direct,rlm,'trace-view']),
    memberchk('--help', Rest).

shortcut_demo(Name, Rest, Session) :-
    parse_cli_options(Rest, Options, Positionals),
    require_no_positionals(Positionals, Name),
    demo_session(Name, Options, Session).

/* Offline effect-store migration -------------------------------------- */

effect_store_migration_session(Args, Session) :-
    parse_migration_cli_options(Args, MigrationOptions),
    effect_store_migrate(MigrationOptions, Report),
    migration_cli_status(Report.status, Status),
    format(string(Summary), 'effect-store migration: ~w~n', [Report.status]),
    default_cli_options(Output0),
    put_dict(json, Output0, true, Output),
    Session = cli_session{command:effect_store_migrate,
                          status:Status,
                          summary:Summary,
                          payload:Report,
                          output:Output}.

migration_cli_status(migrated, pass) :- !.
migration_cli_status(already_migrated, pass) :- !.
migration_cli_status(_, fail).

parse_migration_cli_options(Args, Options) :-
    Defaults = migration_options{source:none,output:none,manifest:none,
                                 backup:none,in_place:false},
    parse_migration_options(Args, Defaults, Options).

parse_migration_options([], Options, Options).
parse_migration_options(['--source',Value|Rest], O0, O) :-
    !, atom_arg(Value, Path), put_dict(source, O0, Path, O1),
    parse_migration_options(Rest, O1, O).
parse_migration_options(['--output',Value|Rest], O0, O) :-
    !, atom_arg(Value, Path), put_dict(output, O0, Path, O1),
    parse_migration_options(Rest, O1, O).
parse_migration_options(['--manifest',Value|Rest], O0, O) :-
    !, atom_arg(Value, Path), put_dict(manifest, O0, Path, O1),
    parse_migration_options(Rest, O1, O).
parse_migration_options(['--backup',Value|Rest], O0, O) :-
    !, atom_arg(Value, Path), put_dict(backup, O0, Path, O1),
    parse_migration_options(Rest, O1, O).
parse_migration_options(['--in-place'|Rest], O0, O) :-
    !, put_dict(in_place, O0, true, O1),
    parse_migration_options(Rest, O1, O).
parse_migration_options(['--json'|Rest], O0, O) :-
    !, parse_migration_options(Rest, O0, O).
parse_migration_options([Option|_], _, _) :-
    throw(cli_fault(unknown_migration_option(Option))).

/* Deterministic demos -------------------------------------------------- */

demo_session(Name, Options, Session) :-
    demo(Name, Result0),
    normalize_demo_result(Result0, Result, Status),
    format(string(Summary), 'demo ~w: ~w~n', [Name, Status]),
    Session = cli_session{command:demo(Name),
                          status:Status,
                          summary:Summary,
                          payload:Result,
                          output:Options}.

normalize_demo_result(error(Error), Error, fail) :- !.
normalize_demo_result(Result, Result, Status) :-
    (   get_dict(status, Result, Found)
    ->  Status = Found
    ;   Status = pass
    ).

/* Direct provider completion ------------------------------------------ */

direct_session(Prompt, Options, Session) :-
    provider_from_options(Options, ProviderName, Provider, Model),
    completion_budget_from_options(Options, Budget),
    RuntimeBase = [provider(Provider),
                   provider_name(ProviderName),
                   planner_max_tokens(Options.max_tokens),
                   budget(Budget)],
    runtime_reasoning_options(Options, ReasoningOptions),
    append(RuntimeBase, ReasoningOptions, RuntimeOptions),
    llm_query(Prompt, RuntimeOptions, Outcome),
    direct_outcome(ProviderName, Model, Outcome, Options, Session).

direct_outcome(ProviderName, Model, ok(Result), Options, Session) :-
    !,
    result_output_text(Result.response, Text),
    format(string(Summary),
           'direct via ~w (~w): ~s~n',
           [ProviderName, Model, Text]),
    Session = cli_session{command:direct,
                          status:pass,
                          summary:Summary,
                          payload:Result,
                          output:Options}.
direct_outcome(ProviderName, Model, error(Error), Options, Session) :-
    format(string(Summary),
           'direct via ~w (~w) failed: ~q~n',
           [ProviderName, Model, Error]),
    Session = cli_session{command:direct,
                          status:fail,
                          summary:Summary,
                          payload:Error,
                          output:Options}.

/* Bounded real RLM completion ----------------------------------------- */

rlm_session(Query, Options, Session) :-
    provider_from_options(Options, ProviderName, Provider, Model),
    rlm_context(Query, Options, ContextText),
    simple_recursive_plan(ProviderName,
                          Options.max_tokens,
                          ContextText,
                          Plan),
    completion_budget_from_options(Options, Budget0),
    put_dict(_{max_recursion_depth:1,
               max_model_calls:2,
               max_context_ops:1},
             Budget0,
             Budget),
    RuntimeBase = [provider(Provider),
                   provider_name(ProviderName),
                   capabilities([rlm,
                                 context(slice),
                                 model(ProviderName)]),
                   child_capabilities([model(ProviderName)]),
                   planner_handler(rlm_cli:fixed_cli_planner(Plan)),
                   planner_attempts(1),
                   planner_max_tokens(1),
                   context_options([max_bytes(Options.context_bytes),
                                    time_limit(2.0)]),
                   budget(Budget)],
    runtime_reasoning_options(Options, ReasoningOptions),
    append(RuntimeBase, ReasoningOptions, RuntimeOptions),
    rlm_completion(Query,
                   text(ContextText),
                   RuntimeOptions,
                   Outcome),
    rlm_outcome(ProviderName, Model, Outcome, Options, Session).

rlm_outcome(ProviderName, Model, ok(Result), Options, Session) :-
    !,
    completion_output_text(Result, Text),
    format(string(Summary),
           'rlm via ~w (~w), depth ~d, ~d runtime model slots: ~s~n',
           [ProviderName,
            Model,
            Result.recursion.max_depth,
            Result.usage.model_calls,
            Text]),
    Session = cli_session{command:rlm,
                          status:pass,
                          summary:Summary,
                          payload:Result,
                          output:Options}.
rlm_outcome(ProviderName, Model, error(Error), Options, Session) :-
    format(string(Summary),
           'rlm via ~w (~w) failed: ~q~n',
           [ProviderName, Model, Error]),
    Session = cli_session{command:rlm,
                          status:fail,
                          summary:Summary,
                          payload:Error,
                          output:Options}.

rlm_context(Query, Options, ContextText) :-
    context_payload(Options, UserContext),
    format(string(ContextText),
           'Question: ~s~n~nExternal context:~n~s~n',
           [Query, UserContext]).

context_payload(Options, Text) :-
    Options.context_file \== none,
    !,
    read_file_to_string(Options.context_file, Text, []).
context_payload(Options, Text) :-
    Options.context \== none,
    !,
    Text = Options.context.
context_payload(_, "No additional external context was supplied.").

simple_recursive_plan(ProviderName,
                      MaxTokens,
                      ContextText,
                      Plan) :-
    string_length(ContextText, RawLength),
    ContextLength is max(1, min(RawLength, 8192)),
    Plan = plan([
               context(input(context),
                       slice(0, ContextLength),
                       snippet),
               rlm(plan([
                       model(ProviderName,
                             var(snippet),
                             _{max_tokens:MaxTokens},
                             child_response),
                       final(var(child_response))
                   ]),
                   child),
               final(var(child))
           ]).

fixed_cli_planner(Plan, _Request,
                  _{plan:Plan,
                    usage:_{prompt_tokens:0,
                            completion_tokens:0,
                            total_tokens:0,
                            cost:0.0}}).

/* Provider configuration ---------------------------------------------- */

runtime_reasoning_options(Options, RuntimeOptions) :-
    findall(Option,
            runtime_reasoning_option(Options, Option),
            RuntimeOptions).

runtime_reasoning_option(Options, reasoning_effort(Effort)) :-
    Options.reasoning_effort \== unspecified,
    Effort = Options.reasoning_effort.
runtime_reasoning_option(Options, planner_reasoning_effort(Effort)) :-
    Options.planner_reasoning_effort \== inherit,
    Effort = Options.planner_reasoning_effort.

provider_from_options(Options, openrouter, Provider, Model) :-
    Options.endpoint == none,
    !,
    resolve_openrouter_model(Options.model, Model),
    openrouter_provider(Model, Provider).
provider_from_options(Options, openai_compatible, Provider, Model) :-
    Options.model \== auto,
    !,
    Model = Options.model,
    endpoint_atom(Options.endpoint, Endpoint),
    credential_option(Options, Credential),
    openai_compatible_provider(Endpoint,
                               Credential,
                               Model,
                               Provider).
provider_from_options(Options, _, _, _) :-
    throw(cli_fault(model_required_for_endpoint(Options.endpoint))).

resolve_openrouter_model(auto, Model) :-
    !,
    default_openrouter_model(Model).
resolve_openrouter_model(Model, Model).

credential_option(Options, none) :-
    Options.no_credential == true,
    !.
credential_option(Options, env(Name)) :-
    atom_string(Name, Options.credential_env).

endpoint_atom(Value, Value) :- atom(Value), !.
endpoint_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
endpoint_atom(Value, _) :- throw(cli_fault(invalid_endpoint(Value))).

completion_budget_from_options(Options,
                               _{max_total_tokens:TotalTokens,
                                 max_cost_usd:Options.max_cost_usd,
                                 max_output_bytes:65536,
                                 time_limit:Options.time_limit}) :-
    TotalTokens is max(512, Options.max_tokens*4).

/* Trace export and inspection ----------------------------------------- */

trace_view_session(Path, Options, Session) :-
    trace_view_file(Path, Options.trace_format, Outcome),
    trace_view_outcome(Path, Outcome, Options, Session).

trace_view_outcome(Path, ok(Text), Options0, Session) :-
    !,
    put_dict(view, Options0, true, Options),
    Session = cli_session{command:trace_view,
                          status:pass,
                          summary:Text,
                          payload:_{path:Path, view:Text},
                          output:Options}.
trace_view_outcome(_, error(Error), Options, Session) :-
    Session = cli_session{command:trace_view,
                          status:fail,
                          summary:"trace view failed\n",
                          payload:Error,
                          output:Options}.

maybe_export_trace(Session0, Session) :-
    Options = Session0.output,
    (   Options.trace == none
    ->  Session = Session0
    ;   trace_write(Options.trace,
                    Options.trace_format,
                    Session0.command,
                    Session0.payload,
                    WriteOutcome),
        put_dict(trace_export, Session0, WriteOutcome, Session)
    ).

emit_session(Session) :-
    Options = Session.output,
    (   Options.json == true
    ->  trace_envelope(Session.command, Session.payload, Envelope),
        trace_json(Envelope, Json),
        format('~s~n', [Json])
    ;   Options.view == true
    ->  trace_view(Session.payload, View),
        format('~s', [View])
    ;   format('~s', [Session.summary])
    ),
    emit_trace_export(Session).

emit_trace_export(Session) :-
    (   get_dict(trace_export, Session, ok(Result))
    ->  format(user_error,
               'trace: ~w (~w, ~d bytes)~n',
               [Result.path, Result.format, Result.bytes])
    ;   get_dict(trace_export, Session, error(Error))
    ->  format(user_error, 'trace export failed: ~q~n', [Error])
    ;   true
    ).

result_output_text(Response, Text) :-
    response_channel_text(Response, Text),
    !.
result_output_text(_, "<no assistant text>").

completion_output_text(Result, Text) :-
    response_channel_text(Result.value, Text),
    !.
completion_output_text(Result, Text) :-
    term_string(Result.value,
                Text,
                [quoted(true), max_depth(5), numbervars(true)]).

response_channel_text(Response, Text) :-
    is_dict(Response),
    get_dict(text, Response, Text),
    string(Text),
    Text \== "",
    !.
response_channel_text(Response, Text) :-
    is_dict(Response),
    get_dict(reasoning, Response, Text),
    string(Text),
    Text \== "".

/* Options -------------------------------------------------------------- */

default_cli_options(
    cli_options{json:false,
                view:false,
                trace:none,
                trace_format:json,
                model:auto,
                reasoning_effort:unspecified,
                planner_reasoning_effort:inherit,
                endpoint:none,
                credential_env:"OPENAI_API_KEY",
                no_credential:false,
                context:none,
                context_file:none,
                context_bytes:8192,
                max_tokens:256,
                max_cost_usd:0.25,
                time_limit:120.0}).

parse_cli_options(Args, Options, Positionals) :-
    default_cli_options(Default),
    parse_options(Args, Default, Options, [], Reversed),
    reverse(Reversed, Positionals).

parse_options([], Options, Options, Positionals, Positionals).
parse_options(['--json'|Rest], O0, O, P0, P) :-
    !, put_dict(json, O0, true, O1), parse_options(Rest, O1, O, P0, P).
parse_options(['--view'|Rest], O0, O, P0, P) :-
    !, put_dict(view, O0, true, O1), parse_options(Rest, O1, O, P0, P).
parse_options(['--no-credential'|Rest], O0, O, P0, P) :-
    !, put_dict(no_credential, O0, true, O1), parse_options(Rest, O1, O, P0, P).
parse_options(['--trace',Value|Rest], O0, O, P0, P) :-
    !, text_arg(Value, Text), put_dict(trace, O0, Text, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--trace-format',Value|Rest], O0, O, P0, P) :-
    !, atom_arg(Value, Format), require_member(Format, [json,jsonl], trace_format),
    put_dict(trace_format, O0, Format, O1), parse_options(Rest, O1, O, P0, P).
parse_options(['--model',Value|Rest], O0, O, P0, P) :-
    !, atom_arg(Value, Model), put_dict(model, O0, Model, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--reasoning-effort',Value|Rest], O0, O, P0, P) :-
    !,
    atom_arg(Value, Effort),
    require_member(Effort, [none,minimal,low,medium,high,xhigh,max], reasoning_effort),
    put_dict(reasoning_effort, O0, Effort, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--planner-reasoning-effort',Value|Rest], O0, O, P0, P) :-
    !,
    atom_arg(Value, Effort),
    require_member(Effort, [none,minimal,low,medium,high,xhigh,max], planner_reasoning_effort),
    put_dict(planner_reasoning_effort, O0, Effort, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--endpoint',Value|Rest], O0, O, P0, P) :-
    !, text_arg(Value, Endpoint), put_dict(endpoint, O0, Endpoint, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--credential-env',Value|Rest], O0, O, P0, P) :-
    !, text_arg(Value, Name), put_dict(credential_env, O0, Name, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--context',Value|Rest], O0, O, P0, P) :-
    !, text_arg(Value, Context), put_dict(context, O0, Context, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--context-file',Value|Rest], O0, O, P0, P) :-
    !, text_arg(Value, Path), put_dict(context_file, O0, Path, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--context-bytes',Value|Rest], O0, O, P0, P) :-
    !, positive_integer_arg(Value, Bytes), put_dict(context_bytes, O0, Bytes, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--max-tokens',Value|Rest], O0, O, P0, P) :-
    !, positive_integer_arg(Value, N), put_dict(max_tokens, O0, N, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--max-cost',Value|Rest], O0, O, P0, P) :-
    !, nonnegative_number_arg(Value, Cost), put_dict(max_cost_usd, O0, Cost, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--time-limit',Value|Rest], O0, O, P0, P) :-
    !, positive_number_arg(Value, Seconds), put_dict(time_limit, O0, Seconds, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options([Arg|_], _, _, _, _) :-
    atom(Arg), sub_atom(Arg, 0, 2, _, '--'), !,
    throw(cli_fault(unknown_option(Arg))).
parse_options([Arg|Rest], O0, O, P0, P) :-
    parse_options(Rest, O0, O, [Arg|P0], P).

normalize_argv([], []).
normalize_argv([Arg0|Rest0], [Arg|Rest]) :-
    atom_arg(Arg0, Arg),
    normalize_argv(Rest0, Rest).

atom_arg(Value, Value) :- atom(Value), !.
atom_arg(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
atom_arg(Value, _) :- throw(cli_fault(invalid_argument(Value))).

text_arg(Value, Value) :- string(Value), !.
text_arg(Value, Text) :- atom(Value), !, atom_string(Value, Text).
text_arg(Value, _) :- throw(cli_fault(invalid_text_argument(Value))).

number_arg(Value, Value) :- number(Value), !.
number_arg(Value, Number) :- atom(Value), atom_number(Value, Number), !.
number_arg(Value, Number) :- string(Value), number_string(Number, Value), !.
number_arg(Value, _) :- throw(cli_fault(invalid_number(Value))).

positive_integer_arg(Value, Number) :-
    number_arg(Value, Number), integer(Number), Number > 0, !.
positive_integer_arg(Value, _) :- throw(cli_fault(invalid_positive_integer(Value))).

positive_number_arg(Value, Number) :-
    number_arg(Value, Number), Number > 0, !.
positive_number_arg(Value, _) :- throw(cli_fault(invalid_positive_number(Value))).

nonnegative_number_arg(Value, Number) :-
    number_arg(Value, Number), Number >= 0, !.
nonnegative_number_arg(Value, _) :-
    throw(cli_fault(invalid_nonnegative_number(Value))).

positional_text([], Name, _) :- throw(cli_fault(missing_argument(Name))).
positional_text(Positionals, _, Text) :-
    maplist(text_arg, Positionals, Parts),
    atomics_to_string(Parts, " ", Text).

single_positional([Value], _, Text) :- !, text_arg(Value, Text).
single_positional([], Name, _) :- throw(cli_fault(missing_argument(Name))).
single_positional(Values, Name, _) :-
    throw(cli_fault(too_many_arguments(Name, Values))).

require_no_positionals([], _) :- !.
require_no_positionals(Values, Command) :-
    throw(cli_fault(unexpected_arguments(Command, Values))).

demo_name([], all) :- !.
demo_name([Value], Name) :- !, atom_arg(Value, Name).
demo_name(Values, _) :- throw(cli_fault(invalid_demo_arguments(Values))).

require_member(Value, Allowed, _) :- memberchk(Value, Allowed), !.
require_member(Value, _, Name) :- throw(cli_fault(invalid_option(Name, Value))).

/* Help and errors ------------------------------------------------------ */

cli_usage(Usage) :-
    Lines = [
        "prolog-rlm",
        "",
        "Usage:",
        "  prolog-rlm demo [all|context|tool|recursion|agent|graph|mcp] [output options]",
        "  prolog-rlm direct PROMPT [provider options] [output options]",
        "  prolog-rlm rlm QUERY [--context TEXT|--context-file PATH] [provider options] [output options]",
        "  prolog-rlm agent|graph|mcp [output options]",
        "  prolog-rlm trace-view PATH [--trace-format json|jsonl]",
        "  prolog-rlm effect-store migrate --source LEDGER --output LEDGER.v2 [--manifest FILE] [--json]",
        "  prolog-rlm effect-store migrate --source LEDGER --in-place --backup LEDGER.bak [--manifest FILE] [--json]",
        "",
        "Provider options:",
        "  --model MODEL                 OpenRouter model; defaults to OPENROUTER_TEST_MODEL or openrouter/free",
        "  --reasoning-effort EFFORT      none|minimal|low|medium|high|xhigh|max",
        "  --planner-reasoning-effort EFFORT  Override planner effort; otherwise inherits reasoning effort",
        "  --endpoint URL                Use an OpenAI-compatible endpoint instead of OpenRouter",
        "  --credential-env NAME         Credential env var for custom endpoint (default OPENAI_API_KEY)",
        "  --no-credential               Custom endpoint requires no credential",
        "  --max-tokens N                Direct/child response limit (default 256)",
        "  --max-cost USD                Completion cost ceiling (default 0.25)",
        "  --time-limit SECONDS          Completion wall-clock limit (default 120)",
        "",
        "RLM options:",
        "  --context TEXT",
        "  --context-file PATH",
        "  --context-bytes N             Context byte ceiling (default 8192)",
        "",
        "Output options:",
        "  --json                        Emit portable trace-envelope JSON",
        "  --view                        Emit hierarchical trace view",
        "  --trace PATH                  Export command payload",
        "  --trace-format json|jsonl     Export/read format (default json)",
        "",
        "Examples:",
        "  prolog-rlm demo",
        "  prolog-rlm direct \"Say hello\"",
        "  prolog-rlm rlm \"What token is in this context?\" --context \"TOKEN_42\"",
        "  prolog-rlm direct \"hello\" --endpoint http://127.0.0.1:8000/v1/chat/completions --model local-model --no-credential",
        "  prolog-rlm demo graph --trace graph.json --view",
        ""
    ],
    atomics_to_string(Lines, "\n", Usage).

cli_exception(cli_fault(Detail), error(Error)) :-
    !,
    Error = cli_error{kind:invalid_cli_request,
                      detail:Detail,
                      message:"prolog-rlm CLI rejected the request"}.
cli_exception(Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = cli_error{kind:exception,
                      exception:Safe,
                      message:"prolog-rlm CLI raised an exception"}.
