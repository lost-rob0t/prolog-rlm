:- use_module(library(plunit)).
:- use_module('../prolog/prlm_session.pl').
:- use_module('../prolog/prlm_tools.pl').

% Wire a test MCP hook clause to exercise the deferred mcp handler path.
:- multifile prlm_tools:prlm_mcp_invoke/5.
:- dynamic prlm_tools:prlm_mcp_invoke/5.

prlm_tools:prlm_mcp_invoke(_Session, mathsrv, dbl, Args, Value) :-
    get_dict(x, Args, X),
    Value is X * 2.

:- begin_tests(prlm_tools).

% ============================================================
% Helpers
% ============================================================

sess_new(S) :-
    prlm_session_new([authority(allow_session)], S).

sess_destroy(S) :-
    catch(prlm_session_destroy(S), _, true).

throws_prlm(Goal, Type, Check) :-
    catch(( call(Goal)
          -> throw(unexpected_success(Goal))
          ;  throw(unexpected_failure(Goal))
          ),
          prlm_error(Type, Info),
          call(Check, Info)).

chk_dict(Info) :- is_dict(Info).
chk_reason(Reason, Info) :- get_dict(reason, Info, Reason).
chk_arg(Arg, Info) :- get_dict(arg, Info, Arg).
chk_expected(Expected, Info) :- get_dict(expected, Info, Expected).
chk_missing(Missing, Info) :- get_dict(missing, Info, Missing).
chk_duplicate(Name, Info) :- get_dict(duplicate, Info, Name).
chk_authority(Tier, Info) :- get_dict(authority, Info, Tier).
chk_key(Key, Value, Info) :- get_dict(Key, Info, Value).
chk_and(C1, C2, Info) :- call(C1, Info), call(C2, Info).

event_data(Session, Type, Data) :-
    prlm_events(Session, -1, Events),
    member(E, Events),
    get_dict(type, E, Type),
    get_dict(data, E, Data),
    !.

tool_names(Session, Names) :-
    prlm_tool_discover(Session, Tools),
    map_list_to_pairs(tn, Tools, Tagged),
    pairs_keys(Tagged, Names).

tn(T, N) :- get_dict(name, T, N).

% A probe tool with configurable name/authority/caps and an identity
% host handler (module-private in prlm_tools, callable via M:Name/2).
probe_tool(Name, Authority, Caps,
           tool{name: Name,
                description: 'probe',
                args_schema: [arg(x, integer)],
                capability: Caps,
                authority: Authority,
                effects: [read],
                result_schema: integer,
                handler: host(prlm_tools:prlm_default_identity)}).

% ============================================================
% Readiness
% ============================================================

test(tools_ready, [true]) :-
    prlm_tools_ready.

% ============================================================
% Registration validation
% ============================================================

test(register_valid) :-
    sess_new(S),
    probe_tool(probe1, allow_session, [cap1], G),
    prlm_tool_register(S, G, T),
    get_dict(name, T, probe1),
    get_dict(capability, T, [cap1]),
    get_dict(authority, T, allow_session),
    get_dict(effects, T, [read]),
    get_dict(result_schema, T, integer),
    get_dict(handler, T, host(prlm_tools:prlm_default_identity)),
    sess_destroy(S).

test(register_rejects_invalid_fields) :-
    sess_new(S),
    probe_tool(probe1, allow_session, [], G0),
    dict_create(NoDesc, tool,
                [name-probe2,
                 args_schema-[arg(x, integer)],
                 capability-[],
                 authority-allow_session,
                 effects-[read],
                 result_schema-integer,
                 handler-host(prlm_tools:prlm_default_identity)]),
    Bad = [G0.put(_{name: 42}),
           G0.put(_{name: ''}),
           G0.put(_{description: 42}),
           G0.put(_{args_schema: arg(x, integer)}),
           G0.put(_{args_schema: [arg(x, bogus_type)]}),
           G0.put(_{args_schema: [not_arg(x)]}),
           G0.put(_{args_schema: [arg(x, integer), arg(x, integer)]}),
           G0.put(_{capability: [cap, 1]}),
           G0.put(_{capability: secret}),
           G0.put(_{authority: admin}),
           G0.put(_{effects: [teleport]}),
           G0.put(_{effects: read}),
           G0.put(_{result_schema: banana}),
           G0.put(_{handler: host(prlm_tools:42)}),
           G0.put(_{handler: host(42)}),
           G0.put(_{handler: lang(demotools:addv/3)}),
           G0.put(_{handler: lang(demotools:addv)}),
           G0.put(_{handler: mcp(srv, 7)}),
           G0.put(_{handler: bogus(x)}),
           G0.put(_{extra_key: 1}),
           NoDesc],
    forall(member(B, Bad),
           throws_prlm(prlm_tool_register(S, B, _),
                       type_error, chk_dict)),
    throws_prlm(prlm_tool_register(S, not_a_dict, _),
                type_error, chk_dict),
    sess_destroy(S).

test(register_rejects_duplicate) :-
    sess_new(S),
    probe_tool(dup1, allow_session, [], G),
    prlm_tool_register(S, G, _),
    throws_prlm(prlm_tool_register(S, G, _),
                type_error, chk_duplicate(dup1)),
    sess_destroy(S).

test(register_emits_nothing) :-
    sess_new(S),
    probe_tool(silent, allow_session, [], G),
    prlm_tool_register(S, G, _),
    prlm_events(S, -1, Es),
    \+ (member(E, Es), get_dict(type, E, tool_call)),
    \+ (member(E, Es), get_dict(type, E, observation)),
    \+ (member(E, Es), get_dict(type, E, failure)),
    sess_destroy(S).

% ============================================================
% Discovery
% ============================================================

test(discover_deterministic_order) :-
    sess_new(S),
    probe_tool(zz, allow_session, [], G1),
    probe_tool(aa, allow_session, [], G2),
    probe_tool(mm, allow_session, [], G3),
    prlm_tool_register(S, G1, _),
    prlm_tool_register(S, G2, _),
    prlm_tool_register(S, G3, _),
    tool_names(S, [aa, mm, zz]),
    tool_names(S, [aa, mm, zz]),
    sess_destroy(S).

test(default_pack_discover_order) :-
    sess_new(S),
    prlm_tools_default(S),
    tool_names(S, [add, clock, echo, fail_always, kv_get, kv_put]),
    sess_destroy(S).

% ============================================================
% Happy path (host handler, evidence, events)
% ============================================================

test(tool_call_happy_path) :-
    sess_new(S),
    prlm_tools_default(S),
    prlm_tool_call(S, [], echo, args{input: hello}, R),
    get_dict(status, R, ok),
    get_dict(value, R, hello),
    get_dict(evidence, R, Ev),
    get_dict(tool, Ev, echo),
    get_dict(args, Ev, EvArgs),
    get_dict(input, EvArgs, hello),
    get_dict(time, Ev, Time),
    assertion(float(Time)),
    get_dict(provenance, Ev, Prov),
    assertion(atom(Prov)),
    assertion(sub_atom(Prov, 0, 5, _, 'host:')),
    get_dict(duration_ms, Ev, Dur),
    assertion(integer(Dur)),
    assertion(Dur >= 0),
    event_data(S, tool_call, D1),
    get_dict(tool, D1, echo),
    get_dict(args, D1, CArgs),
    get_dict(input, CArgs, hello),
    get_dict(effects, D1, [read]),
    event_data(S, observation, D2),
    get_dict(tool, D2, echo),
    get_dict(status, D2, ok),
    get_dict(duration_ms, D2, Dur),
    sess_destroy(S).

test(default_pack_ops) :-
    sess_new(S),
    prlm_tools_default(S),
    prlm_tool_call(S, [], kv_put, args{key: k1, value: v1}, R1),
    get_dict(status, R1, ok),
    get_dict(value, R1, v1),
    prlm_session_get(S, k1, v1),
    prlm_tool_call(S, [], kv_get, args{key: k1}, R2),
    get_dict(status, R2, ok),
    get_dict(value, R2, v1),
    prlm_tool_call(S, [], add, args{a: 2, b: 3}, R3),
    get_dict(status, R3, ok),
    get_dict(value, R3, 5),
    prlm_tool_call(S, [], clock, args{}, R4),
    get_dict(status, R4, ok),
    get_dict(value, R4, Clock),
    assertion(float(Clock)),
    sess_destroy(S).

% ============================================================
% Argument validation
% ============================================================

test(arg_validation_missing_extra_wrong) :-
    sess_new(S),
    prlm_tools_default(S),
    probe_tool(inttool, allow_session, [], G),
    prlm_tool_register(S, G, _),
    throws_prlm(prlm_tool_call(S, [], echo, args{}, _),
                type_error, chk_and(chk_arg(input), chk_expected(term))),
    throws_prlm(prlm_tool_call(S, [], echo, args{input: x, bogus: 1}, _),
                type_error, chk_and(chk_arg(bogus), chk_expected(none))),
    throws_prlm(prlm_tool_call(S, [], inttool, args{x: foo}, _),
                type_error, chk_and(chk_arg(x), chk_expected(integer))),
    throws_prlm(prlm_tool_call(S, [], echo, notadict, _),
                type_error, chk_and(chk_arg('-'), chk_expected(dict))),
    throws_prlm(prlm_tool_call(S, [], no_such_tool, args{}, _),
                existence_error, chk_key(tool, no_such_tool)),
    sess_destroy(S).

test(integer_coercion) :-
    sess_new(S),
    probe_tool(intid, allow_session, [], G),
    prlm_tool_register(S, G, _),
    prlm_tool_call(S, [], intid, args{x: 3.0}, R),
    get_dict(status, R, ok),
    get_dict(value, R, V),
    assertion(integer(V)),
    assertion(V == 3),
    throws_prlm(prlm_tool_call(S, [], intid, args{x: 3.5}, _),
                type_error, chk_arg(x)),
    sess_destroy(S).

% ============================================================
% Capability gate
% ============================================================

test(capability_gate_denial) :-
    sess_new(S),
    probe_tool(capped, allow_session, [secret], G),
    prlm_tool_register(S, G, _),
    throws_prlm(prlm_tool_call(S, [], capped, args{x: 1}, _),
                forbidden,
                chk_and(chk_key(tool, capped), chk_missing([secret]))),
    event_data(S, failure, D),
    get_dict(tool, D, capped),
    get_dict(reason, D, forbidden_caps),
    get_dict(missing, D, [secret]),
    prlm_tool_call(S, [secret, other], capped, args{x: 5}, R),
    get_dict(status, R, ok),
    sess_destroy(S).

% ============================================================
% Authority gate
% ============================================================

test(authority_gate_denial) :-
    sess_new(S),
    probe_tool(dang, dangerous, [], G),
    prlm_tool_register(S, G, _),
    throws_prlm(prlm_tool_call(S, [], dang, args{x: 1}, _),
                forbidden,
                chk_and(chk_key(tool, dang), chk_authority(dangerous))),
    sess_destroy(S).

test(authority_allow_once_consumption) :-
    prlm_session_new([authority(allow_once)], S),
    probe_tool(once_t, allow_once, [], G),
    prlm_tool_register(S, G, _),
    prlm_tool_call(S, [], once_t, args{x: 1}, R1),
    get_dict(status, R1, ok),
    throws_prlm(prlm_tool_call(S, [], once_t, args{x: 2}, _),
                forbidden, chk_authority(allow_once)),
    sess_destroy(S).

test(authority_not_consumed_on_caps_denial) :-
    prlm_session_new([authority(allow_once)], S),
    probe_tool(once_c, allow_once, [secret], G),
    prlm_tool_register(S, G, _),
    throws_prlm(prlm_tool_call(S, [], once_c, args{x: 1}, _),
                forbidden, chk_missing([secret])),
    prlm_tool_call(S, [secret], once_c, args{x: 1}, R),
    get_dict(status, R, ok),
    throws_prlm(prlm_tool_call(S, [secret], once_c, args{x: 2}, _),
                forbidden, chk_authority(allow_once)),
    sess_destroy(S).

% ============================================================
% Budget gate
% ============================================================

test(budget_exceeded_second_call) :-
    prlm_session_new([authority(allow_session),
                      budgets(_{steps: 100, tool_calls: 1,
                                depth: 10, repairs: 3})],
                     S),
    prlm_tools_default(S),
    prlm_tool_call(S, [], echo, args{input: a}, R1),
    get_dict(status, R1, ok),
    throws_prlm(prlm_tool_call(S, [], echo, args{input: b}, _),
                budget_exceeded, chk_key(kind, tool_calls)),
    event_data(S, budget, D),
    get_dict(kind, D, tool_calls),
    sess_destroy(S).

% ============================================================
% Error result paths (handler fail / exception, no rethrow)
% ============================================================

test(handler_fail_error_path) :-
    sess_new(S),
    prlm_tools_default(S),
    prlm_tool_call(S, [], fail_always, args{}, R),
    get_dict(status, R, error),
    get_dict(value, R, handler_failed),
    get_dict(evidence, R, Ev),
    get_dict(provenance, Ev, 'host:prlm_tools:prlm_fail_always'),
    event_data(S, failure, D),
    get_dict(tool, D, fail_always),
    event_data(S, observation, D2),
    get_dict(tool, D2, fail_always),
    get_dict(status, D2, error),
    sess_destroy(S).

test(handler_exception_error_path) :-
    sess_new(S),
    probe_tool(boomer, allow_session, [], G),
    G1 = G.put(_{handler: host(prlm_tools:prlm_default_boom)}),
    prlm_tool_register(S, G1, _),
    prlm_tool_call(S, [], boomer, args{x: 1}, R),
    get_dict(status, R, error),
    get_dict(value, R, error(bang, prlm_tools)),
    event_data(S, failure, D),
    get_dict(tool, D, boomer),
    get_dict(error, D, error(bang, prlm_tools)),
    sess_destroy(S).

% ============================================================
% Effects superset check
% ============================================================

test(effects_superset_check) :-
    sess_new(S),
    probe_tool(rwtool, allow_session, [], G),
    G1 = G.put(_{effects: [read, write]}),
    prlm_tool_register(S, G1, _),
    prlm_tool_check_effects(S, rwtool, [read, write]),
    prlm_tool_check_effects(S, rwtool, [write]),
    prlm_tool_check_effects(S, rwtool, []),
    \+ prlm_tool_check_effects(S, rwtool, [write, net]),
    prlm_tools_default(S),
    prlm_tool_check_effects(S, kv_put, [write]),
    \+ prlm_tool_check_effects(S, no_such_tool, [read]),
    sess_destroy(S).

% ============================================================
% Projections
% ============================================================

test(projection_roundtrip) :-
    sess_new(S),
    prlm_tools_default(S),
    prlm_tool_to_predicate(S, add, CP),
    CP = prlm_tools:prlm_projection(S, add, A, V),
    A = args{a: 20, b: 22},
    call(CP),
    V == 42,
    \+ call(prlm_tools:prlm_projection(S, fail_always, args{}, _)),
    throws_prlm(prlm_tool_to_predicate(S, nope, _),
                existence_error, chk_key(tool, nope)),
    sess_destroy(S).

test(predicate_to_tool_lang) :-
    sess_new(S),
    Src = ":- module(demotools, [addv/2]).\naddv(args([nv(a,X),nv(b,Y)]), R) :- R is X + Y.\n",
    prlm_session_engine(S, E),
    prlm_kernel:prlm_consult_source(E, demotools, Src, '<prlm_tools_test>'),
    Meta = tool{name: addv,
                description: 'Engine add.',
                args_schema: [arg(a, integer), arg(b, integer)],
                capability: [],
                authority: allow_session,
                effects: [read],
                result_schema: integer},
    prlm_predicate_to_tool(S, demotools, addv/2, Meta, T),
    get_dict(handler, T, lang(demotools:addv/2)),
    get_dict(name, T, addv),
    prlm_tool_call(S, [], addv, args{a: 2, b: 40}, R),
    get_dict(status, R, ok),
    get_dict(value, R, 42),
    get_dict(evidence, R, Ev),
    get_dict(provenance, Ev, 'lang:demotools:addv/2'),
    event_data(S, tool_call, D),
    get_dict(tool, D, addv),
    sess_destroy(S).

test(predicate_to_tool_validation) :-
    sess_new(S),
    Src = ":- module(demotools, [addv/2]).\naddv(args([nv(a,X),nv(b,Y)]), R) :- R is X + Y.\n",
    prlm_session_engine(S, E),
    prlm_kernel:prlm_consult_source(E, demotools, Src, '<prlm_tools_test>'),
    Meta = tool{name: addv,
                description: 'Engine add.',
                args_schema: [arg(a, integer), arg(b, integer)],
                capability: [],
                authority: allow_session,
                effects: [read],
                result_schema: integer},
    throws_prlm(prlm_predicate_to_tool(S, demotools, nope/2, Meta, _),
                existence_error,
                chk_key(engine_predicate, demotools:nope/2)),
    throws_prlm(prlm_predicate_to_tool(S, demotools, addv/3, Meta, _),
                type_error,
                chk_reason(engine_predicate_must_be_arity_2)),
    MetaBad = Meta.put(_{handler: lang(demotools:addv/2)}),
    throws_prlm(prlm_predicate_to_tool(S, demotools, addv/2, MetaBad, _),
                type_error, chk_reason(bad_keys)),
    sess_destroy(S).

% ============================================================
% Cancellation
% ============================================================

test(cancellation_gate_first_step) :-
    sess_new(S),
    prlm_tools_default(S),
    prlm_session_token(S, Tok),
    prlm_cancel(Tok),
    prlm_cancelled(Tok),
    throws_prlm(prlm_tool_call(S, [], echo, args{input: x}, _),
                cancellation, chk_key(token, Tok)),
    throws_prlm(prlm_tool_call(S, [], no_such_tool, args{}, _),
                cancellation, chk_key(token, Tok)),
    sess_destroy(S).

% ============================================================
% Deferred handlers (mcp / actor)
% ============================================================

test(mcp_hook_wiring) :-
    sess_new(S),
    probe_tool(dbl, allow_session, [], G),
    G1 = G.put(_{handler: mcp(mathsrv, dbl)}),
    prlm_tool_register(S, G1, _),
    prlm_tool_call(S, [], dbl, args{x: 21}, R),
    get_dict(status, R, ok),
    get_dict(value, R, 42),
    get_dict(evidence, R, Ev),
    get_dict(provenance, Ev, 'mcp:mathsrv'),
    sess_destroy(S).

test(mcp_default_hook_fails) :-
    sess_new(S),
    probe_tool(ghost, allow_session, [], G),
    G1 = G.put(_{handler: mcp(ghostsrv, ghost)}),
    prlm_tool_register(S, G1, _),
    prlm_tool_call(S, [], ghost, args{x: 1}, R),
    get_dict(status, R, error),
    get_dict(value, R, handler_failed),
    event_data(S, failure, D),
    get_dict(tool, D, ghost),
    sess_destroy(S).

test(actor_default_hook_fails) :-
    sess_new(S),
    probe_tool(act, allow_session, [], G),
    G1 = G.put(_{handler: actor(worker1)}),
    prlm_tool_register(S, G1, _),
    prlm_tool_call(S, [], act, args{x: 1}, R),
    get_dict(status, R, error),
    get_dict(value, R, handler_failed),
    get_dict(evidence, R, Ev),
    get_dict(provenance, Ev, 'actor:worker1'),
    sess_destroy(S).

:- end_tests(prlm_tools).
