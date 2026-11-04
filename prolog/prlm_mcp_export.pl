:- module(prlm_mcp_export,
          [ prlm_mcp_export_ready/0,
            prlm_mcp_export_declare/3,
            prlm_mcp_exported/3,
            prlm_mcp_surface/2,
            prlm_mcp_register_tools/3,
            prlm_mcp_consume/4,
            prlm_mcp_set_transport/4,
            prlm_mcp_clear_transport/1
          ]).

/** <module> prlm_mcp_export — the language generates its MCP interface FROM ITSELF

Two directions over one contract:

EXPORT (engine predicates -> MCP tool descriptors -> session tools)
====================================================================

A .prlm source declares what it wants to expose with a load directive:

    :- module(demo, [double/2, double_schema/1]).
    :- mcp_export(double/2).
    double(X, Y) :- Y is X * 2.
    double_schema(schema([arg(x, integer)])).

The kernel offers every unknown directive to its multifile hook
prlm_kernel:prlm_load_directive/3; a clause asserted here accepts exactly
the mcp_export/1 shapes whose argument is a name/arity indicator and records
mcp_exported(Engine, Module, Name/Arity). Any other directive shape falls
through (the clause fails), so the kernel throws its directive_error — fail
closed at load time.

Schema convention (why: the language describes its own tools; no LLM and no
external schema source is involved). For an exported predicate Name/Arity
the last argument is the result; the Arity-1 leading arguments are the tool
input. Argument names and types come from a *companion predicate*
`<name>_schema/1` defined in the same engine module and returning
`schema([arg(Name,Type),...])` with exactly Arity-1 entries, where Type is
one of the prlm_tools argument types (atom, number, integer, string, list,
term, dict). When the companion is absent or malformed the surface falls
back to positional keys arg1..argN typed `string`. Unknown companion types
are sanitized to `string` so registration can never throw on a bad type.

prlm_mcp_surface/2 intersects the recorded declarations with the module's
actual exports (prlm_module_exports/3) and yields descriptor dicts:

    mcp_tool{name: prlm_<module>_<name>_<arity>,
             description: atom,
             inputSchema: mcp_schema{type: object,
                                     properties: [property{name,type},...],
                                     required: [Name,...]},
             source: source{module, predicate, engine}}

prlm_mcp_register_tools/3 registers each descriptor in prlm_tools for a
session with `handler: host(prlm_mcp_export:tool_<N>)`, where tool_<N>/2 is
a UNIQUE dynamically asserted wrapper (globally increasing N) trampolining
to the engine through prlm_kernel:prlm_call_first/5: the ArgsDict values are
laid onto the predicate's leading arguments in schema order, a fresh
variable is appended as the result argument, and the projected value is
returned. Registered tools carry capability [], authority approve_diff,
effects [read] — declarative availability only; capability possession is
still enforced by the gates at call time.

CONSUME (external MCP server descriptors -> session tools)
===========================================================

prlm_mcp_consume/4 registers external tool descriptors (dicts
{name, description, inputSchema}) with `handler: mcp(Server, Tool)` and
effects [external]. Outbound invocation is deferred through
prlm_tools:prlm_mcp_invoke/5: one clause asserted here at module load looks
up the module-local dynamic hook

    prlm_mcp_transport(Session, Server, Tool, ArgsDict, Value)

which hosts and tests implement by asserting clauses (arg-dependent
adapters) or via prlm_mcp_set_transport/4, which asserts a canned-value
clause (Server/Tool -> Value, any arguments). With no matching transport
clause the invoke fails, so prlm_tool_call/5 returns
result{status:error,...}: deferred adapters fail closed.

Note on arity: the transport lookup carries the value argument (a transport
that cannot produce a value is not a transport), hence /5; the exported
setter keeps the four-argument shape (Session, Server, Tool, Value).
*/

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module('./prlm_kernel').
:- use_module('./prlm_session').
:- use_module('./prlm_tools').

prlm_mcp_export_ready :-
    prlm_kernel_ready,
    prlm_session_ready,
    prlm_tools_ready.

% ============================================================
% Export-declaration state
% ============================================================

:- dynamic mcp_exported/3.       % mcp_exported(Engine, Module, Name/Arity)
:- dynamic engine_tool_target/5. % engine_tool_target(N, Engine, Module, Name, Arity)
:- dynamic engine_tool_argspec/2.% engine_tool_argspec(N, [arg(Name,Type),...])
:- dynamic engine_tool_seq/1.    % engine_tool_seq(LastN)

% ------------------------------------------------------------
% Kernel load hook. ONE clause: only mcp_export/1 with a valid
% name/arity indicator is accepted; anything else fails so the kernel
% raises prlm_error(directive_error, _{directive: D}).
% ------------------------------------------------------------

:- multifile(prlm_kernel:prlm_load_directive/3).

prlm_kernel:prlm_load_directive(Engine, Module, mcp_export(Ind)) :-
    prlm_mcp_export:handle_mcp_export(Engine, Module, Ind).

handle_mcp_export(Engine, Module, Ind) :-
    valid_indicator(Ind),
    !,
    (   mcp_exported(Engine, Module, Ind)
    ->  true
    ;   assertz(mcp_exported(Engine, Module, Ind))
    ).
% no cut-escape: invalid shapes fall through to failure.

valid_indicator(Name/Arity) :-
    atom(Name),
    Name \== '',
    integer(Arity),
    Arity >= 0.

%! prlm_mcp_export_declare(+Engine, +Module, +Name/Arity) is det
%
% Public API equivalent of the `:- mcp_export(Name/Arity).` directive:
% record the declaration for Engine. Invalid indicators throw
% prlm_error(type_error, _{...}).
prlm_mcp_export_declare(Engine, Module, Ind) :-
    (   atom(Engine),
        atom(Module),
        valid_indicator(Ind)
    ->  true
    ;   throw(prlm_error(type_error, _{mcp_export: Ind}))
    ),
    (   mcp_exported(Engine, Module, Ind)
    ->  true
    ;   assertz(mcp_exported(Engine, Module, Ind))
    ).

%! prlm_mcp_exported(+Engine, ?Module, ?Name/Arity) is nondet
%
% Recorded export declarations for Engine (the raw declaration store).
prlm_mcp_exported(Engine, Module, Ind) :-
    mcp_exported(Engine, Module, Ind).

% ============================================================
% Surface generation
% ============================================================

%! prlm_mcp_surface(+Engine, -Tools) is det
%
% Tool descriptors for every mcp_export declaration whose predicate is
% actually exported by its module in Engine, sorted by tool name.
prlm_mcp_surface(Engine, Tools) :-
    findall(Ind-Module,
            mcp_exported(Engine, Module, Ind),
            Pairs0),
    sort(Pairs0, Pairs),                        % dedupe, deterministic
    surface_exported(Pairs, Engine, Tools0),
    map_list_to_pairs(tool_desc_name, Tools0, Tagged),
    keysort(Tagged, Sorted),
    pairs_values(Sorted, Tools).

surface_exported([], _, []).
surface_exported([Ind-Module|Rest], Engine, [Tool|Tools]) :-
    Ind = Name/Arity,
    prlm_module_exports(Engine, Module, Exports),
    memberchk(Ind, Exports),
    !,
    build_descriptor(Engine, Module, Name, Arity, Tool),
    surface_exported(Rest, Engine, Tools).
surface_exported([_|Rest], Engine, Tools) :-
    surface_exported(Rest, Engine, Tools).

tool_desc_name(T, N) :- get_dict(name, T, N).

build_descriptor(Engine, Module, Name, Arity, Tool) :-
    atomic_list_concat([prlm, Module, Name, Arity], '_', ToolName),
    format(string(DescS), 'Engine predicate ~w:~w/~w (Prolog-RLM MCP export; last argument is the result)',
           [Module, Name, Arity]),
    atom_string(Desc, DescS),
    schema_args(Engine, Module, Name, Arity, ArgsSpec),
    argspec_properties(ArgsSpec, Props),
    argspec_names(ArgsSpec, Required),
    Tool = mcp_tool{name: ToolName,
                    description: Desc,
                    inputSchema: mcp_schema{type: object,
                                            properties: Props,
                                            required: Required},
                    source: source{module: Module,
                                   predicate: Name/Arity,
                                   engine: Engine}}.

% Schema convention: companion <name>_schema/1 returning
% schema([arg(Name,Type),...]) with exactly Arity-1 entries; else the
% positional fallback arg1..argN all typed string.
schema_args(Engine, Module, Name, Arity, ArgsSpec) :-
    Arity > 0,
    !,
    NArgs is Arity - 1,
    (   companion_schema(Engine, Module, Name, Schema)
    ->  (   argspec_of_schema(Schema, NArgs, ArgsSpec0)
        ->  ArgsSpec = ArgsSpec0
        ;   fallback_argspec(NArgs, ArgsSpec)
        )
    ;   fallback_argspec(NArgs, ArgsSpec)
    ).
schema_args(_, _, _, 0, []).

companion_schema(Engine, Module, Name, Schema) :-
    atom_concat(Name, '_schema', SchemaName),
    SchemaGoal =.. [SchemaName, S],
    catch(prlm_call_first(Engine, Module, SchemaGoal, [schema-S], Result),
          _,
          fail),
    get_dict(schema, Result, Schema).

argspec_of_schema(schema(Args), NArgs, ArgsSpec) :-
    is_list(Args),
    length(Args, NArgs),
    maplist(valid_arg_spec, Args),
    !,
    maplist(sanitize_arg, Args, ArgsSpec).

valid_arg_spec(arg(Name, Type)) :-
    atom(Name),
    tool_type(Type).

sanitize_arg(arg(Name, Type), arg(Name, Type2)) :-
    (   tool_type(Type) -> Type2 = Type ; Type2 = string ).

fallback_argspec(N, ArgsSpec) :-
    (   N >= 1
    ->  numlist(1, N, Idxs),
        maplist(positional_arg, Idxs, ArgsSpec)
    ;   ArgsSpec = []
    ).

positional_arg(I, arg(Name, string)) :-
    atom_concat(arg, I, Name).

% Mirrors prlm_tools' argument-type vocabulary (not exported there).
tool_type(atom).
tool_type(number).
tool_type(integer).
tool_type(string).
tool_type(list).
tool_type(term).
tool_type(dict).

% ============================================================
% Registration into prlm_tools (EXPORT execution side)
% ============================================================

%! prlm_mcp_register_tools(+Session, +Engine, -Registered) is det
%
% Surface Engine's exported mcp_export declarations and register one
% prlm_tools tool per descriptor. Each tool gets a unique dynamically
% asserted wrapper predicate prlm_mcp_export:tool_<N>/2 as its host
% handler, executing the engine predicate through prlm_call_first/5.
% Registered is the list of registered tool names (surface order).
prlm_mcp_register_tools(Session, Engine, Registered) :-
    prlm_mcp_surface(Engine, Tools),
    maplist(register_surface_tool(Session), Tools, Registered).

register_surface_tool(Session, Tool, ToolName) :-
    next_wrapper_n(N),
    get_dict(name, Tool, ToolName),
    get_dict(description, Tool, Description),
    get_dict(properties, Tool.inputSchema, Props),
    maplist(property_argspec, Props, ArgsSpec),
    Tool.source = source{module: Module,
                         predicate: Name/Arity,
                         engine: Engine},
    assertz(engine_tool_target(N, Engine, Module, Name, Arity)),
    assertz(engine_tool_argspec(N, ArgsSpec)),
    wrapper_functor(N, WFunctor),
    WrapperHead =.. [WFunctor, Args, Value],
    assertz(
        (   WrapperHead :-
                prlm_mcp_export:engine_tool_call(N, Args, Value)
        )),
    prlm_tool_register(Session,
                       tool{name: ToolName,
                            description: Description,
                            args_schema: ArgsSpec,
                            capability: [],
                            authority: approve_diff,
                            effects: [read],
                            result_schema: term,
                            handler: host(prlm_mcp_export:WFunctor)},
                       _).

wrapper_functor(N, WFunctor) :-
    atom_concat(tool_, N, WFunctor).

next_wrapper_n(N) :-
    (   retract(engine_tool_seq(N0)) -> true ; N0 = 0 ),
    N is N0 + 1,
    assertz(engine_tool_seq(N)).

property_argspec(Property, arg(Name, Type)) :-
    get_dict(name, Property, Name),
    get_dict(type, Property, Type).

% The wrapper body: lay the normalized ArgsDict onto the engine
% predicate's leading arguments in schema order; the last argument is a
% fresh output variable projected through prlm_call_first/5.
engine_tool_call(N, ArgsDict, Value) :-
    engine_tool_target(N, Engine, Module, Name, _Arity),
    engine_tool_argspec(N, ArgsSpec),
    argspec_names(ArgsSpec, ArgNames),
    arg_values(ArgNames, ArgsDict, Values),
    append(Values, [Out], All),
    Goal =.. [Name|All],
    prlm_call_first(Engine, Module, Goal, [out-Out], Result),
    get_dict(out, Result, Value).

arg_values([], _, []).
arg_values([K|Ks], ArgsDict, [V|Vs]) :-
    get_dict(K, ArgsDict, V),
    arg_values(Ks, ArgsDict, Vs).

argspec_names([], []).
argspec_names([arg(Name, _)|Rest], [Name|Names]) :-
    argspec_names(Rest, Names).

argspec_properties([], []).
argspec_properties([arg(Name, Type)|Rest],
                   [property{name: Name, type: Type}|Props]) :-
    argspec_properties(Rest, Props).

% ============================================================
% Consume side (external MCP descriptors -> session tools)
% ============================================================

%! prlm_mcp_consume(+Session, +ServerName, +ToolsJSON, -Count) is det
%
% Register external MCP tool descriptors (dicts with name, description,
% inputSchema) for Session under ServerName. Each becomes a prlm_tools
% tool with handler mcp(ServerName, ToolName), authority approve_diff,
% capability [] and effects [external]; the args schema is derived from
% inputSchema.properties keys (object-map or property-list form), types
% defaulting to string. Count is the number registered; a conflicting
% existing tool name throws (fail closed, no silent partial consume).
prlm_mcp_consume(Session, ServerName, ToolsJSON, Count) :-
    (   atom(ServerName) -> true
    ;   throw(prlm_error(type_error, _{server: ServerName}))
    ),
    consume_all(ToolsJSON, Session, ServerName, 0, Count).

consume_all([], _, _, Count, Count).
consume_all([T|Ts], Session, Server, N0, Count) :-
    consume_one(T, Session, Server),
    N1 is N0 + 1,
    consume_all(Ts, Session, Server, N1, Count).

consume_one(Desc, Session, Server) :-
    (   is_dict(Desc) -> true
    ;   throw(prlm_error(type_error, _{mcp_tool: Desc}))
    ),
    get_dict(name, Desc, Name0),
    to_atom(Name0, Name),
    get_dict(description, Desc, D0),
    to_atom(D0, Description),
    (   get_dict(inputSchema, Desc, IS) -> true ; IS = _{} ),
    external_args(IS, ArgsSpec),
    prlm_tool_register(Session,
                       tool{name: Name,
                            description: Description,
                            args_schema: ArgsSpec,
                            capability: [],
                            authority: approve_diff,
                            effects: [external],
                            result_schema: term,
                            handler: mcp(Server, Name)},
                       _).

to_atom(A, A) :-
    atom(A),
    !.
to_atom(S, A) :-
    string(S),
    !,
    atom_string(A, S).
to_atom(Other, _) :-
    throw(prlm_error(type_error, _{mcp_tool_field: Other})).

% inputSchema.properties: object map (Name -> Type-or-Spec, keys sorted
% for determinism) or list of property dicts (kept in listed order).
external_args(IS, ArgsSpec) :-
    (   get_dict(properties, IS, Props) -> true ; Props = _{} ),
    (   is_dict(Props)
    ->  dict_pairs(Props, _, KVPairs0),
        map_list_to_pairs(key_of, KVPairs0, Tagged),
        keysort(Tagged, Sorted),
        pairs_values(Sorted, TypedPairs),
        maplist(typed_arg_spec, TypedPairs, ArgsSpec)
    ;   is_list(Props)
    ->  maplist(prop_dict_arg_spec, Props, ArgsSpec)
    ;   ArgsSpec = []
    ).

key_of(K-_, K).

typed_arg_spec(Name-V0, arg(Name, Type)) :-
    (   is_dict(V0) -> get_dict(type, V0, V1) ; V1 = V0 ),
    external_type(V1, Type).

prop_dict_arg_spec(P, arg(Name, Type)) :-
    get_dict(name, P, Name0),
    to_atom(Name0, Name),
    (   get_dict(type, P, T0) -> true ; T0 = string ),
    external_type(T0, Type).

% External schema types default to string; only known argument types are
% passed through so registration can never throw on a bad type.
external_type(T, T) :-
    atom(T),
    tool_type(T),
    !.
external_type(T, Type) :-
    string(T),
    !,
    atom_string(A, T),
    (   tool_type(A) -> Type = A ; Type = string ).
external_type(_, string).

% ============================================================
% Outbound transport (deferred mcp handler)
% ============================================================

:- dynamic prlm_mcp_transport/5.
% prlm_mcp_transport(Session, Server, Tool, ArgsDict, Value)
% Hosts/tests assert clauses here: full adapters (matching on ArgsDict)
% or canned routes via prlm_mcp_set_transport/4. No matching clause => the
% deferred invoke fails => prlm_tool_call/5 returns an error result.

% The single deferred-invoke clause, asserted once at module load: the
% mcp handler in prlm_tools resolves through the transport hook and fails
% closed when no transport clause matches.
:- initialization
       assertz(
           prlm_tools:prlm_mcp_invoke(Session, Server, Tool, ArgsDict, Value) :-
               prlm_mcp_export:prlm_mcp_transport(Session, Server,
                                                  Tool, ArgsDict, Value)).

%! prlm_mcp_set_transport(+Session, +Server, +Tool, +Value) is det
%
% Assert a canned transport route: any outbound mcp(Server, Tool) invoke
% on Session yields Value regardless of arguments. Value must be ground.
prlm_mcp_set_transport(Session, Server, Tool, Value) :-
    (   atom(Session), atom(Server), atom(Tool), ground(Value)
    ->  true
    ;   throw(prlm_error(type_error,
                         _{transport: Session:Server:Tool, value: Value}))
    ),
    assertz(prlm_mcp_transport(Session, Server, Tool, _, Value)).

%! prlm_mcp_clear_transport(+Session) is det
%
% Drop every transport clause (canned and host-asserted) for Session.
prlm_mcp_clear_transport(Session) :-
    retractall(prlm_mcp_transport(Session, _, _, _, _)).
