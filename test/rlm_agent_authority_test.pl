:- begin_tests(rlm_agent_authority).

:- use_module('../prolog/rlm_agent').
:- use_module('../prolog/rlm_authority').

test(runtime_defaults_to_approve_diff) :-
    setup_call_cleanup(
        agent_runtime_create([], Runtime),
        ( agent_runtime_status(Runtime, Status),
          assertion(Status.authority == approve_diff) ),
        agent_runtime_destroy(Runtime)).

test(child_authority_can_only_narrow) :-
    setup_call_cleanup(
        agent_runtime_create([authority(dangerous)], Runtime),
        ( agent_spawn(Runtime,
                      none,
                      _{name:parent, authority:allow_session},
                      [],
                      ok(Parent)),
          agent_status(Runtime, Parent, ok(ParentStatus)),
          assertion(ParentStatus.authority == allow_session),
          agent_spawn(Runtime,
                      Parent,
                      _{name:child, authority:approve_diff},
                      [],
                      ok(Child)),
          agent_status(Runtime, Child, ok(ChildStatus)),
          assertion(ChildStatus.authority == approve_diff) ),
        agent_runtime_destroy(Runtime)).

test(child_authority_widening_fails_closed) :-
    setup_call_cleanup(
        agent_runtime_create([], Runtime),
        ( agent_spawn(Runtime,
                      none,
                      _{name:bad_child, authority:dangerous},
                      [],
                      error(Error)),
          assertion(Error.kind == authority_widening_denied),
          agent_runtime_status(Runtime, Status),
          assertion(Status.agent_count =:= 0) ),
        agent_runtime_destroy(Runtime)).

test(model_facing_agent_tool_cannot_raise_authority) :-
    setup_call_cleanup(
        agent_runtime_create([], Runtime),
        ( Request = _{spec:_{name:model_child, authority:dangerous},
                      capabilities:[]},
          catch(agent_tool_handler(Runtime, none, Request, _),
                Exception,
                true),
          assertion(nonvar(Exception)),
          Exception = error(agent_spawn_failed(Error), _),
          assertion(Error.kind == authority_widening_denied),
          agent_runtime_status(Runtime, Status),
          assertion(Status.agent_count =:= 0) ),
        agent_runtime_destroy(Runtime)).

test(runtime_teardown_clears_session_authority_state) :-
    agent_runtime_create([authority(dangerous)], Runtime),
    Runtime = agent_runtime(Id),
    rlm_authority(runtime(Id), dangerous),
    agent_runtime_destroy(Runtime),
    rlm_authority(runtime(Id), Reset),
    assertion(Reset == approve_diff).

test(yolo_is_rejected_at_runtime_boundary) :-
    catch(agent_runtime_create([authority(yolo)], _), Exception, true),
    assertion(nonvar(Exception)).

:- end_tests(rlm_agent_authority).
