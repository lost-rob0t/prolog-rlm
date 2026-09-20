:- begin_tests(rlm_expert).
:- use_module('../prolog/rlm_expert').
:- use_module('../prolog/rlm_tool').

contract(Id, Priority, Contract) :-
    Contract = expert_contract{id:Id, version:1, goal:review,
        priority:Priority,
        description:"Fixture deterministic expert", arguments:_{type:string},
        result:_{type:string},
        limits:_{time_limit:1.0, max_output_bytes:1024, inferences:10000}}.
echo(X, X).
spin(_, _) :- spin(_, _).

test(select_and_invoke, [setup(tool_registry_create(R)), cleanup(tool_registry_destroy(R))]) :-
    contract(review_one, 10, C),
    expert_register(R, C, plunit_rlm_expert:echo, ok(_)),
    Context = _{capabilities:[tool(review_one)], observations:[source]},
    expert_select(R, review, Context, ok(Decision)),
    assertion(Decision.selected == review_one),
    expert_invoke(R, review_one, "source", Context, [], ok(Value), _),
    assertion(Value.value == "source").

test(missing_capability, [setup(tool_registry_create(R)), cleanup(tool_registry_destroy(R))]) :-
    contract(review_one, 10, C),
    expert_register(R, C, plunit_rlm_expert:echo, ok(_)),
    expert_select(R, review, _{capabilities:[], observations:[source]}, error(E)),
    assertion(E.kind == no_applicable_expert),
    expert_invoke(R, review_one, "source", _{capabilities:[], observations:[source]}, [], error(_), _).

test(ambiguous, [setup(tool_registry_create(R)), cleanup(tool_registry_destroy(R))]) :-
    contract(a, 10, A), contract(b, 10, B),
    expert_register(R, A, plunit_rlm_expert:echo, ok(_)),
    expert_register(R, B, plunit_rlm_expert:echo, ok(_)),
    expert_select(R, review, _{capabilities:[tool(a),tool(b)], observations:[source]}, error(E)),
    assertion(E.kind == ambiguous_expert).

test(native_excluded, [setup(tool_registry_create(R)), cleanup(tool_registry_destroy(R))]) :-
    contract(a, 10, C),
    expert_register(R, C.put(goal,run), plunit_rlm_expert:echo, error(_)),
    expert_catalog(R, []).

test(inference_bound, [setup(tool_registry_create(R)), cleanup(tool_registry_destroy(R))]) :-
    contract(a, 10, C),
    expert_register(R, C, plunit_rlm_expert:spin, ok(_)),
    expert_invoke(R, a, "source", _{capabilities:[tool(a)], observations:[source]}, [], error(_), _).

test(catalog_hides_handler, [setup(tool_registry_create(R)), cleanup(tool_registry_destroy(R))]) :-
    contract(a, 10, C),
    expert_register(R, C, plunit_rlm_expert:echo, ok(_)),
    expert_catalog(R, [Public]),
    assertion(\+ get_dict(handler, Public, _)),
    tool_registry_destroy(R),
    expert_catalog(R, []).

test(raw_tool_projection_uses_same_handler,
     [setup(tool_registry_create(R)), cleanup(tool_registry_destroy(R))]) :-
    contract(a,10,C), expert_register(R,C,plunit_rlm_expert:echo,ok(_)),
    tool_invoke(R,[tool(a)],a,"direct",[],ok(V),_),
    assertion(V.value == "direct"),
    expert_invoke_execute(R,a,"direct",_{capabilities:[tool(a)]},[],Executed),
    assertion(Executed.outcome = ok(_)),
    tool_registry_runtime_tools(R,[tool(a)],Bindings),
    assertion(Bindings = [tool(a,_) ]).

test(reject_unsupported_contract,
     [setup(tool_registry_create(R)), cleanup(tool_registry_destroy(R))]) :-
    contract(a,10,C),
    expert_register(R,C.put(fallback,model),plunit_rlm_expert:echo,error(_)),
    expert_catalog(R,[]).

test(priority_and_schema,
     [setup(tool_registry_create(R)), cleanup(tool_registry_destroy(R))]) :-
    contract(a,10,A),contract(b,20,B),
    expert_register(R,A,plunit_rlm_expert:echo,ok(_)),
    expert_register(R,B,plunit_rlm_expert:echo,ok(_)),
    expert_select(R,review,_{capabilities:[tool(a),tool(b)]},ok(D)),
    assertion(D.selected == b),
    expert_invoke(R,b,42,_{capabilities:[tool(b)]},[],error(_),_).
:- end_tests(rlm_expert).
