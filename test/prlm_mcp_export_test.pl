:- use_module(library(plunit)).
:- use_module('../prolog/prlm_kernel.pl').
:- use_module('../prolog/prlm_session.pl').
:- use_module('../prolog/prlm_tools.pl').
:- use_module('../prolog/prlm_mcp_export.pl').

:- begin_tests(prlm_mcp_export).

% ============================================================
% Helpers
% ============================================================

sess_new(S) :-
    prlm_session_new([], S).

sess_destroy(S) :-
    catch(prlm_session_destroy(S), _, true).

throws_prlm(Goal, Type, Check) :-
    catch(( call(Goal)
          -> throw(unexpected_success(Goal))
          ;  throw(unexpected_failure(Goal))
          ),
          prlm_error(Type, Info),
          call(Check, Info)).

chk_directive(D, Info) :- get_dict(directive, Info, D).
chk_indicator(Ind, Info) :- get_dict(mcp_export, Info, Ind).

event_data(Session, Type, Data) :-
    prlm_events(Session, -1, Events),
    member(E, Events),
    get_dict(type, E, Type),
    get_dict(data, E, Data),
    !.

% Exported predicate with the companion <name>_schema/1 convention.
demo_source(
":- module(mcp_demo, [double/2, double_schema/1]).
:- mcp_export(double/2).
double(X, Y) :- Y is X * 2.
double_schema(schema([arg(x, integer)])).
").

% No companion: positional fallback arg1..argN typed string.
plain_source(
":- module(mcp_plain, [triple/2]).
:- mcp_export(triple/2).
triple(X, Y) :- Y is X * 3.
").

% Only exported predicates surface, even when a private one is declared.
priv_source(
":- module(mcp_priv, [pub/1]).
:- mcp_export(pub/1).
:- mcp_export(priv/1).
pub(ok_pub).
priv(ok_priv).
").

% Declared but exported through the public API instead of the directive.
declare_source(
":- module(mcp_decl, [inc/2]).
inc(X, Y) :- Y is X + 1.
").

% ============================================================
% EXPORT: surface generation
% ============================================================

test(surface_with_companion_schema) :-
    prlm_engine_new(E),
    demo_source(Src),
    prlm_consult_source(E, mcp_demo, Src, demo_src),
    prlm_mcp_surface(E, [Tool]),
    Tool = mcp_tool{name: prlm_mcp_demo_double_2,
                    description: Desc,
                    inputSchema: mcp_schema{type: object,
                                            properties: [property{name: x,
                                                                  type: integer}],
                                            required: [x]},
                    source: source{module: mcp_demo,
                                   predicate: double/2,
                                   engine: E}},
    atom(Desc),
    prlm_engine_destroy(E).

test(surface_falls_back_without_companion) :-
    prlm_engine_new(E),
    plain_source(Src),
    prlm_consult_source(E, mcp_plain, Src, plain_src),
    prlm_mcp_surface(E, [Tool]),
    Tool = mcp_tool{name: prlm_mcp_plain_triple_2,
                    description: _,
                    inputSchema: mcp_schema{type: object,
                                            properties: [property{name: arg1,
                                                                  type: string}],
                                            required: [arg1]},
                    source: source{module: mcp_plain,
                                   predicate: triple/2,
                                   engine: E}},
    prlm_engine_destroy(E).

test(surface_only_exports_declared_and_exported) :-
    prlm_engine_new(E),
    priv_source(Src),
    prlm_consult_source(E, mcp_priv, Src, priv_src),
    prlm_mcp_surface(E, [Tool]),
    Tool = mcp_tool{name: prlm_mcp_priv_pub_1,
                    description: _,
                    inputSchema: mcp_schema{type: object,
                                            properties: [],
                                            required: []},
                    source: source{module: mcp_priv,
                                   predicate: pub/1,
                                   engine: E}},
    prlm_engine_destroy(E).

test(declare_public_api_and_reject_bad_indicator) :-
    prlm_engine_new(E),
    declare_source(Src),
    prlm_consult_source(E, mcp_decl, Src, decl_src),
    prlm_mcp_export_declare(E, mcp_decl, inc/2),
    prlm_mcp_surface(E, [Tool]),
    get_dict(name, Tool, prlm_mcp_decl_inc_2),
    % re-declare is a no-op, not a duplicate
    prlm_mcp_export_declare(E, mcp_decl, inc/2),
    prlm_mcp_surface(E, [Tool]),
    throws_prlm(prlm_mcp_export_declare(E, mcp_decl, inc),
                type_error,
                chk_indicator(inc)),
    prlm_engine_destroy(E).

% ============================================================
% EXPORT: registration and gated execution through the engine
% ============================================================

test(register_tools_and_execute_engine_predicate) :-
    sess_new(S),
    prlm_engine_new(E),
    demo_source(Src),
    prlm_consult_source(E, mcp_demo, Src, demo_src),
    prlm_mcp_register_tools(S, E, Registered),
    Registered == [prlm_mcp_demo_double_2],
    prlm_tool_discover(S, [Tool]),
    get_dict(name, Tool, prlm_mcp_demo_double_2),
    get_dict(capability, Tool, []),
    get_dict(authority, Tool, approve_diff),
    get_dict(effects, Tool, [read]),
    get_dict(args_schema, Tool, [arg(x, integer)]),
    get_dict(handler, Tool, host(prlm_mcp_export:H)),
    atom(H),
    sub_atom(H, 0, _, _, 'tool_'),
    prlm_tool_call(S, [], prlm_mcp_demo_double_2, _{x: 21}, Result),
    get_dict(status, Result, ok),
    get_dict(value, Result, 42),
    Evidence = Result.evidence,
    atom_concat('host:prlm_mcp_export:', H, Evidence.provenance),
    sess_destroy(S),
    prlm_engine_destroy(E).

test(register_twice_yields_distinct_wrappers) :-
    sess_new(S),
    prlm_engine_new(E),
    demo_source(Src),
    prlm_consult_source(E, mcp_demo, Src, demo_src),
    prlm_mcp_register_tools(S, E, R1),
    throws_prlm(prlm_mcp_register_tools(S, E, _R2),
                type_error,
                chk_duplicate(prlm_mcp_demo_double_2)),
    Registered = R1,
    Registered == [prlm_mcp_demo_double_2],
    sess_destroy(S),
    prlm_engine_destroy(E).

chk_duplicate(Name, Info) :- get_dict(duplicate, Info, Name).

% Engine-side failure and a zero-arity export: a failing engine predicate
% stays a tool result error (never escapes); an arity-0 export takes no
% input and binds the result argument directly.
fail_source(
":- module(mcp_fail, [nada/1, zero/0]).
:- mcp_export(nada/1).
:- mcp_export(zero/0).
nada(N) :- integer(N), N < 0.
zero(1).
").

test(engine_failure_is_error_result) :-
    sess_new(S),
    prlm_engine_new(E),
    fail_source(Src),
    prlm_consult_source(E, mcp_fail, Src, fail_src),
    prlm_mcp_register_tools(S, E, [prlm_mcp_fail_nada_1, prlm_mcp_fail_zero_0]),
    prlm_tool_call(S, [], prlm_mcp_fail_nada_1, _{}, R),
    get_dict(status, R, error),
    get_dict(value, R, handler_failed),
    event_data(S, failure, FData),
    get_dict(tool, FData, prlm_mcp_fail_nada_1),
    get_dict(status, FData, error),
    sess_destroy(S),
    prlm_engine_destroy(E).

test(arity_zero_export_binds_result_directly) :-
    sess_new(S),
    prlm_engine_new(E),
    fail_source(Src),
    prlm_consult_source(E, mcp_fail, Src, fail_src),
    prlm_mcp_register_tools(S, E, _),
    prlm_tool_call(S, [], prlm_mcp_fail_zero_0, _{}, R),
    get_dict(status, R, ok),
    get_dict(value, R, 1),
    sess_destroy(S),
    prlm_engine_destroy(E).

% ============================================================
% CONSUME: external descriptors -> session tools -> transport
% ============================================================

external_tools([_{name: "ext_tool",
                  description: "External double",
                  inputSchema: _{type: "object",
                                 properties: _{a: _{type: "string"},
                                               b: _{type: "number"}},
                                 required: ["a"]}},
                _{name: "ext2",
                  description: "No schema tool",
                  inputSchema: _{}}
               ]).

test(consume_registers_external_descriptors) :-
    sess_new(S),
    external_tools(JSON),
    prlm_mcp_consume(S, mathsrv, JSON, Count),
    Count == 2,
    prlm_tool_discover(S, [T1, T2]),
    get_dict(name, T1, ext2),
    get_dict(name, T2, ext_tool),
    get_dict(args_schema, T2, [arg(a, string), arg(b, number)]),
    get_dict(effects, T2, [external]),
    get_dict(authority, T2, approve_diff),
    get_dict(handler, T2, mcp(mathsrv, ext_tool)),
    get_dict(args_schema, T1, []),
    sess_destroy(S).

test(consume_transport_canned_value_and_external_effects_event) :-
    sess_new(S),
    external_tools(JSON),
    prlm_mcp_consume(S, mathsrv, JSON, _),
    prlm_mcp_set_transport(S, mathsrv, ext_tool, 42),
    prlm_tool_call(S, [], ext_tool, _{a: "hi", b: 1}, Result),
    get_dict(status, Result, ok),
    get_dict(value, Result, 42),
    Evidence = Result.evidence,
    Evidence.provenance == 'mcp:mathsrv',
    event_data(S, tool_call, Data),
    get_dict(tool, Data, ext_tool),
    get_dict(effects, Data, [external]),
    sess_destroy(S).

test(consume_without_transport_fails_closed) :-
    sess_new(S),
    external_tools(JSON),
    prlm_mcp_consume(S, mathsrv, JSON, _),
    prlm_tool_call(S, [], ext2, _{}, Result),
    get_dict(status, Result, error),
    get_dict(value, Result, handler_failed),
    event_data(S, failure, FData),
    get_dict(tool, FData, ext2),
    get_dict(status, FData, error),
    sess_destroy(S).

test(transport_arg_dependent_and_clear) :-
    sess_new(S),
    external_tools(JSON),
    prlm_mcp_consume(S, mathsrv, JSON, _),
    % a host-asserted arg-dependent adapter clause
    assertz(prlm_mcp_export:prlm_mcp_transport(S, mathsrv, ext_tool,
                                               Args, Echo) :-
                get_dict(a, Args, Echo)),
    prlm_tool_call(S, [], ext_tool, _{a: "ping", b: 0}, R1),
    get_dict(status, R1, ok),
    get_dict(value, R1, "ping"),
    prlm_mcp_clear_transport(S),
    prlm_tool_call(S, [], ext_tool, _{a: "ping", b: 0}, R2),
    get_dict(status, R2, error),
    sess_destroy(S).

% ============================================================
% Directive hook: fail closed on invalid shapes
% ============================================================

test(directive_hook_rejects_non_indicator) :-
    prlm_engine_new(E),
    throws_prlm(prlm_consult_source(E, mcp_bad,
                                    ":- module(mcp_bad, []).\n:- mcp_export(bad).\n",
                                    bad_src),
                directive_error,
                chk_directive(mcp_export(bad))),
    prlm_engine_destroy(E).

test(directive_hook_ignores_other_directives) :-
    % an unrelated unknown directive must still be rejected (the hook only
    % accepts mcp_export/1 shapes)
    prlm_engine_new(E),
    throws_prlm(prlm_consult_source(E, other,
                                    ":- module(other, []).\n:- mystery_directive(1).\n",
                                    o_src),
                directive_error,
                chk_directive(mystery_directive(1))),
    prlm_engine_destroy(E).

:- end_tests(prlm_mcp_export).
