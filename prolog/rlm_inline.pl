:- module(rlm_inline,
          [ rlm_inline_default_caps/1,
            rlm_inline_grant/3,
            rlm_inline_propose/4,
            rlm_inline_propose_async/5,
            rlm_inline_accept/2,
            rlm_inline_discard/3,
            rlm_inline_lineage/2
          ]).

/** <module> Low-latency inline-completion session class (U1)

Ghost-text proposals run outside the full ADARD run ceremony.  A host
grants an inline session with hard-capped budgets; each proposal is a
single streaming model call whose deltas are surfaced as
proposal_started/proposal_delta/proposal_finished events; accept/discard
decisions are recorded as batched lineage rows.  Model output stays
data: accepting a proposal grants no authority beyond the lineage record.
*/

:- use_module(rlm_completion, [llm_query/3, llm_query_async/3]).
:- use_module(rlm_async, [rlm_future_await/2]).
:- use_module(library(gensym)).
:- use_module(library(lists)).

:- dynamic inline_proposal/2.    % Id, Record
:- dynamic inline_lineage_row/2. % GrantId, row(Id, Event, Info)

rlm_inline_default_caps(
    inline_caps{max_tokens:64,
                time_limit:2.0,
                max_proposals:16}).

hard_cap(max_tokens, 256).
hard_cap(time_limit, 10.0).
hard_cap(max_proposals, 256).

caps_key(max_tokens).
caps_key(time_limit).
caps_key(max_proposals).

/* Grants ------------------------------------------------------------------ */

rlm_inline_grant(Context, Requested, Outcome) :-
    (   typed_caps(Requested, Caps)
    ->  (   within_hard_caps(Caps)
        ->  gensym(inline_grant_, Id),
            get_time(At),
            get_dict(max_proposals, Caps, Remaining),
            Outcome = ok(inline_grant{id:Id,
                                      context:Context,
                                      caps:Caps,
                                      remaining:Remaining,
                                      created_at:At})
        ;   Outcome = error(inline_error{phase:grant,
                                         kind:cap_exceeded,
                                         message:"requested cap exceeds the hard ceiling"})
        )
    ;   Outcome = error(inline_error{phase:grant,
                                     kind:invalid_caps,
                                     message:"caps must be positive numbers on the known keys"})
    ).

typed_caps(Requested, Caps) :-
    rlm_inline_default_caps(Default),
    caps_pair(Requested, Default, max_tokens, Tokens),
    caps_pair(Requested, Default, time_limit, TimeLimit),
    caps_pair(Requested, Default, max_proposals, Proposals),
    Caps = inline_caps{max_tokens:Tokens,
                       time_limit:TimeLimit,
                       max_proposals:Proposals}.

caps_pair(Requested, Default, Key, Value) :-
    (   is_dict(Requested),
        get_dict(Key, Requested, Given)
    ->  Value = Given
    ;   get_dict(Key, Default, Value)
    ),
    typed_cap(Key, Value).

typed_cap(max_tokens, Value) :- integer(Value), Value >= 1.
typed_cap(max_proposals, Value) :- integer(Value), Value >= 1.
typed_cap(time_limit, Value) :- number(Value), Value > 0.

within_hard_caps(Caps) :-
    forall(caps_key(Key),
           ( get_dict(Key, Caps, Value),
             hard_cap(Key, Cap),
             Value =< Cap )).

/* Proposals ---------------------------------------------------------------- */

propose_options(Caps, Sink, Options) :-
    get_dict(max_tokens, Caps, MaxTokens),
    Options = [max_tokens(MaxTokens),
               text_delta_handler(Sink)].

rlm_inline_propose(Grant, Prompt, Options, Outcome) :-
    rlm_inline_propose_async(Grant, Prompt, Options, ProposalId, Future),
    rlm_future_await(Future, QueryOutcome),
    (   QueryOutcome = ok(_),
        inline_proposal(ProposalId, Record)
    ->  Outcome = ok(Record)
    ;   Outcome = QueryOutcome
    ).

rlm_inline_propose_async(Grant, Prompt, Options, ProposalId, Future) :-
    catch(prepare_proposal(Grant, Prompt, Options, ProposalId,
                           ProviderOpts),
          inline_fault(Detail),
          failed_future(Detail, Future)),
    (   var(ProviderOpts)
    ->  true
    ;   llm_query_async(Prompt, ProviderOpts, Future)
    ).

failed_future(Detail, Future) :-
    fault_kind(Detail, Kind),
    rlm_async:rlm_future_deferred(
        async_metadata{operation:inline_proposal}, Future),
    rlm_async:rlm_future_resolve(
        Future,
        error(inline_error{phase:propose, kind:Kind})).

fault_kind(grant_exhausted, grant_exhausted) :- !.
fault_kind(missing_sink, missing_sink) :- !.
fault_kind(invalid_grant(_), invalid_grant) :- !.
fault_kind(_, invalid_proposal).

prepare_proposal(Grant, Prompt, Options, ProposalId, ProviderOpts) :-
    check_grant(Grant),
    option_sink(Options, Sink),
    get_dict(caps, Grant, Caps),
    get_dict(id, Grant, GrantId),
    gensym(inline_proposal_, ProposalId),
    get_time(At),
    assertz(inline_proposal(ProposalId,
                            inline_proposal{id:ProposalId,
                                            grant_id:GrantId,
                                            text:"",
                                            status:streaming,
                                            created_at:At})),
    decrement_remaining(Grant),
    propose_options(Caps, rlm_inline:proposal_delta_sink(ProposalId, Sink),
                    StreamOpts),
    (   member(provider(Provider), Options)
    ->  ProviderOpts = [provider(Provider)|StreamOpts]
    ;   ProviderOpts = StreamOpts
    ),
    deliver(Sink, inline_event{type:proposal_started,
                               proposal_id:ProposalId,
                               prompt:Prompt}).

check_grant(Grant) :-
    is_dict(Grant),
    get_dict(remaining, Grant, Remaining),
    integer(Remaining),
    Remaining > 0,
    !.
check_grant(Grant) :-
    (   is_dict(Grant),
        get_dict(remaining, Grant, 0)
    ->  throw(inline_fault(grant_exhausted))
    ;   throw(inline_fault(invalid_grant(Grant)))
    ).

option_sink(Options, Sink) :-
    member(sink(Sink), Options),
    callable(Sink),
    !.
option_sink(_, _) :-
    throw(inline_fault(missing_sink)).

decrement_remaining(Grant) :-
    get_dict(remaining, Grant, Remaining),
    Next is Remaining - 1,
    nb_set_dict(remaining, Grant, Next).

proposal_delta_sink(ProposalId, Sink, Message) :-
    (   get_dict(phase, Message, delta),
        get_dict(text, Message, Delta)
    ->  deliver(Sink, inline_event{type:proposal_delta,
                                   proposal_id:ProposalId,
                                   delta:Delta}),
        append_proposal_text(ProposalId, Delta)
    ;   get_dict(phase, Message, completed)
    ->  finish_proposal(ProposalId, Sink)
    ;   true
    ).

deliver(Sink, Event) :-
    catch(call(Sink, Event), _, true).

append_proposal_text(ProposalId, Delta) :-
    with_mutex(rlm_inline,
               (   retract(inline_proposal(ProposalId, Record0))
               ->  get_dict(text, Record0, Text0),
                   string_concat(Text0, Delta, Text),
                   put_dict(text, Record0, Text, Record),
                   assertz(inline_proposal(ProposalId, Record))
               ;   true )).

finish_proposal(ProposalId, Sink) :-
    with_mutex(rlm_inline,
               (   retract(inline_proposal(ProposalId, Record0))
               ->  (   Record0.status == streaming
                   ->  put_dict(status, Record0, finished, Record)
                   ;   Record0 = Record
                   ),
                   assertz(inline_proposal(ProposalId, Record))
               ;   Record = none
               )),
    (   Record = none
    ->  true
    ;   get_dict(text, Record, Text),
        deliver(Sink, inline_event{type:proposal_finished,
                                   proposal_id:ProposalId,
                                   text:Text})
    ).

/* Accept / discard and batched lineage ------------------------------------- */

rlm_inline_accept(ProposalId, Outcome) :-
    resolve_proposal(ProposalId, accepted, Outcome),
    (   Outcome = ok(Resolved)
    ->  get_dict(text, Resolved, Text),
        record_lineage(ProposalId, accepted, _{text:Text})
    ;   true ).

rlm_inline_discard(ProposalId, Reason, Outcome) :-
    (   ground(Reason)
    ->  resolve_proposal(ProposalId, discarded, Outcome),
        (   Outcome = ok(_)
        ->  record_lineage(ProposalId, discarded, _{reason:Reason})
        ;   true )
    ;   Outcome = error(inline_error{phase:discard, kind:invalid_reason})
    ).

resolve_proposal(ProposalId, FinalState, Outcome) :-
    with_mutex(rlm_inline,
               (   retract(inline_proposal(ProposalId, Record))
               ->  (   Record.status == finished
                   ->  put_dict(status, Record, FinalState, Resolved),
                       assertz(inline_proposal(ProposalId, Resolved)),
                       Outcome = ok(Resolved)
                   ;   assertz(inline_proposal(ProposalId, Record)),
                       Outcome = error(inline_error{
                                           phase:resolve,
                                           kind:proposal_not_pending,
                                           state:Record.status})
                   )
               ;   Outcome = error(inline_error{phase:resolve,
                                               kind:unknown_proposal})
               )).

record_lineage(ProposalId, Event, Info) :-
    (   inline_proposal(ProposalId, Record)
    ->  get_dict(grant_id, Record, GrantId),
        with_mutex(rlm_inline,
                   assertz(inline_lineage_row(
                               GrantId,
                               row(ProposalId, Event, Info))))
    ;   true ).

rlm_inline_lineage(Grant, Rows) :-
    get_dict(id, Grant, GrantId),
    with_mutex(rlm_inline,
               findall(Row, inline_lineage_row(GrantId, Row), Rows)).
