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

:- use_module(library(http/json)).
:- use_module(library(readutil)).
:- use_module(rlm_chain).
:- use_module(rlm_completion).
:- use_module(rlm_demo).
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
    default_cli_options(Options),
    cli_usage(Usage),
    Session = cli_session{command:help,
                          status:pass,
                          summary:Usage,
                          payload:_{usage:Usage},
                          output:Options}.
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
cli_dispatch([Command|_], _) :-
    throw(cli_fault(unknown_command(Command))).

shortcut_demo(Name, Rest, Session) :-
    parse_cli_options(Rest, Options, Positionals),
    require_no_positionals(Positionals, Name),
    demo_session(Name, Options, Session).

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
    RuntimeOptions = [provider(Provider),
                      provider_name(ProviderName),
                      planner_max_tokens(Options.max_tokens),
                      budget(Budget)],
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
    simple_recursive_planner_instruction(ProviderName,
                                         Options.max_tokens,
                                         ContextText,
                                         PlannerInstruction),
    completion_budget_from_options(Options, Budget0),
    put_dict(_{max_recursion_depth:1,
               max_model_calls:3,
               max_context_ops:1},
             Budget0,
             Budget),
    RuntimeOptions = [provider(Provider),
                      provider_name(ProviderName),
                      capabilities([rlm,
                                    context(slice),
                                    model(ProviderName)]),
                      child_capabilities([model(ProviderName)]),
                      planner_instruction(PlannerInstruction),
                      planner_attempts(Options.planner_attempts),
                      planner_max_tokens(Options.planner_max_tokens),
                      context_options([max_bytes(Options.context_bytes),
                                       time_limit(2.0)]),
                      budget(Budget)],
    rlm_completion(Query,
                   text(ContextText),
                   RuntimeOptions,
                   Outcome),
    rlm_outcome(ProviderName, Model, Outcome, Options, Session).

rlm_outcome(ProviderName, Model, ok(Result), Options, Session) :-
    !,
    completion_output_text(Result, Text),
    format(string(Summary),
           'rlm via ~w (~w), depth ~d, ~d model calls: ~s~n',
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

simple_recursive_planner_instruction(ProviderName,
                                     MaxTokens,
                                     ContextText,
                                     Instruction) :-
    string_length(ContextText, RawLength),
    ContextLength is max(1, min(RawLength, 8192)),
    atom_string(ProviderName, ProviderString),
    Plan = _{steps:[
                 _{op:"context",
                   handle:_{ref:"input", name:"context"},
                   action:_{type:"slice", start:0, length:ContextLength},
                   bind:"snippet"},
                 _{op:"rlm",
                   plan:_{steps:[
                              _{op:"model",
                                provider:ProviderString,
                                prompt:_{ref:"var", name:"snippet"},
                                options:_{max_tokens:MaxTokens},
                                bind:"child_response"},
                              _{op:"final",
                                value:_{ref:"var", name:"child_response"}}
                          ]},
                   bind:"child"},
                 _{op:"final",
                   value:_{ref:"var", name:"child"}}
             ]},
    with_output_to(string(PlanJson),
                   json_write_dict(current_output, Plan, [width(0)])),
    format(string(Instruction),
           'For this CLI invocation return exactly the following JSON plan, changing only insignificant JSON whitespace. Return no markdown or explanation.~n~s',
           [PlanJson]).

/* Provider configuration ---------------------------------------------- */

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
    TotalTokens is max(Options.max_tokens*4,
                       Options.planner_max_tokens*2).

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
                endpoint:none,
                credential_env:"OPENAI_API_KEY",
                no_credential:false,
                context:none,
                context_file:none,
                context_bytes:8192,
                max_tokens:256,
                planner_attempts:2,
                planner_max_tokens:1200,
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
parse_options(['--planner-attempts',Value|Rest], O0, O, P0, P) :-
    !, positive_integer_arg(Value, N), put_dict(planner_attempts, O0, N, O1),
    parse_options(Rest, O1, O, P0, P).
parse_options(['--planner-max-tokens',Value|Rest], O0, O, P0, P) :-
    !, positive_integer_arg(Value, N), put_dict(planner_max_tokens, O0, N, O1),
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
        "",
        "Provider options:",
        "  --model MODEL                 OpenRouter model; defaults to OPENROUTER_TEST_MODEL or openrouter/free",
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
        "  --planner-attempts N          Root planner parse attempts (default 2)",
        "  --planner-max-tokens N        Root planner token limit (default 1200)",
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
