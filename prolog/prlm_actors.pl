:- module(prlm_actors,
          [ prlm_actors_ready/0,
            prlm_actor_spawn/4,
            prlm_send/3,
            prlm_actor_step/3,
            prlm_actor_mail_len/3,
            prlm_actor_run/3,
            prlm_actor_cancel/2,
            prlm_actor_status/3,
            prlm_actor_state/3,
            prlm_actor_children/3,
            prlm_actor_checkpoint/3,
            prlm_actor_restore/4,
            prlm_agent_spawn/4,
            prlm_agent_ask/3,
            prlm_agent_result/3,
            prlm_actor_external_ask/5,
            prlm_agent_run_goal/5
          ]).

/** <module> prlm_actors — native actor runtime; agents built on actors only

Actors are part of the language runtime itself: identity, state, mailbox,
messages, supervision, lifecycle, capabilities, cancellation and child
actors are runtime primitives here — not library conveniences. Agents,
supervisors, MCP connections and worker processes are KINDS of actor, so
there is no separate agent architecture to drift out of sync.

Why this exists
===============

Prolog-RLM's symbolic-recursive mode needs supervised recursion (depth up
to the session's depth budget — 500 by default) with shared budgets,
authority narrowing and cancellation. Host threads cannot provide
deterministic semantics, so actors are message-driven and stepped by an
explicit deterministic scheduler: round-robin over FIFO mailboxes. Every
transition emits events on the one normalized session stream, so
OpenCode/Zara/MCP UIs observe exactly what the runtime does.

Rules enforced here (fail closed):

* Child authority is the narrowing (prlm_authority_child) of the parent's
  authority; a child can never hold more authority than its parent.
* Child capabilities must be a subset of the parent's capabilities.
* Depth budget is charged per nesting level; the default depth budget (500)
  bounds supervised recursion globally per session.
* A cancelled session token makes every step fail closed.

Agents are actors whose behavior invokes the prlm_agent_run_goal/5 hook
(replaced by the RLM layer in stage1); results flow back as structured
Prolog terms — agent_result{status, value, evidence, usage} — never as
prose.
*/

:- use_module(library(lists)).
:- use_module(prlm_session).
:- use_module(prlm_kernel).

prlm_actors_ready.

% ============================================================
% State
% ============================================================

:- dynamic actor_reg/2.          % actor_reg(Session, ActorDict)
:- dynamic actor_mail/3.         % actor_mail(Session, ActorId, Msgs)
:- dynamic agent_result/3.       % agent_result(Session, AgentId, Result)
:- dynamic actor_seq/2.          % actor_seq(Session, N)

canonical_kind(actor). canonical_kind(agent). canonical_kind(mcp).
canonical_kind(worker).

canonical_strategy(restart). canonical_strategy(stop). canonical_strategy(escalate).

prlm_actor_external_ask(_, _, _, _, _) :- fail.   % multifile hook (deferred adapters)
:- multifile prlm_actor_external_ask/5.
:- dynamic prlm_actor_external_ask/5.
prlm_agent_run_goal(_, _, _, _, _) :- fail.       % multifile hook (replaced by RLM layer)
:- multifile prlm_agent_run_goal/5.
:- dynamic prlm_agent_run_goal/5.

next_actor_id(Session, Id) :-
    (   retract(actor_seq(Session, N0)) -> true ; N0 = 0 ),
    N1 is N0 + 1,
    assertz(actor_seq(Session, N1)),
    atom_concat(actor_, N1, Id).

% ============================================================
% Spawn
% ============================================================

%! prlm_actor_spawn(+Session, +ParentIdOrNone, +ProfileIn, -ActorId) is det
%
% Spawn an actor. Profile = actor{name, behavior, state0, caps, authority,
% kind, strategy, max_depth(optional), goal(optional)}. Children narrow
% authority, must stay within parent capabilities and charge the shared
% depth budget.
prlm_actor_spawn(Session, ParentIdOrNone, Profile0, ActorId) :-
    prlm_check_cancelled(Session),
    normalize_profile(Profile0, Profile),
    next_actor_id(Session, ActorId),
    (   ParentIdOrNone == none
    ->  prlm_authority_current(Session, SessionTier),
        prlm_authority_child(SessionTier, Profile.authority, Auth),
        Depth = 1
    ;   actor_dict(Session, ParentIdOrNone, Parent),
        prlm_authority_child(Parent.authority, Profile.authority, Auth),
        (   caps_subset(Profile.caps, Parent.caps)
        ->  true
        ;   throw(prlm_error(forbidden, _{caps: Profile.caps, parent: ParentIdOrNone}))
        ),
        Depth is Parent.depth + 1
    ),
    prlm_budget_check(Session, depth, Depth),
    prlm_budget_charge(Session, depth, Depth),
    Dict = Profile.put(_{id: ActorId, session: Session, parent: ParentIdOrNone,
                         authority: Auth, depth: Depth,
                         restarts: 0, status: alive, state: Profile.state0}),
    assertz(actor_reg(Session, Dict)),
    assertz(actor_mail(Session, ActorId, [])),
    prlm_event_emit(Session, actor_spawn,
                    _{actor: ActorId, name: Profile.name, kind: Profile.kind,
                      parent: ParentIdOrNone, depth: Depth, authority: Auth}).

normalize_profile(Profile0, Profile) :-
    is_dict(Profile0),
    get_dict(name, Profile0, Name), atom(Name),
    get_dict(behavior, Profile0, Behavior), valid_behavior(Behavior),
    get_dict(kind, Profile0, Kind), canonical_kind(Kind),
    get_dict(strategy, Profile0, Strategy), canonical_strategy(Strategy),
    get_dict(caps, Profile0, Caps), proper_atom_list(Caps),
    get_dict(authority, Profile0, Authority),
    member(Authority, [approve_diff, allow_once, allow_session, dangerous]),
    (   get_dict(max_depth, Profile0, MD), integer(MD) -> true ; MD = 8 ),
    (   get_dict(state0, Profile0, State0) -> true ; State0 = none ),
    (   get_dict(goal, Profile0, Goal) -> true ; Goal = none ),
    Profile = Profile0.put(_{max_depth: MD, state0: State0, goal: Goal}),
    !.                              % deterministic: no backtrack re-entry
normalize_profile(Profile0, _) :-
    throw(prlm_error(type_error, _{actor_profile: Profile0})).

valid_behavior(lang(Module:Name/Arity)) :-
    atom(Module), atom(Name), Arity == 3, !.
valid_behavior(host(Module:Name/Arity)) :-
    atom(Module), atom(Name), Arity == 3, !.
valid_behavior(external(Adapter)) :-
    \+ var(Adapter), !.

proper_atom_list(L) :-
    is_list(L),
    forall(member(X, L), atom(X)).

caps_subset(Child, Parent) :-
    forall(member(C, Child), member(C, Parent)).

actor_dict(Session, ActorId, Dict) :-
    actor_reg(Session, Dict),
    get_dict(id, Dict, ActorId),
    !.

set_actor(Session, Dict) :-
    get_dict(id, Dict, Id),
    (   actor_dict(Session, Id, Old)
    ->  retract(actor_reg(Session, Old))
    ;   true
    ),
    assertz(actor_reg(Session, Dict)).

% ============================================================
% Mailboxes
% ============================================================

%! prlm_send(+Session, +To, +Msg) is det
prlm_send(Session, To, Msg) :-
    actor_dict(Session, To, Dict),
    get_dict(status, Dict, alive),
    !,
    retract(actor_mail(Session, To, Msgs)),
    append(Msgs, [Msg], Msgs2),
    assertz(actor_mail(Session, To, Msgs2)),
    prlm_event_emit(Session, actor_message, _{to: To, queued: true}).
prlm_send(Session, To, _) :-
    (   actor_dict(Session, To, Dict),
        get_dict(status, Dict, Status)
    ->  throw(prlm_error(existence_error, _{mailbox: To, status: Status}))
    ;   throw(prlm_error(existence_error, _{actor: To}))
    ).

prlm_actor_mail_len(Session, ActorId, N) :-
    (   actor_mail(Session, ActorId, Msgs) -> length(Msgs, N) ; N = 0 ).

% ============================================================
% Stepping
% ============================================================

%! prlm_actor_step(+Session, +ActorId, -Outcome) is det
%
% Process one message. Outcomes: stepped(Actions), restarted,
% failed(ErrorTag), escalated(ErrorTag).
prlm_actor_step(Session, ActorId, Outcome) :-
    prlm_check_cancelled(Session),
    actor_dict(Session, ActorId, Dict0),
    get_dict(status, Dict0, alive),
    actor_mail(Session, ActorId, [Msg|Rest]),
    retract(actor_mail(Session, ActorId, [Msg|Rest])),
    assertz(actor_mail(Session, ActorId, Rest)),
    (   catch(execute_behavior(Session, Dict0, Msg, NewState, Actions),
              Error,
              true)
    ->  (   var(Error)
        ->  apply_actions(Session, ActorId, Msg, NewState, Actions),
            actor_dict(Session, ActorId, Dict1),
            set_actor(Session, Dict1.put(state, NewState)),
            prlm_event_emit(Session, observation,
                            _{actor: ActorId, actions: Actions}),
            Outcome = stepped(Actions)
        ;   supervise(Session, ActorId, Dict0, Msg, Error, Outcome)
        )
    ;   % behavior failed without exception (deterministic failure)
        supervise(Session, ActorId, Dict0, Msg,
                  prlm_error(type_error, _{behavior_failed: ActorId}), Outcome)
    ).

execute_behavior(Session, Dict, Msg, NewState, Actions) :-
    get_dict(state, Dict, State),
    get_dict(behavior, Dict, Behavior),
    behavior_outcome(Session, Dict, Behavior, State, Msg, NewState, Actions).

behavior_outcome(Session, _Dict, lang(Module:Name/3), State, Msg, NewState, Actions) :-
    prlm_session_engine(Session, Engine),
    prlm_kernel:prlm_call_first(Engine, Module,
                                call(Name, State, Msg, Outcome0),
                                [o-Outcome0],
                                Result),
    get_dict(o, Result, Outcome1),
    outcome_split(Outcome1, NewState, Actions).
behavior_outcome(_Session, _Dict, host(Module:Name/3), State, Msg, NewState, Actions) :-
    call(Module:Name, State, Msg, Outcome0),
    outcome_split(Outcome0, NewState, Actions).
behavior_outcome(Session, _Dict, external(Adapter), State, Msg, State, [reply(Reply)]) :-
    prlm_actor_external_ask(Session, Adapter, State, Msg, Reply).

outcome_split(outcome(NewState, Actions), NewState, Actions) :- !.
outcome_split(NewState, NewState, []).

apply_actions(_, _, _, _, []) :- !.
apply_actions(Session, ActorId, Msg, NewState, [A|Rest]) :-
    apply_action(Session, ActorId, Msg, NewState, A),
    apply_actions(Session, ActorId, Msg, NewState, Rest).

apply_action(Session, _, _, _, send(To, M)) :-
    !,
    prlm_send(Session, To, M).
apply_action(Session, ActorId, _, _, spawn(Profile)) :-
    !,
    prlm_actor_spawn(Session, ActorId, Profile, _).
apply_action(Session, ActorId, _, _, stop) :-
    !,
    actor_dict(Session, ActorId, Dict),
    set_actor(Session, Dict.put(status, done)).
apply_action(Session, ActorId, Msg, _, reply(R)) :-
    !,
    % Replies route to the sender when the sender is a live actor; unknown
    % or external senders get an observation event instead of a crash.
    (   Msg = msg(From, _), atom(From), actor_dict(Session, From, Dict1),
        get_dict(status, Dict1, alive)
    ->  prlm_send(Session, From, R)
    ;   prlm_event_emit(Session, observation, _{actor: ActorId, reply: R})
    ).
apply_action(Session, ActorId, _, _, log(T)) :-
    !,
    prlm_event_emit(Session, observation, _{actor: ActorId, log: T}).

%! Supervision: restart | stop | escalate on behavior failure.
supervise(Session, ActorId, Dict, Msg, Error, Outcome) :-
    Strategy = Dict.strategy,
    error_tag(Error, Tag),
    (   Strategy == restart,
        Dict.restarts < 3
    ->  RestartN is Dict.restarts + 1,
        set_actor(Session, Dict.put(restarts, RestartN).put(state, Dict.state0)),
        retractall(actor_mail(Session, ActorId, _)),
        assertz(actor_mail(Session, ActorId, [Msg])),
        prlm_event_emit(Session, failure,
                        _{actor: ActorId, supervision: restart, error: Tag}),
        Outcome = restarted
    ;   Strategy == stop
    ->  set_actor(Session, Dict.put(status, failed)),
        prlm_event_emit(Session, failure,
                        _{actor: ActorId, supervision: stop, error: Tag}),
        Outcome = failed(Tag)
    ;   % escalate (also when the restart budget is exhausted)
        set_actor(Session, Dict.put(status, failed)),
        (   Dict.parent \== none
        ->  prlm_send(Session, Dict.parent, actor_failed(ActorId, Tag))
        ;   true
        ),
        prlm_event_emit(Session, failure,
                        _{actor: ActorId, supervision: escalate, error: Tag}),
        Outcome = escalated(Tag)
    ).

error_tag(Error, Tag) :-
    (   Error = prlm_error(Type, _) -> Tag = Type
    ;   Error = error(Type, _) -> Tag = Type
    ;   Tag = unknown
    ).

% ============================================================
% Deterministic round-robin scheduler
% ============================================================

%! prlm_actor_run(+Session, +MaxSteps, -Stats) is det
prlm_actor_run(Session, MaxSteps, Stats) :-
    prlm_actor_run_(Session, MaxSteps, 0, Stats).

prlm_actor_run_(Session, MaxSteps, Done0, Stats) :-
    prlm_check_cancelled(Session),
    Done0 < MaxSteps,
    runnable_ids(Session, Runnable),
    Runnable \== [],
    !,
    run_round(Session, Runnable),
    length(Runnable, N),
    Done1 is Done0 + N,
    prlm_actor_run_(Session, MaxSteps, Done1, Stats).
prlm_actor_run_(Session, _MaxSteps, Done, Stats) :-
    findall(Id,
            (   actor_reg(Session, D),
                get_dict(id, D, Id),
                get_dict(status, D, done)
            ),
            Stopped0),
    findall(Id,
            (   actor_reg(Session, D),
                get_dict(id, D, Id),
                get_dict(status, D, failed)
            ),
            Failed0),
    sort(Stopped0, Stopped),
    sort(Failed0, Failed),
    Stats = stats{processed: Done, stopped: Stopped, failed: Failed}.

runnable_ids(Session, Runnable) :-
    findall(Id,
            (   actor_reg(Session, D),
                get_dict(status, D, alive),
                get_dict(id, D, Id),
                actor_mail(Session, Id, [_|_])
            ),
            Runnable0),
    sort(Runnable0, Runnable).

run_round(_, []).
run_round(Session, [Id|Rest]) :-
    (   catch(prlm_actor_step(Session, Id, _), _, true)
    ->  true
    ;   true
    ),
    run_round(Session, Rest).

% ============================================================
% Cancellation (subtree)
% ============================================================

%! prlm_actor_cancel(+Session, +ActorId) is det
prlm_actor_cancel(Session, Root) :-
    subtree_ids(Session, Root, Sub),
    forall(member(Id, [Root|Sub]),
           (   actor_dict(Session, Id, Dict),
               set_actor(Session, Dict.put(status, cancelled)),
               retractall(actor_mail(Session, Id, _)),
               assertz(actor_mail(Session, Id, [])),
               prlm_event_emit(Session, cancellation, _{actor: Id})
           )).

subtree_ids(Session, Id, All) :-
    prlm_actor_children(Session, Id, Children),
    subtree_many(Session, Children, SubAll),
    append(Children, SubAll, All).

subtree_many(_, [], []).
subtree_many(Session, [C|Cs], All) :-
    subtree_ids(Session, C, Sub),
    subtree_many(Session, Cs, Rest),
    append(Sub, Rest, All).

%! prlm_actor_children(+Session, +ActorId, -ChildIds) is det
prlm_actor_children(Session, Parent, Children) :-
    findall(Child,
            (   actor_reg(Session, D),
                get_dict(parent, D, Parent),
                get_dict(id, D, Child)
            ),
            Children0),
    sort(Children0, Children).

%! prlm_actor_state(+Session, +ActorId, -State) is semidet
%
% Current state term of an actor (introspection for tests and tools).
prlm_actor_state(Session, ActorId, State) :-
    actor_dict(Session, ActorId, Dict),
    get_dict(state, Dict, State).

%! prlm_actor_status(+Session, +ActorId, -Status) is semidet
prlm_actor_status(Session, ActorId, Status) :-
    actor_dict(Session, ActorId, Dict),
    get_dict(status, Dict, Status).

% ============================================================
% Checkpoint / resume
% ============================================================

prlm_actor_checkpoint(Session, ActorId, Ckpt) :-
    actor_dict(Session, ActorId, Profile),
    actor_mail(Session, ActorId, Mailbox),
    get_dict(state, Profile, State),
    Ckpt = ckpt{profile: Profile, state: State, mailbox: Mailbox}.

prlm_actor_restore(Session, ParentIdOrNone, Ckpt, NewActorId) :-
    Ckpt = ckpt{profile: Profile0, state: State, mailbox: Mailbox},
    Stripped = actor{name: Profile0.name, behavior: Profile0.behavior,
                     state0: State, caps: Profile0.caps,
                     authority: Profile0.authority, kind: Profile0.kind,
                     strategy: Profile0.strategy},
    prlm_actor_spawn(Session, ParentIdOrNone, Stripped, NewActorId),
    retract(actor_mail(Session, NewActorId, _)),
    assertz(actor_mail(Session, NewActorId, Mailbox)).

% ============================================================
% Agents (actors with an RLM goal hook; structured results only)
% ============================================================

%! prlm_agent_spawn(+Session, +ParentAgentOrNone, +AgentSpec0, -AgentId) is det
%
% AgentSpec = agent{name, goal, mode, caps, authority, max_depth}.
prlm_agent_spawn(Session, Parent, AgentSpec0, AgentId) :-
    (   agent_spec_ok(AgentSpec0, Name, Goal, Mode, Caps, Authority, MD)
    ->  State0 = agent_state{agent: none, session: Session, goal: Goal,
                             mode: Mode, result: none},
        Profile = actor{name: Name,
                        behavior: host(prlm_actors:agent_behavior/3),
                        state0: State0, caps: Caps, authority: Authority,
                        kind: agent, strategy: escalate, max_depth: MD,
                        goal: Goal},
        prlm_actor_spawn(Session, Parent, Profile, AgentId),
        actor_dict(Session, AgentId, Dict),
        update_agent_state(Session, AgentId, Dict)
    ;   throw(prlm_error(type_error, _{agent_spec: AgentSpec0}))
    ).

agent_spec_ok(Spec, Name, Goal, Mode, Caps, Authority, MD) :-
    is_dict(Spec),
    get_dict(name, Spec, Name), atom(Name),
    get_dict(goal, Spec, Goal),
    (   get_dict(mode, Spec, Mode0) -> Mode0 = Mode ; Mode = auto ),
    member(Mode, [direct, symbolic, symbolic_recursive, auto]),
    (   get_dict(caps, Spec, Caps) -> true ; Caps = [] ),
    (   get_dict(authority, Spec, Authority) -> true ; Authority = approve_diff ),
    (   get_dict(max_depth, Spec, MD) -> true ; MD = 8 ),
    proper_atom_list(Caps).

update_agent_state(Session, AgentId, Dict) :-
    (   get_dict(state, Dict, S0) -> true ; S0 = none ),
    (   S0 = none
    ->  true
    ;   set_actor(Session, Dict.put(state, S0.put(agent, AgentId)))
    ).

%! prlm_agent_ask(+Session, +AgentId, -Result) is det
%
% Run the agent to completion and return its structured result.
prlm_agent_ask(Session, AgentId, Result) :-
    prlm_send(Session, AgentId, msg(supervisor, run)),
    pump_agent(Session, 10000),
    (   agent_result(Session, AgentId, Result)
    ->  true
    ;   Result = agent_result{status: error, value: no_result,
                              evidence: evidence{source: prlm_actors,
                                                 provenance: agent_ask},
                              usage: usage{steps: 0}}
    ).

pump_agent(Session, Budget) :-
    Budget > 0,
    runnable_ids(Session, Runnable),
    Runnable \== [],
    !,
    forall(member(Id, Runnable),
           (   catch(prlm_actor_step(Session, Id, _), _, true) )),
    Budget1 is Budget - 1,
    pump_agent(Session, Budget1).
pump_agent(_, _).

%! prlm_agent_result(+Session, +AgentId, -Result) is semidet
prlm_agent_result(Session, AgentId, Result) :-
    agent_result(Session, AgentId, Result).

% The generated agent behavior (host): runs the goal hook, records the
% structured result, replies to the requester, stops.
agent_behavior(State, msg(_From, run),
               outcome(NewState, [stop])) :-
    get_dict(agent, State, AgentId),
    atom(AgentId),
    !,
    get_dict(goal, State, Goal),
    get_dict(mode, State, Mode),
    get_dict(session, State, Session),
    (   prlm_agent_run_goal(Session, AgentId, Goal, Mode, Result)
    ->  true
    ;   Result = agent_result{status: ok, value: goal_done(Goal),
                              evidence: evidence{source: prolog_only,
                                                 provenance: prlm_actors},
                              usage: usage{steps: 1}}
    ),
    (   agent_result(Session, AgentId, _)
    ->  true
    ;   assertz(agent_result(Session, AgentId, Result))
    ),
    NewState = State.put(result, Result).
agent_behavior(State, Msg, outcome(State, [log(unexpected_message(Msg))])).
