:- use_module('../prolog/prlm_actors').
:- use_module('../prolog/prlm_session').
:- use_module('../prolog/prlm_kernel').

% ============================================================
% Support behaviors (loaded into user; referenced as user:Name/3)
% ============================================================

sup_host_behavior(_State, _Msg, outcome(counted, [])).
sup_flaky_behavior(State, _, outcome(NewState, [])) :-
    (   State == boom -> fail ; NewState = boom ).
sup_counter_behavior(State, _, outcome(NewState, [])) :-
    (   var(State) -> NewState = 1
    ;   State == none -> NewState = 1
    ;   NewState is State + 1
    ).
sup_collector(State, Msg, outcome(NewState, [])) :-
    (   Msg = actor_failed(Id, _)
    ->  NewState = [failed(Id)|State]
    ;   NewState = [Msg|State]
    ).

:- begin_tests(prlm_actors).

fresh_session(Session) :-
    prlm_session_new([budgets(_{steps: 500000, tool_calls: 100,
                                depth: 500, repairs: 3}),
                      authority(allow_session), provider(prolog)], Session).

spawn_simple(Session, Behavior, Authority, Caps, Id) :-
    prlm_actor_spawn(Session, none,
                     actor{name: n, kind: actor, strategy: stop,
                           behavior: Behavior, caps: Caps, authority: Authority},
                     Id).

echo_engine(Session) :-
    prlm_session_engine(Session, Engine),
    prlm_kernel:prlm_consult_source(Engine, demoactor,
        ":- module(demoactor, [echo3/3]).\necho3(State, Msg, outcome(NewState, [reply(got(Msg))])) :- NewState = [Msg|State].",
        dtest).

% ============================================================
% Lang behavior: step, state, reply routing
% ============================================================

test(lang_behavior_step_reply_and_state) :-
    fresh_session(Session),
    echo_engine(Session),
    prlm_actor_spawn(Session, none,
                     actor{name: echoer, kind: actor, strategy: restart,
                           behavior: lang(demoactor:echo3/3),
                           caps: [], authority: approve_diff}, A),
    % a real sender actor so the reply has somewhere to go
    spawn_simple(Session, host(user:sup_host_behavior/3), approve_diff, [], Sender),
    prlm_send(Session, A, msg(Sender, ping)),
    prlm_actor_mail_len(Session, A, 1),
    prlm_actor_step(Session, A, stepped(Actions)),
    Actions == [reply(got(msg(Sender, ping)))],
    % the reply was routed back to the sender
    prlm_actor_mail_len(Session, Sender, 1),
    % the actor's state accumulated the message
    prlm_actor_state(Session, A, State),
    memberchk(msg(Sender, ping), State),
    prlm_session_destroy(Session).

test(reply_to_unknown_sender_is_observation_not_crash) :-
    fresh_session(Session),
    echo_engine(Session),
    prlm_actor_spawn(Session, none,
                     actor{name: echoer, kind: actor, strategy: restart,
                           behavior: lang(demoactor:echo3/3),
                           caps: [], authority: approve_diff}, A),
    prlm_send(Session, A, msg(nobody, ping)),
    prlm_actor_step(Session, A, stepped(_Actions)),
    prlm_actor_status(Session, A, alive),
    prlm_session_destroy(Session).

test(host_behavior) :-
    fresh_session(Session),
    spawn_simple(Session, host(user:sup_host_behavior/3), approve_diff, [], A),
    prlm_send(Session, A, anything),
    prlm_actor_step(Session, A, stepped([])),
    prlm_actor_status(Session, A, alive),
    prlm_session_destroy(Session).

% ============================================================
% Validation
% ============================================================

test(spawn_rejects_bad_kind) :-
    fresh_session(Session),
    catch(prlm_actor_spawn(Session, none,
                           actor{name: x, kind: alien, strategy: restart,
                                 behavior: host(user:sup_host_behavior/3),
                                 caps: [], authority: approve_diff}, _),
          prlm_error(type_error, _),
          true),
    prlm_session_destroy(Session).

test(spawn_rejects_bad_strategy) :-
    fresh_session(Session),
    catch(prlm_actor_spawn(Session, none,
                           actor{name: x, kind: actor, strategy: yolo,
                                 behavior: host(user:sup_host_behavior/3),
                                 caps: [], authority: approve_diff}, _),
          prlm_error(type_error, _),
          true),
    prlm_session_destroy(Session).

% ============================================================
% Authority and capability narrowing
% ============================================================

test(child_authority_never_widens) :-
    fresh_session(Session),
    prlm_actor_spawn(Session, none,
                     actor{name: sup, kind: actor, strategy: stop,
                           behavior: host(user:sup_host_behavior/3),
                           caps: [read], authority: allow_session}, Parent),
    prlm_actor_spawn(Session, Parent,
                     actor{name: kid, kind: actor, strategy: stop,
                           behavior: host(user:sup_host_behavior/3),
                           caps: [read], authority: dangerous}, Child),
    prlm_actors:actor_dict(Session, Child, Dict),
    get_dict(authority, Dict, allow_session),
    prlm_session_destroy(Session).

test(child_caps_violation_rejected) :-
    fresh_session(Session),
    prlm_actor_spawn(Session, none,
                     actor{name: sup, kind: actor, strategy: stop,
                           behavior: host(user:sup_host_behavior/3),
                           caps: [read], authority: allow_session}, Parent),
    catch(prlm_actor_spawn(Session, Parent,
                           actor{name: kid, kind: actor, strategy: stop,
                                 behavior: host(user:sup_host_behavior/3),
                                 caps: [read, write], authority: allow_session}, _),
          prlm_error(forbidden, _),
          true),
    prlm_session_destroy(Session).

% ============================================================
% Depth budget
% ============================================================

test(depth_budget_enforced) :-
    prlm_session_new([budgets(_{steps: 100000, tool_calls: 10,
                                depth: 6, repairs: 3})], Session),
    spawn_simple(Session, host(user:sup_host_behavior/3), approve_diff, [], A1),
    prlm_actor_spawn(Session, A1,
                     actor{name: b, kind: actor, strategy: stop,
                           behavior: host(user:sup_host_behavior/3),
                           caps: [], authority: approve_diff}, A2),
    prlm_actor_spawn(Session, A2,
                     actor{name: c, kind: actor, strategy: stop,
                           behavior: host(user:sup_host_behavior/3),
                           caps: [], authority: approve_diff}, A3),
    % 1 + 2 + 3 = 6 depth charges exceed the budget of 5
    catch(prlm_actor_spawn(Session, A3,
                           actor{name: d, kind: actor, strategy: stop,
                                 behavior: host(user:sup_host_behavior/3),
                                 caps: [], authority: approve_diff}, _),
          prlm_error(budget_exceeded, _),
          true),
    prlm_session_destroy(Session).

% ============================================================
% Supervision
% ============================================================

test(supervision_restart_then_success) :-
    fresh_session(Session),
    prlm_actor_spawn(Session, none,
                     actor{name: flaky, kind: actor, strategy: restart,
                           behavior: host(user:sup_flaky_behavior/3),
                           caps: [], authority: approve_diff}, A),
    % first message succeeds and arms the bomb (state := boom)
    prlm_send(Session, A, m1),
    prlm_actor_step(Session, A, stepped(_)),
    % second message hits the bomb: failure triggers a supervised restart
    prlm_send(Session, A, m2),
    prlm_actor_step(Session, A, restarted),
    % after restart the state is reset, so processing succeeds again
    prlm_actor_step(Session, A, stepped(_)),
    prlm_actor_status(Session, A, alive),
    prlm_session_destroy(Session).

test(supervision_stop_on_failure) :-
    fresh_session(Session),
    prlm_actor_spawn(Session, none,
                     actor{name: flaky, kind: actor, strategy: stop,
                           behavior: host(user:sup_flaky_behavior/3),
                           caps: [], authority: approve_diff}, A),
    prlm_send(Session, A, m1),
    prlm_actor_step(Session, A, stepped(_)),
    prlm_send(Session, A, m2),
    prlm_actor_step(Session, A, failed(_)),
    prlm_actor_status(Session, A, failed),
    prlm_session_destroy(Session).

test(supervision_escalate_notifies_parent) :-
    fresh_session(Session),
    prlm_actor_spawn(Session, none,
                     actor{name: sup, kind: actor, strategy: stop,
                           behavior: host(user:sup_collector/3),
                           caps: [], authority: allow_session}, Parent),
    prlm_actor_spawn(Session, Parent,
                     actor{name: kid, kind: actor, strategy: escalate,
                           behavior: host(user:sup_flaky_behavior/3),
                           caps: [], authority: allow_session}, Kid),
    prlm_send(Session, Kid, m1),
    prlm_actor_step(Session, Kid, stepped(_)),
    prlm_send(Session, Kid, m2),
    prlm_actor_step(Session, Kid, escalated(_)),
    prlm_actor_status(Session, Kid, failed),
    prlm_actor_mail_len(Session, Parent, 1),
    prlm_actor_step(Session, Parent, stepped(_)),
    prlm_session_destroy(Session).

% ============================================================
% Round-robin run
% ============================================================

test(run_round_robin_processes_mailboxes) :-
    fresh_session(Session),
    spawn_simple(Session, host(user:sup_counter_behavior/3), approve_diff, [], A1),
    spawn_simple(Session, host(user:sup_counter_behavior/3), approve_diff, [], A2),
    prlm_send(Session, A1, x),
    prlm_send(Session, A2, x),
    prlm_actor_run(Session, 100, Stats),
    get_dict(processed, Stats, 2),
    prlm_actor_mail_len(Session, A1, 0),
    prlm_actor_mail_len(Session, A2, 0),
    prlm_session_destroy(Session).

% ============================================================
% Cancellation
% ============================================================

test(cancel_cancels_subtree) :-
    fresh_session(Session),
    spawn_simple(Session, host(user:sup_counter_behavior/3), approve_diff, [], Root),
    prlm_actor_spawn(Session, Root,
                     actor{name: mid, kind: actor, strategy: stop,
                           behavior: host(user:sup_counter_behavior/3),
                           caps: [], authority: approve_diff}, Mid),
    prlm_actor_spawn(Session, Mid,
                     actor{name: leaf, kind: actor, strategy: stop,
                           behavior: host(user:sup_counter_behavior/3),
                           caps: [], authority: approve_diff}, Leaf),
    prlm_actor_cancel(Session, Root),
    prlm_actor_status(Session, Root, cancelled),
    prlm_actor_status(Session, Mid, cancelled),
    prlm_actor_status(Session, Leaf, cancelled),
    prlm_session_destroy(Session).

test(cancelled_session_blocks_step) :-
    fresh_session(Session),
    spawn_simple(Session, host(user:sup_counter_behavior/3), approve_diff, [], A),
    prlm_send(Session, A, m),
    prlm_cancel(Session),
    catch(prlm_actor_step(Session, A, _),
          prlm_error(cancellation, _),
          true),
    prlm_session_destroy(Session).

% ============================================================
% Checkpoint / restore
% ============================================================

test(checkpoint_restore_roundtrip) :-
    fresh_session(Session),
    prlm_session_engine(Session, Engine),
    prlm_kernel:prlm_consult_source(Engine, demoactor2,
        ":- module(demoactor2, [echo2/3]).\necho2(State, Msg, outcome(NewState, [])) :- NewState = [Msg|State].",
        dtest2),
    prlm_actor_spawn(Session, none,
                     actor{name: echoer, kind: actor, strategy: restart,
                           behavior: lang(demoactor2:echo2/3),
                           caps: [], authority: approve_diff}, A),
    prlm_send(Session, A, one),
    prlm_actor_step(Session, A, _),
    prlm_send(Session, A, pending),
    prlm_actor_checkpoint(Session, A, Ckpt),
    prlm_actor_restore(Session, none, Ckpt, B),
    prlm_actor_status(Session, B, alive),
    prlm_actor_mail_len(Session, B, 1),
    prlm_actor_state(Session, B, State),
    memberchk(one, State),
    prlm_session_destroy(Session).

% ============================================================
% Agents
% ============================================================

test(agent_default_result_without_model) :-
    fresh_session(Session),
    prlm_agent_spawn(Session, none,
                     agent{name: worker, goal: summarize_context,
                           mode: symbolic}, AgentId),
    prlm_agent_ask(Session, AgentId, Result),
    get_dict(status, Result, ok),
    get_dict(value, Result, goal_done(summarize_context)),
    get_dict(usage, Result, Usage),
    get_dict(steps, Usage, 1),
    prlm_session_destroy(Session).

test(agent_hook_replaces_default) :-
    fresh_session(Session),
    assertz(prlm_actors:prlm_agent_run_goal(Session, A0, Goal, _Mode,
                                            agent_result{status: ok,
                                                         value: custom(Goal, A0),
                                                         evidence: evidence{source: test,
                                                                            provenance: hook},
                                                         usage: usage{steps: 7}})),
    prlm_agent_spawn(Session, none,
                     agent{name: hooked, goal: compute_thing, mode: auto}, AgentId),
    prlm_agent_ask(Session, AgentId, Result),
    get_dict(value, Result, custom(compute_thing, AgentId)),
    get_dict(usage, Result, Usage),
    get_dict(steps, Usage, 7),
    retractall(prlm_actors:prlm_agent_run_goal(Session, _, _, _, _)),
    prlm_session_destroy(Session).

test(agent_child_narrowing) :-
    fresh_session(Session),
    prlm_agent_spawn(Session, none,
                     agent{name: supervisor, goal: top, mode: symbolic,
                           caps: [read], authority: allow_session}, Sup),
    prlm_agent_spawn(Session, Sup,
                     agent{name: sub, goal: sub_task, mode: symbolic,
                           caps: [read], authority: dangerous}, Sub),
    prlm_actors:actor_dict(Session, Sub, Dict),
    get_dict(authority, Dict, allow_session),
    prlm_session_destroy(Session).

% ============================================================
% External (mcp/worker) actors
% ============================================================

test(external_actor_with_hook) :-
    fresh_session(Session),
    assertz(prlm_actors:prlm_actor_external_ask(Session, mcp(zara), _State, _Msg,
                                                replied)),
    prlm_actor_spawn(Session, none,
                     actor{name: zbridge, kind: mcp, strategy: stop,
                           behavior: external(mcp(zara)),
                           caps: [], authority: approve_diff}, A),
    prlm_send(Session, A, ask(me)),
    prlm_actor_step(Session, A, stepped(Actions)),
    memberchk(reply(replied), Actions),
    retractall(prlm_actors:prlm_actor_external_ask(Session, _, _, _, _)),
    prlm_session_destroy(Session).

:- end_tests(prlm_actors).
