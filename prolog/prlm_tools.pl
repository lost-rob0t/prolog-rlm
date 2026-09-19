:- module(prlm_tools,
          [ prlm_tools_ready/0,
            prlm_tool_register/3,
            prlm_tool_discover/2,
            prlm_tool_lookup/3,
            prlm_tool_call/5,
            prlm_tool_check_effects/3,
            prlm_tools_default/1,
            prlm_tool_to_predicate/3,
            prlm_predicate_to_tool/5,
            prlm_projection/4
          ]).

/** <module> prlm_tools — tools as native language capabilities

A tool is a closed record `tool{name, description, args_schema, capability,
authority, effects, result_schema, handler}`. Every tool operation carries an
explicit argument schema, a capability requirement, an authority tier, an
effect set, a result schema and provenance. Tools are discoverable from the
registration table alone — no model is required to enumerate them.

Invocation (`prlm_tool_call/5`) runs a fixed gated order, each step before
the next:

    1. cancellation check (throws on a cancelled session)
    2. tool lookup (existence_error when unknown)
    3. argument validation/normalisation against args_schema
    4. capability gate (caller caps must cover the tool caps; failure event)
    5. authority gate (prlm_authority_allows/2; allow_once consumes)
    6. budget check + charge of one tool_call
    7. tool_call event
    8. handler execution (host / lang / mcp / actor)
    9. result{status, value, evidence{tool, args, time, provenance,
       duration_ms}}
    10. observation event

Handler shapes:

  * `host(Module:Pred)` — `call(Module:Pred, ArgsDict, Value)`; `Pred` is a
    callable term whose arity-2 form `Module:Name(Args, Value)` is invoked.
  * `lang(Module:Name/2)` — an engine predicate `Name(args(ArgList), Result)`
    with `ArgList = [nv(Name, Value), ...]`, executed through
    prlm_query_first/4 on the session engine.
  * `mcp(Server, Tool)` — DEFERRED: resolved at call time through the
    multifile dynamic hook `prlm_mcp_invoke/5`
    (Session, Server, Tool, ArgsDict, Value); default clauses fail, which
    yields an error result.
  * `actor(ActorId)` — DEFERRED: resolved at call time through the
    multifile dynamic hook `prlm_actor_tool_invoke/4`
    (Session, ActorId, ArgsDict, Value); same pattern.

Errors follow the kernel/session model: throw(prlm_error(Type, InfoDict)).
Handler exceptions never escape: they become result{status:error} plus a
failure event.
*/

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).
:- use_module('./prlm_kernel').
:- use_module('./prlm_session').

% Deferred execution hooks. External integrations (MCP transports, actor
% runtimes) add clauses with `:- multifile prlm_tools:prlm_mcp_invoke/5.`
:- multifile prlm_mcp_invoke/5.
:- dynamic prlm_mcp_invoke/5.
:- multifile prlm_actor_tool_invoke/4.
:- dynamic prlm_actor_tool_invoke/4.

% Module-local registration table, keyed by the owning session.
:- dynamic tool_reg/2.

prlm_tools_ready :-
    prlm_session_ready,
    forall(prlm_tool_type(_), true),
    forall(prlm_tool_effect(_), true),
    forall(prlm_tool_tier(_), true).

% ============================================================
% Vocabularies
% ============================================================

prlm_tool_type(atom).
prlm_tool_type(number).
prlm_tool_type(integer).
prlm_tool_type(string).
prlm_tool_type(list).
prlm_tool_type(term).
prlm_tool_type(dict).

prlm_tool_effect(read).
prlm_tool_effect(write).
prlm_tool_effect(shell).
prlm_tool_effect(net).
prlm_tool_effect(process).
prlm_tool_effect(external).

prlm_tool_tier(approve_diff).
prlm_tool_tier(allow_once).
prlm_tool_tier(allow_session).
prlm_tool_tier(dangerous).

tool_key_full([args_schema, authority, capability, description,
               effects, handler, name, result_schema]).
tool_key_meta([args_schema, authority, capability, description,
               effects, name, result_schema]).

% ============================================================
% Errors
% ============================================================

tool_reg_error(Tool, Info0) :-
    (   is_dict(Tool),
        get_dict(name, Tool, N),
        atom(N)
    ->  Info = Info0.put(_{tool: N})
    ;   Info = Info0.put(_{tool: Tool})
    ),
    throw(prlm_error(type_error, Info)).

% ============================================================
% Registration
% ============================================================

%! prlm_tool_register(+Session, +ToolIn, -Tool) is det
%
% Validate the closed tool structure and store it for Session. Emits
% nothing: discovery is passive. Duplicate names are rejected.
prlm_tool_register(Session, ToolIn, Tool) :-
    valid_tool_structure(ToolIn, tool_key_full, Name),
    (   prlm_tool_lookup(Session, Name, _)
    ->  throw(prlm_error(type_error, _{duplicate: Name}))
    ;   true
    ),
    assertz(tool_reg(Session, ToolIn)),
    Tool = ToolIn.

valid_tool_structure(Tool, KeyPred, Name) :-
    (   is_dict(Tool, tool)
    ->  true
    ;   tool_reg_error(Tool, _{reason: not_tool_dict})
    ),
    dict_pairs(Tool, tool, Pairs0),
    pairs_keys(Pairs0, Keys0),
    sort(Keys0, Keys),
    call(KeyPred, Required),
    (   Keys == Required
    ->  true
    ;   tool_reg_error(Tool, _{reason: bad_keys, keys: Keys})
    ),
    % get_dict/3 (not dot syntax) everywhere: dot access throws on a
    % missing key, and the meta shape intentionally has no handler key.
    get_dict(name, Tool, NameField),
    (   atom(NameField),
        NameField \== ''
    ->  Name = NameField
    ;   tool_reg_error(Tool, _{reason: bad_name})
    ),
    get_dict(description, Tool, Desc),
    (   atom(Desc)
    ->  true
    ;   tool_reg_error(Tool, _{reason: bad_description})
    ),
    get_dict(args_schema, Tool, Schema),
    valid_args_schema(Tool, Schema),
    get_dict(capability, Tool, Caps),
    valid_capability(Tool, Caps),
    get_dict(authority, Tool, Tier),
    (   prlm_tool_tier(Tier)
    ->  true
    ;   tool_reg_error(Tool, _{reason: bad_authority, authority: Tier})
    ),
    get_dict(effects, Tool, Effects),
    valid_effects(Tool, Effects),
    get_dict(result_schema, Tool, RSchema),
    (   prlm_tool_type(RSchema)
    ->  true
    ;   tool_reg_error(Tool, _{reason: bad_result_schema,
                               result_schema: RSchema})
    ),
    (   get_dict(handler, Tool, Handler)
    ->  valid_handler(Tool, Handler)   % meta dicts carry no handler
    ;   true
    ).

valid_args_schema(Tool, Schema) :-
    (   is_list(Schema)
    ->  true
    ;   tool_reg_error(Tool, _{reason: bad_args_schema, args_schema: Schema})
    ),
    maplist(valid_arg_spec(Tool), Schema),
    map_list_to_pairs(arg_spec_name, Schema, Tagged),
    keysort(Tagged, Sorted),
    (   pairs_same_names_unique(Sorted)
    ->  true
    ;   tool_reg_error(Tool, _{reason: duplicate_arg_name})
    ).

pairs_same_names_unique([]).
pairs_same_names_unique([N-_|T]) :-
    (   T == []
    ->  true
    ;   T = [N2-_|_],
        N \== N2,
        pairs_same_names_unique(T)
    ).

arg_spec_name(arg(Name, _), Name).

valid_arg_spec(Tool, arg(Name, Type)) :- !,
    (   atom(Name),
        Name \== '',
        prlm_tool_type(Type)
    ->  true
    ;   tool_reg_error(Tool, _{reason: bad_arg_spec, arg: Name, type: Type})
    ).
valid_arg_spec(Tool, Other) :-
    tool_reg_error(Tool, _{reason: bad_arg_spec, arg: Other}).

valid_capability(Tool, Caps) :-
    (   is_list(Caps),
        all_atoms(Caps)
    ->  true
    ;   tool_reg_error(Tool, _{reason: bad_capability, capability: Caps})
    ).

all_atoms([]).
all_atoms([A|T]) :- atom(A), all_atoms(T).

valid_effects(Tool, Effects) :-
    (   is_list(Effects),
        all_known_effects(Effects)
    ->  true
    ;   tool_reg_error(Tool, _{reason: bad_effects, effects: Effects})
    ).

all_known_effects([]).
all_known_effects([E|T]) :-
    prlm_tool_effect(E),
    all_known_effects(T).

valid_handler(Tool, host(M:P)) :- !,
    (   atom(M),
        valid_host_pred(P)
    ->  true
    ;   tool_reg_error(Tool, _{reason: bad_handler, handler: host(M:P)})
    ).
valid_handler(Tool, lang(M:N/A)) :- !,
    (   atom(M),
        atom(N),
        A == 2
    ->  true
    ;   tool_reg_error(Tool, _{reason: bad_handler, handler: lang(M:N/A)})
    ).
valid_handler(Tool, mcp(Server, ToolName)) :- !,
    (   atom(Server),
        atom(ToolName)
    ->  true
    ;   tool_reg_error(Tool, _{reason: bad_handler, handler: mcp(Server, ToolName)})
    ).
valid_handler(_Tool, actor(ActorId)) :- !,
    (   atom(ActorId)
    ;   integer(ActorId)
    ),
    !.
valid_handler(Tool, actor(ActorId)) :-
    tool_reg_error(Tool, _{reason: bad_handler, handler: actor(ActorId)}).
valid_handler(Tool, Handler) :-
    tool_reg_error(Tool, _{reason: bad_handler, handler: Handler}).

% host(Module:Pred): Pred is a closure callable as call(Pred, Args, Value).
% Accepted shapes: Name (implying Name/2), the indicator Name/2, or a
% partially applied compound closure (e.g. handler(Session)).
valid_host_pred(Name) :- atom(Name).
valid_host_pred(Name/2) :- atom(Name).
valid_host_pred(P) :- compound(P).

% ============================================================
% Discovery and lookup
% ============================================================

%! prlm_tool_discover(+Session, -Tools) is det
%
% All tools registered for Session, deterministically ordered by name.
prlm_tool_discover(Session, Tools) :-
    findall(T, tool_reg(Session, T), Ts),
    map_list_to_pairs(tool_reg_name, Ts, Tagged),
    keysort(Tagged, Sorted),
    pairs_values(Sorted, Tools).

tool_reg_name(Tool, Name) :- get_dict(name, Tool, Name).

%! prlm_tool_lookup(+Session, +Name, -Tool) is semidet
prlm_tool_lookup(Session, Name, Tool) :-
    tool_reg(Session, Tool),
    get_dict(name, Tool, Name),
    !.

% ============================================================
% Invocation
% ============================================================

%! prlm_tool_call(+Session, +CallerCaps, +Name, +ArgsIn, -Result) is det
%
% The gated tool invocation. See the module documentation for the exact
% step order. Handler exceptions become result{status:error} and a
% failure event; they are never rethrown.
prlm_tool_call(Session, CallerCaps, Name, ArgsIn, Result) :-
    prlm_check_cancelled(Session),                                     % 1
    (   is_list(CallerCaps)
    ->  true
    ;   throw(prlm_error(type_error,
                         _{tool: Name, reason: caller_caps_not_list}))
    ),
    (   prlm_tool_lookup(Session, Name, Tool)
    ->  true
    ;   throw(prlm_error(existence_error, _{tool: Name}))              % 2
    ),
    normalize_args(Name, Tool.args_schema, ArgsIn, Normalized),        % 3
    capability_gate(Session, Name, CallerCaps, Tool.capability),       % 4
    (   prlm_authority_allows(Session, Tool.authority)
    ->  true
    ;   throw(prlm_error(forbidden,
                         _{tool: Name, authority: Tool.authority}))    % 5
    ),
    prlm_budget_check(Session, tool_calls, 1),                         % 6
    prlm_budget_charge(Session, tool_calls, 1),
    prlm_event_emit(Session, tool_call,                                % 7
                    _{tool: Name,
                      args: Normalized,
                      effects: Tool.effects}),
    get_time(T0),
    run_handler(Tool.handler, Session, Normalized, Ok, ValueOut),      % 8
    get_time(T1),
    Duration is round((T1 - T0) * 1000),
    handler_provenance(Tool.handler, Prov),
    tool_outcome(Ok, ValueOut, Status, ValueFinal),
    (   Status == error
    ->  (   ground(ValueFinal)
        ->  ErrData = ValueFinal
        ;   term_to_atom(ValueFinal, ErrData)   % host balls may carry a
        ),                                      % non-ground stack context
        prlm_event_emit(Session, failure,
                        _{tool: Name, status: error, error: ErrData})
    ;   true
    ),
    Evidence = evidence{tool: Name,
                        args: Normalized,
                        time: T1,
                        provenance: Prov,
                        duration_ms: Duration},                        % 9
    Result = result{status: Status, value: ValueFinal, evidence: Evidence},
    prlm_event_emit(Session, observation,                              % 10
                    _{tool: Name, status: Status, duration_ms: Duration}).

tool_outcome(true, Value, ok, Value) :-
    ground(Value),
    !.
tool_outcome(true, _Value, error, unground_result).
tool_outcome(false, Value, error, Value).

capability_gate(Session, Name, CallerCaps, NeedCaps) :-
    missing_caps(NeedCaps, CallerCaps, Missing),
    (   Missing == []
    ->  true
    ;   prlm_event_emit(Session, failure,
                        _{tool: Name,
                          status: error,
                          reason: forbidden_caps,
                          missing: Missing}),
        throw(prlm_error(forbidden, _{tool: Name, missing: Missing}))
    ).

missing_caps([], _, []).
missing_caps([C|T], Have, [C|M]) :-
    \+ memberchk(C, Have),
    !,
    missing_caps(T, Have, M).
missing_caps([_|T], Have, M) :-
    missing_caps(T, Have, M).

% ============================================================
% Argument validation / normalisation
% ============================================================

normalize_args(Name, Schema, ArgsIn, Normalized) :-
    (   is_dict(ArgsIn)
    ->  true
    ;   throw(prlm_error(type_error,
                         _{tool: Name, arg: '-', expected: dict}))
    ),
    args_pairs(Schema, Pairs),
    check_extra_keys(Name, ArgsIn, Pairs),
    normalize_each(Pairs, ArgsIn, Name, NPairs),
    dict_create(Normalized, args, NPairs).

args_pairs([], []).
args_pairs([arg(K, T)|Rest], [K-T|Pairs]) :-
    args_pairs(Rest, Pairs).

check_extra_keys(Name, ArgsIn, Pairs) :-
    dict_pairs(ArgsIn, _, InPairs),
    (   extra_key(InPairs, Pairs, Key)
    ->  throw(prlm_error(type_error,
                         _{tool: Name, arg: Key, expected: none}))
    ;   true
    ).

extra_key([K-_|_], Pairs, K) :-
    \+ memberchk(K-_, Pairs).
extra_key([_|T], Pairs, K) :-
    extra_key(T, Pairs, K).

normalize_each([], _, _, []).
normalize_each([K-T|Rest], ArgsIn, Name, [K-V|NP]) :-
    (   get_dict(K, ArgsIn, V0)
    ->  true
    ;   throw(prlm_error(type_error, _{tool: Name, arg: K, expected: T}))
    ),
    (   coerce_arg(T, V0, V),
        ground(V)
    ->  true
    ;   throw(prlm_error(type_error, _{tool: Name, arg: K, expected: T}))
    ),
    normalize_each(Rest, ArgsIn, Name, NP).

% Strict type check; the only coercion is a whole-valued number to
% integer for the integer type (e.g. 3.0 -> 3).
coerce_arg(integer, V, V) :-
    integer(V),
    !.
coerce_arg(integer, V, I) :-
    number(V),
    I is round(V),
    I =:= V.
coerce_arg(atom, V, V) :- atom(V).
coerce_arg(number, V, V) :- number(V).
coerce_arg(string, V, V) :- string(V).
coerce_arg(list, V, V) :- is_list(V).
coerce_arg(dict, V, V) :- is_dict(V).
coerce_arg(term, V, V) :- nonvar(V).

% ============================================================
% Handler execution
% ============================================================

run_handler(host(M:P), _Session, Args, Ok, V) :- !,
    host_closure(P, Args, V, P2),
    HandlerGoal = ':'(M, P2),
    (   catch(HandlerGoal, Ex, true)
    ->  (   var(Ex)
        ->  (   var(V) -> V = true
            ;   true
            ),
            Ok = true
        ;   Ok = false,
            V = Ex
        )
    ;   Ok = false,
        V = handler_failed
    ).
run_handler(lang(M:Name/2), Session, Args, Ok, V) :- !,
    (   catch(run_lang(Session, M, Name, Args, V), Ex, true)
    ->  (   var(Ex)
        ->  Ok = true
        ;   Ok = false,
            V = Ex
        )
    ;   Ok = false,
        V = handler_failed
    ).
run_handler(mcp(Server, ToolName), Session, Args, Ok, V) :- !,
    (   catch(prlm_mcp_invoke(Session, Server, ToolName, Args, V), Ex, true)
    ->  (   var(Ex)
        ->  Ok = true
        ;   Ok = false,
            V = Ex
        )
    ;   Ok = false,
        V = handler_failed
    ).
run_handler(actor(ActorId), Session, Args, Ok, V) :- !,
    (   catch(prlm_actor_tool_invoke(Session, ActorId, Args, V), Ex, true)
    ->  (   var(Ex)
        ->  Ok = true
        ;   Ok = false,
            V = Ex
        )
    ;   Ok = false,
        V = handler_failed
    ).

% Build the host handler goal: Name -> Name(Args, V); Name/2 indicator ->
% Name(Args, V); compound closure C -> C with Args, V appended.
host_closure(Name, Args, V, Goal) :-
    atom(Name),
    !,
    Goal =.. [Name, Args, V].
host_closure(Name/_A, Args, V, Goal) :-
    Goal =.. [Name, Args, V].
host_closure(Closure, Args, V, C2) :-
    compound(Closure),
    Closure =.. [F|As],
    append(As, [Args, V], As2),
    C2 =.. [F|As2].

%! run_lang(+Session, +Module, +Name, +ArgsDict, -Value) is semidet
%
% Execute engine predicate Name(args(ArgList), Result) in the session
% engine through prlm_query_first/4 and project the result variable.
run_lang(Session, Module, Name, Args, Value) :-
    prlm_session_engine(Session, Engine),
    dict_pairs(Args, _, APairs),
    arg_list(APairs, ArgList),
    ResultKey = '$prlm_tool_result',
    Goal =.. [Name, args(ArgList), '$v'(ResultKey)],
    prlm_query_first(Engine, Module, Goal, Env),
    env_project(Env, '$v'(ResultKey), Value).

arg_list([], []).
arg_list([K-V|Pairs], [nv(K, V)|NVs]) :-
    arg_list(Pairs, NVs).

% Dereference/project engine variables (''$v'(Name)') against a solution
% environment (dict Name -> Term). Mirrors the kernel's projection but
% uses only public dict access.
env_deref(Env, T0, T) :-
    (   is_vterm(T0)
    ->  vterm_name(T0, N),
        (   get_dict(N, Env, V)
        ->  (   is_vterm(V),
                vterm_name(V, N)
            ->  T = T0                       % self-binding guard
            ;   env_deref(Env, V, T)
            )
        ;   T = T0
        )
    ;   T = T0
    ).

env_project(Env, T0, T) :-
    env_project_walk(Env, T0, [], T).

env_project_walk(Env, T0, Seen, T) :-
    env_deref(Env, T0, T1),
    (   is_vterm(T1)
    ->  T = T1
    ;   is_dict(T1)
    ->  T = T1                           % engine-side dicts stay opaque
    ;   compound(T1)
    ->  (   memberchk(T1, Seen)
        ->  T = T1
        ;   T1 =.. [F|As],
            env_project_args(Env, As, [T1|Seen], As2),
            T =.. [F|As2]
        )
    ;   T = T1
    ).

env_project_args(_, [], _, []).
env_project_args(Env, [A|As], Seen, [A2|As2]) :-
    env_project_walk(Env, A, Seen, A2),
    env_project_args(Env, As, Seen, As2).

is_vterm(T) :-
    nonvar(T),
    functor(T, '$v', 1).

vterm_name('$v'(Name), Name).

handler_provenance(host(M:P), Prov) :- !,
    term_to_atom(host:M:P, Prov).
handler_provenance(lang(M:N/A), Prov) :- !,
    term_to_atom(lang:M:N/A, Prov).
handler_provenance(mcp(Server, _ToolName), Prov) :- !,
    term_to_atom(mcp:Server, Prov).
handler_provenance(actor(ActorId), Prov) :-
    term_to_atom(actor:ActorId, Prov).

% ============================================================
% Effect verification support
% ============================================================

%! prlm_tool_check_effects(+Session, +Name, +ExpectedEffects) is semidet
%
% True iff the registered tool's declared effects are a superset of
% ExpectedEffects. Unknown tools fail.
prlm_tool_check_effects(Session, Name, ExpectedEffects) :-
    prlm_tool_lookup(Session, Name, Tool),
    forall(member(E, ExpectedEffects),
           memberchk(E, Tool.effects)).

% ============================================================
% Default starter pack (deterministic, no network, no shell)
% ============================================================

%! prlm_tools_default(+Session) is det
%
% Register the deterministic starter pack: echo, kv_put, kv_get, add,
% clock, fail_always. All are public (no capability requirement),
% allow_session authority, no external effects. Re-registering on a
% session that already has a tool of the same name throws.
prlm_tools_default(Session) :-
    prlm_tool_register(Session,
                       tool{name: echo,
                            description: 'Echo the input back as an atom.',
                            args_schema: [arg(input, term)],
                            capability: [],
                            authority: allow_session,
                            effects: [read],
                            result_schema: atom,
                            handler: host(prlm_tools:prlm_default_echo)},
                       _),
    prlm_tool_register(Session,
                       tool{name: kv_put,
                            description: 'Store a value in the session KVS.',
                            args_schema: [arg(key, atom), arg(value, term)],
                            capability: [],
                            authority: allow_session,
                            effects: [write],
                            result_schema: term,
                            handler: host(prlm_tools:prlm_default_kv_put(Session))},
                       _),
    prlm_tool_register(Session,
                       tool{name: kv_get,
                            description: 'Fetch a value from the session KVS.',
                            args_schema: [arg(key, atom)],
                            capability: [],
                            authority: allow_session,
                            effects: [read],
                            result_schema: term,
                            handler: host(prlm_tools:prlm_default_kv_get(Session))},
                       _),
    prlm_tool_register(Session,
                       tool{name: add,
                            description: 'Add two integers.',
                            args_schema: [arg(a, integer), arg(b, integer)],
                            capability: [],
                            authority: allow_session,
                            effects: [read],
                            result_schema: integer,
                            handler: host(prlm_tools:prlm_default_add)},
                       _),
    prlm_tool_register(Session,
                       tool{name: clock,
                            description: 'Current UNIX time as a float.',
                            args_schema: [],
                            capability: [],
                            authority: allow_session,
                            effects: [read],
                            result_schema: number,
                            handler: host(prlm_tools:prlm_default_clock)},
                       _),
    prlm_tool_register(Session,
                       tool{name: fail_always,
                            description: 'Always fails; error-path probe.',
                            args_schema: [],
                            capability: [],
                            authority: allow_session,
                            effects: [read],
                            result_schema: term,
                            handler: host(prlm_tools:prlm_fail_always)},
                       _).

% Default host handlers. These are module-local; the host handler shape
% calls them with explicit module qualification.
prlm_default_echo(Args, Value) :-
    get_dict(input, Args, V0),
    (   atom(V0)
    ->  Value = V0
    ;   term_to_atom(V0, Value)
    ).

prlm_default_kv_put(Session, Args, Value) :-
    get_dict(key, Args, Key),
    get_dict(value, Args, Value),
    prlm_session_put(Session, Key, Value).

prlm_default_kv_get(Session, Args, Value) :-
    get_dict(key, Args, Key),
    prlm_session_get(Session, Key, Value).

prlm_default_add(Args, Value) :-
    get_dict(a, Args, A),
    get_dict(b, Args, B),
    Value is A + B.

prlm_default_clock(_Args, Value) :-
    get_time(Value).

prlm_fail_always(_Args, _Value) :-
    fail.

% Test/projection helper host handler: pass the x argument through.
prlm_default_identity(Args, Value) :-
    get_dict(x, Args, Value).

% Handler that throws a host exception (error-path tests).
prlm_default_boom(_Args, _Value) :-
    throw(error(bang, prlm_tools)).

% ============================================================
% Tool <-> predicate projections
% ============================================================

%! prlm_tool_to_predicate(+Session, +Name, -CallPattern) is det
%
% Tool -> Prolog projection. CallPattern is the goal term
% `prlm_tools:prlm_projection(Session, Name, ArgsDict, Value)`; calling
% it (with ArgsDict bound) performs the gated tool call and yields Value
% when the tool result status is ok (fails otherwise; gate errors still
% throw).
prlm_tool_to_predicate(Session, Name, CallPattern) :-
    (   prlm_tool_lookup(Session, Name, _)
    ->  true
    ;   throw(prlm_error(existence_error, _{tool: Name}))
    ),
    CallPattern = prlm_tools:prlm_projection(Session, Name, _Args, _Value).

%! prlm_projection(+Session, +Name, +Args, -Value) is semidet
%
% The projection target: run the tool with the tool's own capability set
% as caller caps, succeed with Value when the result status is ok.
prlm_projection(Session, Name, Args, Value) :-
    (   prlm_tool_lookup(Session, Name, Tool)
    ->  true
    ;   throw(prlm_error(existence_error, _{tool: Name}))
    ),
    prlm_tool_call(Session, Tool.capability, Name, Args, Result),
    get_dict(status, Result, ok),
    get_dict(value, Result, Value).

%! prlm_predicate_to_tool(+Session, +Module, +Name/Arity, +Meta0, -Tool)
%                         is det
%
% Prolog -> tool projection for engine predicates. Validates that
% Module:Name/2 exists in the session engine, fills the lang handler and
% registers the tool. Meta0 is a closed `tool{}` dict with exactly the
% seven meta keys (no handler key).
prlm_predicate_to_tool(Session, Module, Name/Arity, Meta0, Tool) :-
    (   atom(Module),
        atom(Name)
    ->  true
    ;   throw(prlm_error(type_error,
                         _{engine_predicate: Module:Name/Arity}))
    ),
    (   Arity == 2
    ->  true
    ;   throw(prlm_error(type_error,
                         _{engine_predicate: Module:Name/Arity,
                           reason: engine_predicate_must_be_arity_2}))
    ),
    (   valid_tool_structure(Meta0, tool_key_meta, _MetaName)
    ->  true
    ;   throw(prlm_error(type_error, _{reason: bad_meta}))
    ),
    prlm_session_engine(Session, Engine),
    (   prlm_current_predicate(Engine, Module, Name/2)
    ->  true
    ;   throw(prlm_error(existence_error,
                         _{engine_predicate: Module:Name/2}))
    ),
    ToolIn = Meta0.put(_{handler: lang(Module:Name/2)}),
    prlm_tool_register(Session, ToolIn, Tool).
