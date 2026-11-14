:- begin_tests(rlm_expert_tool).
:- use_module('../prolog/rlm_expert_tool').
:- use_module('../prolog/rlm_expert').
:- use_module('../prolog/rlm_tool').

contract(Handler, Requires, C) :-
    C = expert_contract{id:echo,version:1,accepts:[echo/1],produces:value,
        specialties:[test],requires:Requires,observations:[],effects:[],
        fallback:none,child_policy:never,limits:expert_limits{},handler:Handler}.
echo(echo(X), _, succeeded(X,[fixture])).
loop(_, _, _) :- repeat, fail.
cancel(_, _, _) :- throw(error(rlm_cancelled(test_token), fixture)).
setup(Handler, Requires, E, T) :-
    expert_registry_create([], E), tool_registry_create(T),
    contract(Handler, Requires, C), expert_register(E,C,ok(_)).
cleanup(E,T) :- expert_registry_destroy(E), tool_registry_destroy(T).
project(E,T,Limits,O) :- expert_tool_register(T,E,echo,
    expert_tool{name:echo_tool,goal:echo/1,description:"Echo expert",limits:Limits},O).
invoke(T,Caps,Args,O) :- tool_invoke_execute(T,Caps,echo_tool,Args,[],R), O=R.outcome.
args(X, expert_args{arguments:[X]}).

test(invoke_preserves_evidence_and_usage, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    project(E,T,limits{},ok(_)), args(hello,A),
    invoke(T,[tool(echo_tool)],A,ok(R)),
    assertion(R.value.result == hello), assertion(R.value.evidence == [fixture]),
    assertion(R.value.usage.model_calls == 0), assertion(R.value.expert_id == echo).

test(registration_does_not_grant_capability, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    project(E,T,limits{},ok(_)), args(hello,A), invoke(T,[],A,error(Error)),
    assertion(Error.kind == capability_denied), expert_invocations(E,[]).

test(required_capability_is_checked, [setup(setup(plunit_rlm_expert_tool:echo,[context(search)],E,T)),cleanup(cleanup(E,T))]) :-
    project(E,T,limits{},ok(_)), args(hello,A),
    invoke(T,[tool(echo_tool)],A,error(Error)), assertion(Error.kind == capability_denied),
    expert_invocations(E,[]),
    invoke(T,[tool(echo_tool),context(search)],A,ok(_)).

test(catalog_hides_handler, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    project(E,T,limits{},ok(_)), tool_discover(T,[Schema]),
    assertion(\+ get_dict(handler,Schema,_)),
    tool_registry_runtime_tools(T,[tool(echo_tool)],[_]).

test(stale_projection_fails_closed, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    project(E,T,limits{},ok(_)), expert_unregister(E,echo,ok(_)), args(hello,A),
    invoke(T,[tool(echo_tool)],A,error(_)), expert_invocations(E,[]).

test(model_context_cannot_be_supplied, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    project(E,T,limits{},ok(_)),
    invoke(T,[tool(echo_tool)],expert_args{arguments:[hello],capabilities:[context(search)]},error(_)),
    expert_invocations(E,[]).

test(inference_budget, [setup(setup(plunit_rlm_expert_tool:loop,[],E,T)),cleanup(cleanup(E,T))]) :-
    project(E,T,limits{inferences:1000},ok(_)), args(hello,A),
    invoke(T,[tool(echo_tool)],A,error(Error)), assertion(Error.kind == handler_exception).

test(cancellation_propagates, [setup(setup(plunit_rlm_expert_tool:cancel,[],E,T)),cleanup(cleanup(E,T)),throws(error(rlm_cancelled(test_token),fixture))]) :-
    project(E,T,limits{},ok(_)), args(hello,A), invoke(T,[tool(echo_tool)],A,_).

test(output_budget, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    project(E,T,limits{max_output_bytes:1},ok(_)), args(hello,A), invoke(T,[tool(echo_tool)],A,error(_)).

test(unknown_goal_not_projected, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    expert_tool_register(T,E,echo,expert_tool{name:nope,goal:call/1,description:"No"},error(_)),
    tool_discover(T,[]).

test(plan_tool_adapter_executes_same_expert, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    project(E,T,limits{},ok(_)), args(hello,A),
    tool_registry_runtime_tools(T,[tool(echo_tool)],[tool(echo_tool,Handler)]),
    call(Handler,A,Envelope), assertion(Envelope.value.result == hello),
    assertion(Envelope.value.usage.model_calls == 0).

test(wrong_arity_rejected, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    project(E,T,limits{},ok(_)), invoke(T,[tool(echo_tool)],expert_args{arguments:[]},error(_)),
    expert_invocations(E,[]).

test(replacement_cannot_reuse_projection, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    project(E,T,limits{},ok(_)), expert_unregister(E,echo,ok(_)),
    contract(plunit_rlm_expert_tool:cancel,[],C), expert_register(E,C,ok(_)),
    args(hello,A), invoke(T,[tool(echo_tool)],A,error(_)), expert_invocations(E,[]).

test(effectful_contract_rejected, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    expert_unregister(E,echo,ok(_)), contract(plunit_rlm_expert_tool:echo,[],C0),
    put_dict(effects,C0,[write],C), expert_register(E,C,ok(_)),
    project(E,T,limits{},error(_)), tool_discover(T,[]).

test(fallback_contract_rejected, [setup(setup(plunit_rlm_expert_tool:echo,[],E,T)),cleanup(cleanup(E,T))]) :-
    expert_unregister(E,echo,ok(_)), contract(plunit_rlm_expert_tool:echo,[],C0),
    put_dict(fallback,C0,semantic_generation_fallback,C), expert_register(E,C,ok(_)),
    project(E,T,limits{},error(_)), tool_discover(T,[]).

wait_handler(echo(Queue), _, succeeded(done,[])) :- thread_get_message(Queue,_).
test(wall_time_limit, [setup(setup(plunit_rlm_expert_tool:wait_handler,[],E,T)),cleanup(cleanup(E,T))]) :-
    message_queue_create(Q),
    setup_call_cleanup(true,
       ( project(E,T,limits{time_limit:0.01},ok(_)), args(Q,A),
         invoke(T,[tool(echo_tool)],A,error(Error)), assertion(Error.kind == timeout) ),
       message_queue_destroy(Q)).

:- end_tests(rlm_expert_tool).
