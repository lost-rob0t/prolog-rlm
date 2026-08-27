:- use_module('../../prolog/rlm_delegation_runtime').

:- dynamic delegation_resume_calls/1.

unknown_command_records([
    prompt(short_unknown, "Need evidence."),
    prompt_trigger(short_unknown, unknown),
    prompt_action(short_unknown, delegate_subagent)
]).

reset_delegation_resume_probe :-
    retractall(delegation_resume_calls(_)),
    assertz(delegation_resume_calls(0)).

resume_probe(Input, ok(Result)) :-
    retract(delegation_resume_calls(Count0)),
    Count is Count0+1,
    assertz(delegation_resume_calls(Count)),
    Child = Input.child_result,
    Result = resumed{value:Child.value,
                     prompt_id:Input.prompt_id,
                     delegation:Input.delegation}.

resume_probe_must_not_run(_, _) :-
    retract(delegation_resume_calls(Count0)),
    Count is Count0+1,
    assertz(delegation_resume_calls(Count)),
    assertion(fail).

test(unresolved_binding_delegates_and_resumes_parent_once,
     [setup(reset_delegation_resume_probe)]) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    ChildCaps = [rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps), max_agents(3)], Runtime),
    setup_call_cleanup(
        agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
        ( skill_role_records(Records),
          CompletionOptions = [
              planner_handler(completion_test_support:direct_planner),
              capabilities(ChildCaps),
              child_capabilities(ChildCaps),
              disabled_skills(['rlm-operate',
                               'rlm-recurse',
                               'rlm-constraints'])
          ],
          rlm_delegation_runtime:delegation_resume(
              Records,
              unknown,
              Runtime,
              Parent,
              ChildCaps,
              text("bounded evidence"),
              CompletionOptions,
              [],
              plunit_rlm_prompt_command:resume_probe,
              ok(Result)),
          assertion(Result.command.trigger == unknown),
          Envelope = Result.child_result,
          assertion(Envelope.status == completed),
          assertion(Envelope.value == "direct-ok"),
          assertion(Envelope.delegation.role == reviewer),
          assertion(Envelope.delegation.skills == ['rlm-facts']),
          assertion(Result.continuation.value == "direct-ok"),
          assertion(Result.continuation.prompt_id == short_unknown),
          assertion(Result.resume_input.child_result == Envelope),
          delegation_resume_calls(Calls),
          assertion(Calls =:= 1),
          Child = Envelope.correlation.child,
          agent_status(Runtime, Child, ok(ChildStatus)),
          assertion(ChildStatus.capabilities == ChildCaps)
        ),
        agent_runtime_destroy(Runtime)).

test(parent_capability_denial_never_resumes,
     [setup(reset_delegation_resume_probe)]) :-
    ParentCaps = [rlm, model(openrouter)],
    ChildCaps = [rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(ParentCaps), max_agents(3)], Runtime),
    setup_call_cleanup(
        agent_spawn(Runtime,
                    none,
                    agent_spec(parent),
                    ParentCaps,
                    ok(Parent)),
        ( unknown_command_records(Records),
          CompletionOptions = [
              planner_handler(completion_test_support:direct_planner),
              capabilities(ChildCaps),
              child_capabilities(ChildCaps)
          ],
          rlm_delegation_runtime:delegation_resume(
              Records,
              unknown,
              Runtime,
              Parent,
              ChildCaps,
              text("bounded evidence"),
              CompletionOptions,
              [],
              plunit_rlm_prompt_command:resume_probe_must_not_run,
              error(Error)),
          assertion(Error.kind == capability_denied),
          delegation_resume_calls(Calls),
          assertion(Calls =:= 0)
        ),
        agent_runtime_destroy(Runtime)).

test(failed_child_result_never_resumes_as_success,
     [setup((reset_delegation_resume_probe,
             completion_test_support:reset_calls))]) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    ChildCaps = [rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps), max_agents(3)], Runtime),
    setup_call_cleanup(
        agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
        ( unknown_command_records(Records),
          CompletionOptions = [
              planner_handler(completion_test_support:invalid_planner),
              planner_attempts(1),
              capabilities(ChildCaps),
              child_capabilities(ChildCaps)
          ],
          rlm_delegation_runtime:delegation_resume(
              Records,
              unknown,
              Runtime,
              Parent,
              ChildCaps,
              text("bounded evidence"),
              CompletionOptions,
              [],
              plunit_rlm_prompt_command:resume_probe_must_not_run,
              error(Error)),
          assertion(Error.kind == child_failed),
          assertion(Error.child_result.status == failed),
          delegation_resume_calls(Calls),
          assertion(Calls =:= 0)
        ),
        agent_runtime_destroy(Runtime)).

test(missing_unresolved_binding_never_spawns_or_resumes,
     [setup(reset_delegation_resume_probe)]) :-
    Caps = [tool(rlm_subagent), rlm, model(openrouter)],
    ChildCaps = [rlm, model(openrouter)],
    agent_runtime_create([root_capabilities(Caps), max_agents(3)], Runtime),
    setup_call_cleanup(
        agent_spawn(Runtime, none, agent_spec(parent), Caps, ok(Parent)),
        ( rlm_delegation_runtime:delegation_resume(
              [prompt(other, "Other")],
              unknown,
              Runtime,
              Parent,
              ChildCaps,
              text("bounded evidence"),
              [ planner_handler(completion_test_support:direct_planner),
                capabilities(ChildCaps),
                child_capabilities(ChildCaps)
              ],
              [],
              plunit_rlm_prompt_command:resume_probe_must_not_run,
              error(Error)),
          assertion(Error.kind == missing_binding),
          delegation_resume_calls(Calls),
          assertion(Calls =:= 0),
          agent_trace(Runtime, Trace),
          findall(Child,
                  ( member(Event, Trace),
                    is_dict(Event),
                    get_dict(event, Event, spawned),
                    get_dict(parent, Event, Parent),
                    get_dict(agent, Event, Child)
                  ),
                  Children),
          assertion(Children == [])
        ),
        agent_runtime_destroy(Runtime)).
