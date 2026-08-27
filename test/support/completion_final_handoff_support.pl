:- module(completion_final_handoff_support,
          [ final_handoff_planner/2,
            recursive_final_handoff_planner/2,
            two_model_final_handoff_planner/2,
            repair_then_final_handoff_planner/2,
            native_tool_call_planner/2,
            missing_final_planner/2,
            start_final_handoff_server/1,
            stop_final_handoff_server/1,
            set_final_handoff_mode/1,
            final_handoff_requests/1,
            reset_repair_handoff/0
          ]).

:- use_module(library(http/http_dispatch)).
:- use_module(library(http/json)).
:- use_module(library(http/http_json)).
:- use_module(library(http/thread_httpd)).
:- use_module('../../benchmark/rlm_constraint_problem').

:- dynamic final_handoff_mode/1.
:- dynamic final_handoff_port/1.
:- dynamic final_handoff_request/1.
:- dynamic final_handoff_solution/1.
:- dynamic repair_handoff_call/1.

:- http_handler(root(rlm_final_handoff),
                final_handoff_handler,
                [method(post)]).

final_handoff_planner(_, ok(Output)) :-
    Plan = plan([model(openai_compatible,
                       input(query),
                       _{},
                       answer),
                 final(var(answer))]),
    planner_output(Plan, Output).

recursive_final_handoff_planner(_, ok(Output)) :-
    Child = plan([model(openai_compatible,
                        input(query),
                        _{},
                        child_answer),
                  final(var(child_answer))]),
    Plan = plan([rlm(Child, child),
                 final(var(child))]),
    planner_output(Plan, Output).

two_model_final_handoff_planner(_, ok(Output)) :-
    Plan = plan([model(openai_compatible,
                       input(query),
                       _{},
                       early),
                 model(openai_compatible,
                       input(query),
                       _{},
                       final_answer),
                 final(var(final_answer))]),
    planner_output(Plan, Output).

repair_then_final_handoff_planner(_, ok(Output)) :-
    repair_handoff_call(Call),
    retractall(repair_handoff_call(_)),
    Next is Call+1,
    assertz(repair_handoff_call(Next)),
    (   Call =:= 0
    ->  Plan = plan([final(literal("invalid-first")),
                    final(literal("second-final"))])
    ;   Plan = plan([model(openai_compatible,
                           input(query),
                           _{},
                           answer),
                     final(var(answer))])
    ),
    planner_output(Plan, Output).

native_tool_call_planner(_, ok(Response)) :-
    Response = model_response{provider:openai_compatible,
                              requested_model:'test/final-handoff',
                              selected_model:'test/final-handoff',
                              response_id:"native-tool-plan",
                              text:"",
                              tool_calls:[_{id:"call-1",
                                            type:"function",
                                            function:_{name:"plan",
                                                       arguments:"{\\\"steps\\\":[]}"}}],
                              reasoning:"",
                              reasoning_details:[],
                              finish_reason:tool_calls,
                              usage:usage{present:true,
                                          prompt_tokens:1,
                                          completion_tokens:1,
                                          total_tokens:2,
                                          cost:0.0},
                              metadata:provider_metadata{http_status:200,
                                                          response_received:true}}.

missing_final_planner(_, ok(Output)) :-
    planner_output(plan([checkpoint(no_final)]), Output).

reset_repair_handoff :-
    retractall(repair_handoff_call(_)),
    assertz(repair_handoff_call(0)).

planner_output(Plan,
               planner_output{plan:Plan,
                              usage:_{prompt_tokens:1,
                                      completion_tokens:1,
                                      total_tokens:2,
                                      cost:0.0}}).

start_final_handoff_server(Port) :-
    retractall(final_handoff_mode(_)),
    retractall(final_handoff_port(_)),
    retractall(final_handoff_request(_)),
    retractall(final_handoff_solution(_)),
    assertz(final_handoff_mode(leak_sensitive)),
    known_solution_json(Solution),
    assertz(final_handoff_solution(Solution)),
    http_server(http_dispatch, [port(Port)]),
    assertz(final_handoff_port(Port)).

stop_final_handoff_server(Port) :-
    catch(http_stop_server(Port, []), _, true),
    retractall(final_handoff_port(_)),
    retractall(final_handoff_mode(_)),
    retractall(final_handoff_request(_)),
    retractall(final_handoff_solution(_)).

set_final_handoff_mode(Mode) :-
    memberchk(Mode, [leak_sensitive, planner, mixed, sequenced, error]),
    retractall(final_handoff_mode(_)),
    assertz(final_handoff_mode(Mode)).

final_handoff_requests(Requests) :-
    findall(Request,
            final_handoff_request(Request),
            Requests).

final_handoff_handler(Request) :-
    final_handoff_mode(error),
    !,
    http_read_json_dict(Request, Payload),
    assertz(final_handoff_request(Payload)),
    reply_json_dict(_{error:_{message:"deterministic final execution failure"}},
                    [status(500)]).
final_handoff_handler(Request) :-
    http_read_json_dict(Request, Payload),
    assertz(final_handoff_request(Payload)),
    final_handoff_response(Payload, Text, Reasoning),
    reply_json_dict(_{id:"final-handoff",
                      object:"chat.completion",
                      model:"test/final-handoff",
                      choices:[_{index:0,
                                 message:_{role:"assistant",
                                           content:Text,
                                           reasoning:Reasoning},
                                 finish_reason:"stop"}],
                      usage:_{prompt_tokens:1,
                              completion_tokens:1,
                              total_tokens:2}}).

final_handoff_response(Payload, Text, Reasoning) :-
    final_handoff_mode(Mode),
    (   Mode == planner
    ->  planner_response(Text), Reasoning = ""
    ;   Mode == mixed
    ->  final_handoff_solution(Text), planner_response(Reasoning)
    ;   Mode == sequenced
    ->  final_handoff_request_count(Count),
        sequenced_response(Count, Text), Reasoning = ""
    ;   planner_context_present(Payload)
    ->  planner_response(Text), Reasoning = ""
    ;   final_handoff_solution(Text), Reasoning = ""
    ).

planner_response("{\"steps\":[{\"op\":\"final\",\"value\":\"planner-leak\"}]}").

sequenced_response(1, "EARLIER_MODEL_RESULT").
sequenced_response(_, Text) :- final_handoff_solution(Text).

final_handoff_request_count(Count) :-
    findall(Request, final_handoff_request(Request), Requests),
    length(Requests, Count).

known_solution_json(Json) :-
    constraint_known_solution(Solution),
    atom_json_dict(Atom, Solution, [width(0)]),
    atom_string(Atom, Json).

planner_context_present(Payload) :-
    get_dict(messages, Payload, Messages),
    member(Message, Messages),
    get_dict(role, Message, Role),
    role_is_system(Role),
    get_dict(content, Message, Content),
    text_string(Content, Text),
    sub_string(Text, _, _, _, "{\"steps\":[...]}"),
    !.

role_is_system(system).
role_is_system("system").

text_string(Text, Text) :- string(Text), !.
text_string(Atom, Text) :- atom(Atom), atom_string(Atom, Text).
