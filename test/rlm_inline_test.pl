:- begin_tests(rlm_inline).

:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_inline').
:- use_module('../prolog/prolog_agent_ui_v1').
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_server)).
:- use_module(library(http/json)).

/* Caps and grants --------------------------------------------------------- */

test(default_caps_within_hard_ceilings) :-
    rlm_inline_default_caps(Caps),
    get_dict(max_tokens, Caps, DefaultTokens),
    get_dict(time_limit, Caps, DefaultTime),
    get_dict(max_proposals, Caps, DefaultProposals),
    rlm_inline:hard_cap(max_tokens, HardTokens),
    rlm_inline:hard_cap(time_limit, HardTime),
    rlm_inline:hard_cap(max_proposals, HardProposals),
    DefaultTokens =< HardTokens,
    DefaultTime =< HardTime,
    DefaultProposals =< HardProposals.

test(grant_defaults_when_caps_partial) :-
    rlm_inline_grant(agent(inline_defaults, 1), _{}, ok(Grant)),
    get_dict(caps, Grant, Caps),
    rlm_inline_default_caps(Default),
    Caps == Default,
    get_dict(remaining, Grant, Remaining),
    get_dict(max_proposals, Default, Remaining).

test(grant_rejects_cap_over_hard_ceiling) :-
    rlm_inline_grant(agent(inline_over, 1),
                     _{max_tokens:100000}, error(Error)),
    get_dict(kind, Error, cap_exceeded).

test(grant_rejects_invalid_caps) :-
    rlm_inline_grant(agent(inline_invalid, 1),
                     _{max_tokens:many}, error(Error)),
    get_dict(kind, Error, invalid_caps),
    rlm_inline_grant(agent(inline_invalid2, 1),
                     _{time_limit: (-1)}, error(Error2)),
    get_dict(kind, Error2, invalid_caps).

test(grant_ids_are_distinct) :-
    rlm_inline_grant(agent(inline_ids, 1), _{}, ok(G1)),
    rlm_inline_grant(agent(inline_ids, 1), _{}, ok(G2)),
    get_dict(id, G1, Id1),
    get_dict(id, G2, Id2),
    Id1 \== Id2.

/* Proposal options wiring (pure) ------------------------------------------ */

test(propose_options_carry_token_cap_and_handler) :-
    rlm_inline_default_caps(Caps),
    rlm_inline:propose_options(Caps, my_sink, Options),
    member(max_tokens(Tokens), Options),
    get_dict(max_tokens, Caps, Tokens),
    member(text_delta_handler(Sink), Options),
    Sink == my_sink.

/* Streaming proposals over a local provider ------------------------------- */

:- dynamic inline_seen/1.

reset_inline :-
    retractall(inline_seen(_)).

record_event(Event) :-
    assertz(inline_seen(Event)).

stream_provider(Port, Provider) :-
    format(atom(Endpoint), 'http://127.0.0.1:~d/inline_sse', [Port]),
    Config = [endpoint(Endpoint),
              credential(none),
              model('test/model')],
    Provider = provider(openai_compatible, Config).

chunk_line(Delta, Finish, Line) :-
    Chunk = _{id:"chat-1",
              model:"test/model",
              choices:[_{index:0,
                        delta:Delta,
                        finish_reason:Finish}]},
    with_output_to(string(Json),
                   json_write_dict(current_output, Chunk,
                                   [width(0), tab_distance(0)])),
    atom_concat('data: ', Json, Line).

usage_line(Line) :-
    Usage = _{id:"chat-1",
              model:"test/model",
              choices:[],
              usage:_{prompt_tokens:2, completion_tokens:3, total_tokens:5}},
    with_output_to(string(Json),
                   json_write_dict(current_output, Usage,
                                   [width(0), tab_distance(0)])),
    atom_concat('data: ', Json, Line).

hello_body(Body) :-
    chunk_line(_{role:assistant, content:"He"}, null, Line1),
    chunk_line(_{role:assistant, content:"llo"}, null, Line2),
    chunk_line(_{}, stop, Line3),
    usage_line(Line4),
    atomic_list_concat([Line1, Line2, Line3, Line4, 'data: [DONE]'], '\n',
                       T),
    string_concat(T, '\n', Body).

:- http_handler(root(inline_sse), inline_sse_handler, [method(post)]).

inline_sse_handler(_Request) :-
    hello_body(Body),
    format('Content-type: text/event-stream\n\n'),
    format('~s', [Body]).

with_inline_server(Goal) :-
    setup_call_cleanup(http_server(http_dispatch, [port(Port)]),
                       call(Goal, Port),
                       http_stop_server(Port, [])).

test(propose_streams_started_delta_finished, [setup(reset_inline)]) :-
    with_inline_server(propose_hello(Outcome)),
    (   Outcome = ok(Proposal)
    ->  true
    ;   assertion(failed(Outcome))
    ),
    get_dict(text, Proposal, "Hello"),
    get_dict(status, Proposal, finished),
    findall(Type, ( inline_seen(Event),
                    get_dict(type, Event, Type) ),
            Types),
    Types == [proposal_started, proposal_delta, proposal_delta,
              proposal_finished].

propose_hello(Outcome, Port) :-
    stream_provider(Port, Provider),
    rlm_inline_grant(agent(inline_stream, 1), _{}, ok(Grant)),
    rlm_inline_propose(Grant, "hello",
                       [provider(Provider),
                        sink(plunit_rlm_inline:record_event)],
                       Outcome).

test(propose_decrements_grant_remaining, [setup(reset_inline)]) :-
    with_inline_server(propose_twice),
    propagate_propose_twice.

:- dynamic propose_twice_result/1.

propose_twice(Port) :-
    stream_provider(Port, Provider),
    rlm_inline_grant(agent(inline_remaining, 1),
                     _{max_proposals:2}, ok(Grant)),
    rlm_inline_propose(Grant, "one",
                       [provider(Provider), sink(plunit_rlm_inline:record_event)],
                       ok(_)),
    get_dict(remaining, Grant, 1),
    rlm_inline_propose(Grant, "two",
                       [provider(Provider), sink(plunit_rlm_inline:record_event)],
                       ok(_)),
    get_dict(remaining, Grant, 0),
    (   rlm_inline_propose(Grant, "three",
                           [provider(Provider),
                            sink(plunit_rlm_inline:record_event)],
                           error(Error))
    ->  get_dict(kind, Error, grant_exhausted),
        assertz(propose_twice_result(passed))
    ;   assertz(propose_twice_result(failed))
    ).

propagate_propose_twice :-
    retract(propose_twice_result(passed)),
    !.
propagate_propose_twice :-
    retract(propose_twice_result(R)),
    assertion(R == passed).

/* Accept / discard and lineage -------------------------------------------- */

test(accept_records_lineage, [setup(reset_inline)]) :-
    with_inline_server(accept_flow),
    propagate_accept_flow.

:- dynamic accept_flow_result/1.

accept_flow(Port) :-
    stream_provider(Port, Provider),
    rlm_inline_grant(agent(inline_accept, 1), _{}, ok(Grant)),
    rlm_inline_propose(Grant, "pick me",
                       [provider(Provider), sink(plunit_rlm_inline:record_event)],
                       ok(Proposal)),
    get_dict(id, Proposal, ProposalId),
    (   rlm_inline_accept(ProposalId, ok(_))
    ->  rlm_inline_lineage(Grant, Rows),
        member(row(ProposalId, accepted, Info), Rows),
        get_dict(text, Info, "Hello"),
        (   rlm_inline_accept(ProposalId, error(Error))
        ->  get_dict(kind, Error, proposal_not_pending),
            assertz(accept_flow_result(passed))
        ;   assertz(accept_flow_result(double_accept_failed))
        )
    ;   assertz(accept_flow_result(accept_failed))
    ).

propagate_accept_flow :-
    retract(accept_flow_result(passed)),
    !.
propagate_accept_flow :-
    retract(accept_flow_result(R)),
    assertion(R == passed).

test(discard_records_lineage, [setup(reset_inline)]) :-
    with_inline_server(discard_flow),
    propagate_discard_flow.

:- dynamic discard_flow_result/1.

discard_flow(Port) :-
    stream_provider(Port, Provider),
    rlm_inline_grant(agent(inline_discard, 1), _{}, ok(Grant)),
    rlm_inline_propose(Grant, "drop me",
                       [provider(Provider), sink(plunit_rlm_inline:record_event)],
                       ok(Proposal)),
    get_dict(id, Proposal, ProposalId),
    (   rlm_inline_discard(ProposalId, superseded, ok(_))
    ->  rlm_inline_lineage(Grant, Rows),
        member(row(ProposalId, discarded, Info), Rows),
        get_dict(reason, Info, superseded),
        assertz(discard_flow_result(passed))
    ;   assertz(discard_flow_result(failed))
    ).

propagate_discard_flow :-
    retract(discard_flow_result(passed)),
    !.
propagate_discard_flow :-
    retract(discard_flow_result(R)),
    assertion(R == passed).

test(accept_unknown_proposal_fails_closed) :-
    rlm_inline_accept(inline_nope, error(Error)),
    get_dict(kind, Error, unknown_proposal).

/* UI protocol surface ------------------------------------------------------ */

test(proposal_event_types_are_known) :-
    member(Type, ["proposal_started", "proposal_delta",
                  "proposal_finished", "proposal_accepted",
                  "proposal_discarded"]),
    prolog_agent_ui_v1:known_event_type(Type).

test(initial_view_has_proposals) :-
    ui_v1_initial_view("inline_session", View),
    get_dict(proposals, View, []).

test(reducer_accumulates_proposal_lifecycle) :-
    Session = "inline_session",
    ui_v1_initial_view(Session, View0),
    ui_v1_event_frame(Session, 1, "e1", "proposal_started",
                      _{proposal_id:"prop_1", prompt:"hello"}, none, F1),
    ui_v1_apply_event(View0, F1, ok(View1)),
    ui_v1_event_frame(Session, 2, "e2", "proposal_delta",
                      _{proposal_id:"prop_1", delta:"He"}, none, F2),
    ui_v1_apply_event(View1, F2, ok(View2)),
    ui_v1_event_frame(Session, 3, "e3", "proposal_delta",
                      _{proposal_id:"prop_1", delta:"llo"}, none, F3),
    ui_v1_apply_event(View2, F3, ok(View3)),
    ui_v1_event_frame(Session, 4, "e4", "proposal_finished",
                      _{proposal_id:"prop_1"}, none, F4),
    ui_v1_apply_event(View3, F4, ok(View4)),
    ui_v1_event_frame(Session, 5, "e5", "proposal_accepted",
                      _{proposal_id:"prop_1"}, none, F5),
    ui_v1_apply_event(View4, F5, ok(View5)),
    get_dict(proposals, View5, [Proposal]),
    get_dict(status, Proposal, "accepted"),
    get_dict(text, Proposal, "Hello").

:- end_tests(rlm_inline).
