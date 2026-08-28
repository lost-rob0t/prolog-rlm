:- module(rlm_plan_graph,
          [ plan_graph_parse/2,
            plan_graph_normalize/2,
            plan_graph_validate/4,
            plan_graph_ready/3,
            plan_graph_execute/5,
            plan_graph_run/5,
            plan_graph_run_async/4,
            plan_graph_cancel/1,
            plan_graph_cancellation_token/1,
            plan_graph_op/1,
            default_plan_graph_budget/1,
            plan_graph_resolve_symbol/3,
            plan_graph_symbol_ref_valid/1,
            plan_graph_source_span_valid/1
          ]).

/** <module> Closed project-op plan vocabulary and plan dependency-graph executor

Model output may propose a plan dependency graph over a closed project-op
vocabulary, but the graph is inert data: it is parsed, normalized, fully
validated (structure, ids, dependencies, cycles, closed vocabulary, per-op
arg shapes, per-op capabilities, aggregate budget) and only then executed.

`rlm_plan` remains the ONLY step executor. Each ready step is desugared
mechanically into a two-step closed-AST plan
`[tool(Op, literal(Args), Bind), final(var(Bind))]` executed with the
`rlm_plan` validate/execute ABIs inside the single async worker. Expert
closures are host-supplied only; model data is never a goal and never
reaches `call/1` except as the argument of a host-registered handler.

Scheduling semantics: `plan_graph_ready/3` admits exactly the pending steps
whose dependencies are all completed. A failed step transitively blocks its
dependents. Cancellation is not ordinary failure: it aborts the whole graph
and rethrows `error(rlm_cancelled(Token), _)`. `abandoned` is terminal
state, never retry authorization. An aggregate budget bounds totals across
step executions via `plan_result.budget_remaining` feed-forward.

This module adds no external-effect path. Ops classified externally
effectful in real use (`sync_remote/1`, `edit/2`, `create/2`, `delete/1`,
`run/1`) require expert packs whose handlers admit/dispatch/observe through
the durable effect boundary with trusted adapter/attempt identity. Shipped
handlers are pure host closures.
*/

:- use_module(library(lists)).
:- use_module(library(uuid)).
:- use_module(library(http/json)).
:- use_module(rlm_async, []).
:- use_module(rlm_plan, [default_plan_budget/1,
                         plan_validate/4,
                         plan_execute/4]).
:- use_module(rlm_tool, [capabilities_narrow/3,
                         capabilities_normalize/2]).

:- dynamic(plan_graph_cancel_state/2).
:- dynamic(plan_graph_cancel_thread/2).

/* -------------------------------------------------------------------------
 * Closed op vocabulary (inert data, never callables)
 * ---------------------------------------------------------------------- */

plan_graph_op(sync_remote/1).
plan_graph_op(index/1).
plan_graph_op(search/2).
plan_graph_op(locate/1).
plan_graph_op(read/1).
plan_graph_op(diff/2).
plan_graph_op(edit/2).
plan_graph_op(create/2).
plan_graph_op(delete/1).
plan_graph_op(run/1).
plan_graph_op(validate/1).
plan_graph_op(delegate/2).

%% plan_capability_required(+Op, -Capability) is det.
%
% Mechanical pairing between a closed-vocabulary op and the capability term
% the desugared plan requires. The desugared plan and its inner capability
% term both derive from this single declaration.
plan_capability_required(delegate/2, tool(spawn_agent)).
plan_capability_required(Op/_, tool(Op)) :-
    Op \== delegate.

%% op_effect_class(+Op, -Class) is det.
%
% Externally effectful ops require real expert packs to route through the
% durable effect boundary (normalize -> schema/capability/policy ->
% authority -> durable admission -> dispatch -> observe-or-indeterminate).
op_effect_class(sync_remote/1, external_effect).
op_effect_class(index/1, observation).
op_effect_class(search/2, observation).
op_effect_class(locate/1, observation).
op_effect_class(read/1, observation).
op_effect_class(diff/2, observation).
op_effect_class(edit/2, external_effect).
op_effect_class(create/2, external_effect).
op_effect_class(delete/1, external_effect).
op_effect_class(run/1, external_effect).
op_effect_class(validate/1, orchestration).
op_effect_class(delegate/2, orchestration).

default_plan_graph_budget(graph_budget{max_steps:64,
                                       max_total_tool_calls:16,
                                       max_total_model_calls:8,
                                       max_total_context_ops:32,
                                       max_total_output_bytes:65536,
                                       time_limit:30.0}).

/* -------------------------------------------------------------------------
 * Shared faults, options, and outcome helpers
 * ---------------------------------------------------------------------- */

graph_fault(Phase, Detail) :-
    throw(graph_fault(Phase, Detail)).

must_list(Value, Name) :-
    (   is_list(Value)
    ->  true
    ;   graph_fault(structure, not_a_list(Name))
    ).

require_dict_key(Dict, Key, Value) :-
    (   is_dict(Dict),
        get_dict(Key, Dict, Value)
    ->  true
    ;   graph_fault(structure, missing_key(Key))
    ).

require_exact_keys(Dict, Allowed) :-
    dict_keys(Dict, Keys),
    forall(member(Key, Keys), memberchk(Key, Allowed)).

require_atom_key(Dict, Key, Atom) :-
    require_dict_key(Dict, Key, Raw),
    (   catch(atom_string(Atom, Raw), _, fail)
    ->  true
    ;   graph_fault(structure, expected_atom(Key))
    ).

graph_option(Key, Options, Default, Value) :-
    must_list(Options, options),
    (   option_term(Key, Options, Value)
    ->  true
    ;   Value = Default
    ).

option_term(Key, Options, Value) :-
    functor(Term, Key, 1),
    arg(1, Term, Value),
    memberchk(Term, Options).

require_graph_outcome(ok(Value), Value).
require_graph_outcome(error(Error), _) :-
    graph_fault(internal, outcome_error(Error)).

require_caps_outcome(ok(Normalized), Normalized).
require_caps_outcome(error(capability_error{detail:Detail}), _) :-
    graph_fault(capability, capability_error(Detail)).

require_acyclic_data(Term) :-
    (   acyclic_term(Term)
    ->  true
    ;   graph_fault(structure, cyclic_data)
    ).

%% Public-entry exception mapping. Cancellation is never folded into an
%% outcome: it propagates so the awaiting facade observes the exact token.
graph_exception(_, Exception, _) :-
    cancellation_throw(Exception),
    !,
    throw(Exception).
graph_exception(_, graph_fault(Phase, Detail),
                error(plan_graph_error{phase:Phase,
                                       kind:FaultKind,
                                       detail:Detail})) :-
    fault_kind(Detail, FaultKind),
    !.
graph_exception(Phase, Exception,
                error(plan_graph_error{phase:Phase,
                                       kind:exception,
                                       detail:exception_data(Exception)})).

cancellation_throw(error(rlm_cancelled(_), _)).
cancellation_throw(graph_cancelled(_)).

fault_kind(op(_), unknown_op).
fault_kind(cycle(_), cycle).
fault_kind(duplicate_step_id, duplicate_step_id).
fault_kind(duplicate_bind, duplicate_bind).
fault_kind(dependency(_, _), unknown_dependency).
fault_kind(invalid_args(_, _, _), invalid_args).
fault_kind(capability_denied(_, _), capability_denied).
fault_kind(capability_error(_), capability_denied).
fault_kind(unknown_expert(_), unknown_expert).
fault_kind(invalid_expert_registry(_), invalid_expert_registry).
fault_kind(invalid_budget(_), invalid_budget).
fault_kind(no_json_object, no_json_object).
fault_kind(invalid_json(_), invalid_json).
fault_kind(unsupported_input(_), unsupported_input).
fault_kind(invalid_graph(_), invalid_graph).
fault_kind(not_a_list(_), invalid_structure).
fault_kind(missing_key(_), invalid_structure).
fault_kind(expected_atom(_), invalid_structure).
fault_kind(cyclic_data, invalid_structure).
fault_kind(budget_exceeded(_, _), budget_exceeded).
fault_kind(budget_exceeded(_, _, _), budget_exceeded).
fault_kind(_, invalid_input).

/* -------------------------------------------------------------------------
 * Parse and normalize
 * ---------------------------------------------------------------------- */

plan_graph_parse(Input, Outcome) :-
    catch(plan_graph_parse_(Input, Outcome),
          Exception,
          graph_exception(parse, Exception, Outcome)).

plan_graph_parse_(Input, Outcome) :-
    is_dict(Input),
    !,
    plan_graph_normalize_(Input, Outcome).
plan_graph_parse_(Input, Outcome) :-
    compound(Input),
    !,
    require_acyclic_data(Input),
    plan_graph_normalize_(Input, Outcome).
plan_graph_parse_(Input, Outcome) :-
    text_string(Input, Text),
    !,
    (   extract_json_object(Text, JsonText)
    ->  atom_string(JsonAtom, JsonText),
        catch(atom_json_dict(JsonAtom, Dict, []),
              Exception,
              graph_fault(parse, invalid_json(Exception))),
        plan_graph_normalize_(Dict, Outcome)
    ;   graph_fault(parse, no_json_object)
    ).
plan_graph_parse_(Input, _) :-
    graph_fault(parse, unsupported_input(Input)).

plan_graph_normalize(Input, Outcome) :-
    catch(plan_graph_normalize_(Input, Outcome),
          Exception,
          graph_exception(normalize, Exception, Outcome)).

plan_graph_normalize_(Input, Outcome) :-
    require_acyclic_data(Input),
    normalize_input(Input, Steps, Deps),
    maplist(with_requirements(Deps), Steps, StepsWithReq),
    edges_from_deps(StepsWithReq, Edges),
    Outcome = ok(plan_graph{steps:StepsWithReq, edges:Edges}).

normalize_input(Dict, Steps, Deps) :-
    is_dict(Dict),
    !,
    require_dict_key(Dict, steps, Steps0),
    must_list(Steps0, steps),
    maplist(decode_json_step, Steps0, Steps),
    (   get_dict(depends_on, Dict, Deps0)
    ->  must_list(Deps0, depends_on),
        maplist(decode_json_dep, Deps0, Deps)
    ;   Deps = []
    ).
normalize_input(plan_graph(steps(Steps0)), Steps, Deps) :-
    !,
    must_list(Steps0, steps),
    maplist(decode_term_step, Steps0, Steps),
    Deps = [].
normalize_input(plan_graph(steps(Steps0), depends_on(Deps0)), Steps, Deps) :-
    !,
    must_list(Steps0, steps),
    maplist(decode_term_step, Steps0, Steps),
    must_list(Deps0, depends_on),
    maplist(decode_term_dep, Deps0, Deps).
normalize_input(Input, _, _) :-
    graph_fault(normalize, invalid_graph(Input)).

decode_json_step(Step,
                 graph_step{id:Id, op:Op, args:Args, bind:Bind, requires:[]}) :-
    require_dict_key(Step, id, IdText),
    require_dict_key(Step, op, OpText),
    require_dict_key(Step, args, ArgsDict),
    require_dict_key(Step, bind, BindText),
    require_exact_keys(Step, [id, op, args, bind]),
    atom_string(Id, IdText),
    atom_string(OpAtom, OpText),
    atom_string(Bind, BindText),
    decode_args(OpAtom, ArgsDict, Args, Arity),
    Op = OpAtom/Arity.

decode_json_dep(Dep, dep(step:StepId, requires:Reqs)) :-
    require_dict_key(Dep, step, StepText),
    require_dict_key(Dep, requires, Reqs0),
    require_exact_keys(Dep, [step, requires]),
    atom_string(StepId, StepText),
    must_list(Reqs0, requires),
    maplist(decode_atom, Reqs0, Reqs).

decode_atom(Raw, Atom) :-
    atom_string(Atom, Raw).

decode_term_step(step(Id, OpAtom, ArgsTerm, Bind),
                 graph_step{id:Id, op:Op, args:Args, bind:Bind, requires:[]}) :-
    atom(Id),
    atom(OpAtom),
    atom(Bind),
    require_acyclic_data(ArgsTerm),
    functor(ArgsTerm, OpAtom, Arity),
    !,
    Args = ArgsTerm,
    Op = OpAtom/Arity.
decode_term_step(step(Id, OpAtom, ArgsTerm, Bind),
                 graph_step{id:Id,
                            op:OpAtom/unknown_arity,
                            args:ArgsTerm,
                            bind:Bind,
                            requires:[]}) :-
    require_acyclic_data(ArgsTerm).

decode_term_dep(depends_on(StepId, Reqs), dep(step:StepId, requires:Reqs)) :-
    atom(StepId),
    must_list(Reqs, requires),
    forall(member(Req, Reqs), atom(Req)).

/* JSON arg decoders: closed key sets per op. Unknown ops keep their raw
   args with a key-count arity so the vocabulary check can reject them with
   full identity; known ops with malformed args store an invalid_args
   sentinel that arg-shape validation rejects. Model text is never read as
   a Prolog term. */

decode_args(Op, ArgsDict, Args, Arity) :-
    plan_graph_op(Op/DecodedArity),
    !,
    (   catch(decode_known_args(Op, ArgsDict, Args),
              graph_fault(_, _),
              fail)
    ->  true
    ;   ground_args_data(ArgsDict, GroundArgs),
        Args = invalid_args(Op, GroundArgs)
    ),
    Arity = DecodedArity.
decode_args(_, ArgsDict, Args, Arity) :-
    is_dict(ArgsDict),
    !,
    dict_pairs(ArgsDict, plan_graph_args, Pairs),
    dict_create(Args, plan_graph_args, Pairs),
    length(Pairs, Arity).
decode_args(_, ArgsTerm, ArgsTerm, unknown_arity).

%% Copy the offending args into a fully ground form (JSON dicts carry a
%% fresh variable tag that would make the sentinel non-ground and break
%% ground/1 during validation).
ground_args_data(ArgsDict, Ground) :-
    is_dict(ArgsDict),
    !,
    dict_pairs(ArgsDict, plan_graph_args, Pairs),
    dict_create(Ground, plan_graph_args, Pairs).
ground_args_data(Args, Args).

decode_known_args(sync_remote, D, sync_remote(op(A))) :-
    require_exact_keys(D, [op]),
    require_atom_key(D, op, A).
decode_known_args(index, D, index(scope(S))) :-
    require_exact_keys(D, [scope]),
    require_dict_key(D, scope, Raw),
    decode_scope(Raw, S).
decode_known_args(search, D, search(P, S)) :-
    require_exact_keys(D, [pattern, scope]),
    require_atom_key(D, pattern, P),
    require_dict_key(D, scope, Raw),
    decode_scope(Raw, S).
decode_known_args(locate, D, locate(symbol_ref(Ref))) :-
    require_exact_keys(D, [symbol]),
    require_dict_key(D, symbol, RefDict),
    is_dict(RefDict),
    json_symbol_ref(RefDict, Ref).
decode_known_args(read, D, read(path(A))) :-
    require_exact_keys(D, [source]),
    require_dict_key(D, source, Raw),
    require_path_object(Raw, A).
decode_known_args(diff, D, diff(L, R)) :-
    require_exact_keys(D, [left, right]),
    require_dict_key(D, left, Left),
    require_dict_key(D, right, Right),
    decode_side(Left, L),
    decode_side(Right, R).
decode_known_args(edit, D, edit(T, Rep)) :-
    require_exact_keys(D, [target, replacement]),
    require_dict_key(D, target, Raw),
    decode_side(Raw, T),
    require_atom_key(D, replacement, Rep).
decode_known_args(create, D, create(path(A), literal(L))) :-
    require_exact_keys(D, [path, literal]),
    require_atom_key(D, path, A),
    require_atom_key(D, literal, L).
decode_known_args(delete, D, delete(path(A))) :-
    require_exact_keys(D, [path]),
    require_atom_key(D, path, A).
decode_known_args(run, D, run(command(A))) :-
    require_exact_keys(D, [command]),
    require_atom_key(D, command, A).
decode_known_args(validate, D, validate(spec(fingerprint(A)))) :-
    require_exact_keys(D, [spec]),
    require_dict_key(D, spec, Raw),
    (   is_dict(Raw)
    ->  require_atom_key(Raw, fingerprint, A)
    ;   atom_string(A, Raw)
    ).
decode_known_args(delegate, D, delegate(task(A), caps(Cs))) :-
    require_exact_keys(D, [task, caps]),
    require_atom_key(D, task, A),
    require_dict_key(D, caps, CapsRaw),
    must_list(CapsRaw, caps),
    maplist(decode_json_cap, CapsRaw, Cs).

decode_scope(Raw, all) :-
    (   text_string(Raw, "all")
    ;   Raw == all
    ),
    !.
decode_scope(Raw, path(A)) :-
    require_path_object(Raw, A).

require_path_object(Raw, A) :-
    is_dict(Raw),
    require_exact_keys(Raw, [path]),
    require_atom_key(Raw, path, A).

decode_side(Raw, path(A)) :-
    require_path_object(Raw, A).
decode_side(Raw, ref(symbol_ref(Ref))) :-
    is_dict(Raw),
    require_exact_keys(Raw, [ref]),
    require_dict_key(Raw, ref, RefDict),
    json_symbol_ref(RefDict, Ref).
decode_side(Raw, span(Span)) :-
    is_dict(Raw),
    require_exact_keys(Raw, [span]),
    require_dict_key(Raw, span, SpanDict),
    json_source_span(SpanDict, Span).

%% JSON capability strings are restricted to the closed shape tool(Name)
%% with a plain atom name; nothing is read as a Prolog term.
decode_json_cap(CapText, tool(Name)) :-
    text_string(CapText, CapString),
    string_concat("tool(", Rest, CapString),
    string_length(Rest, Len),
    Len > 1,
    sub_string(Rest, End, 1, 0, ")"),
    Inner is End,
    Inner >= 1,
    sub_string(Rest, 0, Inner, _, NameText),
    \+ sub_string(NameText, _, _, _, "("),
    \+ sub_string(NameText, _, _, _, ")"),
    atom_string(Name, NameText),
    Name \== ''.

json_symbol_ref(Dict, Ref) :-
    require_atom_key(Dict, name, Name),
    Name \== '',
    require_atom_key(Dict, kind, Kind),
    Kind \== '',
    require_exact_keys(Dict, [name, kind, arity, owner, occurrence]),
    (   get_dict(arity, Dict, ArityRaw)
    ->  must_be_nonneg(ArityRaw)
    ;   true
    ),
    (   get_dict(occurrence, Dict, OccRaw)
    ->  atom_string(Occ, OccRaw),
        memberchk(Occ, [definition, reference, any])
    ;   Occ = any
    ),
    optional_ref_keys(Dict, Extra),
    dict_create(Ref, symbol_ref,
                [name-Name, kind-Kind, occurrence-Occ|Extra]).

optional_ref_keys(Dict, Keys) :-
    (   get_dict(arity, Dict, ArityRaw)
    ->  Keys0 = [arity-ArityRaw]
    ;   Keys0 = []
    ),
    (   get_dict(owner, Dict, OwnerRaw)
    ->  atom_string(Owner, OwnerRaw),
        Keys = [owner-Owner|Keys0]
    ;   Keys = Keys0
    ).

json_source_span(Dict, source_span{file:File,
                                    start_byte:Start,
                                    end_byte:End}) :-
    require_atom_key(Dict, file, File),
    require_dict_key(Dict, start_byte, Start),
    require_dict_key(Dict, end_byte, End),
    must_be_nonneg(Start),
    must_be_nonneg(End).

must_be_nonneg(Value) :-
    (   integer(Value),
        Value >= 0
    ->  true
    ;   graph_fault(structure, expected_nonneg_integer(Value))
    ).

with_requirements(Deps, Step0, Step) :-
    get_dict(id, Step0, Id),
    findall(Req,
            (   member(dep(step:DepId, requires:Reqs), Deps),
                DepId == Id,
                member(Req, Reqs)
            ),
            Reqs0),
    sort(Reqs0, Reqs),
    put_dict(requires, Step0, Reqs, Step).

%% Edges are derived from the dependency-merged steps so duplicate or
%% ghost depends_on entries can never produce an inconsistent edge set.
edges_from_deps(Steps, Edges) :-
    include(step_requires_nonempty, Steps, WithDeps),
    maplist(step_to_edge, WithDeps, Edges).

step_requires_nonempty(Step) :-
    get_dict(requires, Step, Reqs),
    Reqs \== [].

step_to_edge(Step, graph_edge{step:StepId, requires:Reqs}) :-
    get_dict(id, Step, StepId),
    get_dict(requires, Step, Reqs).

/* -------------------------------------------------------------------------
 * Validation
 * ---------------------------------------------------------------------- */

plan_graph_validate(Graph0, Caps, Budget0, Outcome) :-
    catch(plan_graph_validate_(Graph0, Caps, Budget0, Outcome),
          Exception,
          graph_exception(validate, Exception, Outcome)).

plan_graph_validate_(Graph0, Caps0, Budget0,
                     ok(validated_plan_graph{graph:Graph,
                                             capabilities:Caps,
                                             budget:Budget,
                                             estimates:Estimates})) :-
    require_acyclic_data(Graph0),
    check_structure(Graph0, Graph),
    !,
    check_duplicates(Graph),
    check_unknown_dependencies(Graph),
    check_acyclic(Graph),
    check_vocabulary(Graph),
    check_arg_shapes(Graph),
    (   catch(capabilities_narrow(Caps0, Caps0, CapsOutcome), _, fail)
    ->  require_caps_outcome(CapsOutcome, Caps)
    ;   graph_fault(capability, capability_error(invalid_capabilities(Caps0)))
    ),
    check_capabilities(Graph, Caps),
    normalize_graph_budget(Budget0, Budget),
    check_budget(Graph, Budget, Estimates),
    !.

check_structure(Graph, Graph) :-
    is_dict(Graph),
    get_dict(steps, Graph, Steps),
    must_list(Steps, steps),
    Steps = [_|_],
    forall(member(Step, Steps),
           (   valid_step_shape(Step)
           ->  true
           ;   graph_fault(structure, invalid_graph(Step))
           )),
    get_dict(edges, Graph, Edges),
    must_list(Edges, edges),
    edges_consistent(Steps, Edges).

valid_step_shape(Step) :-
    is_dict(Step),
    get_dict(id, Step, Id),
    atom(Id),
    get_dict(op, Step, Op),
    op_term(Op),
    get_dict(args, Step, Args),
    ground(Args),
    get_dict(bind, Step, Bind),
    atom(Bind),
    get_dict(requires, Step, Reqs),
    must_list(Reqs, requires),
    forall(member(Req, Reqs), atom(Req)).

op_term(Name/Arity) :-
    atom(Name),
    (   integer(Arity)
    ->  Arity >= 0
    ;   Arity == unknown_arity
    ).

edges_consistent(Steps, Edges) :-
    forall(member(Edge, Edges), edge_consistent(Steps, Edge)),
    forall((   member(Step, Steps),
               get_dict(requires, Step, Reqs),
               Reqs \== []
           ),
           (   get_dict(id, Step, Id),
               memberchk(graph_edge{step:Id, requires:Reqs}, Edges)
           ->  true
           ;   graph_fault(structure, invalid_graph(missing_edge(Id)))
           )).

edge_consistent(Steps, Edge) :-
    is_dict(Edge),
    get_dict(step, Edge, StepId),
    get_dict(requires, Edge, Reqs),
    member(Step, Steps),
    get_dict(id, Step, StepId),
    get_dict(requires, Step, StepReqs),
    StepReqs == Reqs,
    !.
edge_consistent(_, Edge) :-
    graph_fault(structure, invalid_graph(Edge)).

check_duplicates(Graph) :-
    get_dict(steps, Graph, Steps),
    maplist(step_id, Steps, Ids),
    no_duplicates(Ids, duplicate_step_id),
    maplist(step_bind, Steps, Binds),
    no_duplicates(Binds, duplicate_bind).

step_id(Step, Id) :-
    get_dict(id, Step, Id).

step_bind(Step, Bind) :-
    get_dict(bind, Step, Bind).

no_duplicates(Values, Kind) :-
    msort(Values, Sorted),
    (   adjacent_equal(Sorted)
    ->  graph_fault(structure, Kind)
    ;   true
    ).

adjacent_equal([A, A|_]).
adjacent_equal([_|Rest]) :-
    adjacent_equal(Rest).

check_unknown_dependencies(Graph) :-
    get_dict(steps, Graph, Steps),
    maplist(step_id, Steps, Ids),
    forall((   member(Step, Steps),
               get_dict(requires, Step, Reqs),
               member(Req, Reqs)
           ),
           (   memberchk(Req, Ids)
           ->  true
           ;   get_dict(id, Step, StepId),
               graph_fault(structure, dependency(StepId, Req))
           )),
    get_dict(edges, Graph, Edges),
    forall(member(Edge, Edges),
           (   get_dict(step, Edge, EdgeStep),
               memberchk(EdgeStep, Ids)
           ->  true
           ;   graph_fault(structure,
                           unknown_dependency(EdgeStep, depends_on_entry))
           )).

check_acyclic(Graph) :-
    get_dict(steps, Graph, Steps),
    requires_map(Steps, ReqMap),
    maplist(step_id, Steps, Ids),
    (   member(Root, Ids),
        dfs_node(ReqMap, _{}, Root, [Root], Cycle, _),
        Cycle \== none
    ->  graph_fault(structure, cycle(Cycle))
    ;   true
    ).

requires_map(Steps, ReqMap) :-
    foldl(add_requires, Steps, _{}, ReqMap).

add_requires(Step, Map0, Map) :-
    get_dict(id, Step, Id),
    get_dict(requires, Step, Reqs),
    put_dict(Id, Map0, Reqs, Map).

requires_of(ReqMap, Id, Reqs) :-
    (   get_dict(Id, ReqMap, Reqs)
    ->  true
    ;   Reqs = []
    ).

%% Three-color DFS. The color map holds only visiting/done entries;
%% absence means unvisited. Returns the first cycle found as a path (most
%% recent node first) or none, threading the map through.
dfs_node(ReqMap, Colors0, Id, Path, Cycle, Colors) :-
    requires_of(ReqMap, Id, Reqs),
    put_dict(Id, Colors0, visiting, Colors1),
    dfs_deps(ReqMap, Colors1, Reqs, [Id|Path], Id, Cycle, ColorsOut),
    put_dict(Id, ColorsOut, done, Colors).

dfs_deps(_, Colors, [], _, _, none, Colors).
dfs_deps(ReqMap, Colors0, [R|Rs], Path, Self, Cycle, Colors) :-
    (   R == Self
    ->  Cycle = [R|Path],
        Colors = Colors0
    ;   get_dict(R, Colors0, visiting)
    ->  Cycle = [R|Path],
        Colors = Colors0
    ;   get_dict(R, Colors0, done)
    ->  dfs_deps(ReqMap, Colors0, Rs, Path, Self, Cycle, Colors)
    ;   dfs_node(ReqMap, Colors0, R, Path, Cycle1, Colors1),
        (   Cycle1 \== none
        ->  Cycle = Cycle1,
            Colors = Colors1
        ;   dfs_deps(ReqMap, Colors1, Rs, Path, Self, Cycle, Colors)
        )
    ).

check_vocabulary(Graph) :-
    get_dict(steps, Graph, Steps),
    forall(member(Step, Steps), check_step_vocabulary(Step)).

check_step_vocabulary(Step) :-
    get_dict(op, Step, Op),
    (   plan_graph_op(Op)
    ->  true
    ;   graph_fault(vocabulary, op(Op))
    ).

check_arg_shapes(Graph) :-
    get_dict(steps, Graph, Steps),
    forall(member(Step, Steps),
           (   get_dict(op, Step, Op),
               get_dict(args, Step, Args),
               get_dict(id, Step, StepId),
               (   args_valid(Op, Args)
               ->  true
               ;   graph_fault(validate, invalid_args(StepId, Op, Args))
               )
           )).

args_valid(sync_remote/1, sync_remote(op(A))) :-
    atom(A).
args_valid(index/1, index(scope(S))) :-
    scope_valid(S).
args_valid(search/2, search(P, S)) :-
    atom(P),
    scope_valid(S).
args_valid(locate/1, locate(symbol_ref(Ref))) :-
    plan_graph_symbol_ref_valid(Ref).
args_valid(read/1, read(path(A))) :-
    atom(A).
args_valid(diff/2, diff(L, R)) :-
    side_valid(L),
    side_valid(R).
args_valid(edit/2, edit(T, Rep)) :-
    side_valid(T),
    atom(Rep).
args_valid(create/2, create(path(A), literal(L))) :-
    atom(A),
    atom(L).
args_valid(delete/1, delete(path(A))) :-
    atom(A).
args_valid(run/1, run(command(A))) :-
    atom(A).
args_valid(validate/1, validate(spec(fingerprint(A)))) :-
    atom(A).
args_valid(delegate/2, delegate(task(A), caps(Cs))) :-
    atom(A),
    is_list(Cs).

scope_valid(all).
scope_valid(path(A)) :-
    atom(A).

side_valid(path(A)) :-
    atom(A).
side_valid(ref(symbol_ref(Ref))) :-
    plan_graph_symbol_ref_valid(Ref).
side_valid(span(Span)) :-
    plan_graph_source_span_valid(Span).

check_capabilities(Graph, Caps) :-
    get_dict(steps, Graph, Steps),
    forall(member(Step, Steps), check_step_capability(Step, Caps)).

check_step_capability(Step, Caps) :-
    get_dict(op, Step, Op),
    plan_capability_required(Op, Required),
    (   capabilities_narrow(Caps, [Required], ok(_))
    ->  get_dict(args, Step, Args),
        check_delegate_narrowing(Op, Args, Caps)
    ;   graph_fault(capability, capability_denied(Op, Required))
    ).

check_delegate_narrowing(delegate/2, delegate(_, caps(Child)), Caps) :-
    !,
    (   capabilities_normalize(Child, ok(_)),
        capabilities_narrow(Caps, Child, ok(_))
    ->  true
    ;   graph_fault(capability,
                    capability_denied(delegate/2, narrowing_violation(Child)))
    ).
check_delegate_narrowing(_, _, _).

check_budget(Graph, Budget, estimates{steps:StepCount,
                                      tool_calls:StepCount,
                                      model_calls:ValidateCount}) :-
    get_dict(steps, Graph, Steps),
    length(Steps, StepCount),
    findall(ValidateStep,
            (   member(ValidateStep, Steps),
                get_dict(op, ValidateStep, validate/1)
            ),
            ValidateSteps),
    length(ValidateSteps, ValidateCount),
    budget_within(Budget, max_steps, StepCount),
    budget_within(Budget, max_total_tool_calls, StepCount),
    budget_within(Budget, max_total_model_calls, ValidateCount).

budget_within(Budget, Key, Count) :-
    get_dict(Key, Budget, Limit),
    (   Count =< Limit
    ->  true
    ;   graph_fault(budget, budget_exceeded(Key, Count, Limit))
    ).

normalize_graph_budget(default, Budget) :-
    !,
    default_plan_graph_budget(Budget).
normalize_graph_budget(Overlay, Budget) :-
    is_dict(Overlay),
    !,
    default_plan_graph_budget(Default),
    put_dict(Overlay, Default, Budget).
normalize_graph_budget(Other, _) :-
    graph_fault(validate, invalid_budget(Other)).

/* -------------------------------------------------------------------------
 * Ready-step scheduling
 * ---------------------------------------------------------------------- */

plan_graph_ready(Graph, State, StepId) :-
    get_dict(steps, Graph, Steps),
    member(Step, Steps),
    get_dict(id, Step, StepId),
    get_dict(status, State, Statuses),
    step_status(Statuses, StepId, pending),
    get_dict(requires, Step, Reqs),
    forall(member(Req, Reqs),
           (   get_dict(Req, Statuses, ReqStatus),
               ReqStatus == completed
           )).

step_status(Statuses, Id, Status) :-
    (   get_dict(Id, Statuses, S)
    ->  S == Status
    ;   Status == pending
    ).

/* -------------------------------------------------------------------------
 * Execution
 * ---------------------------------------------------------------------- */

plan_graph_execute(GraphInput, Caps, Options, Inputs, Outcome) :-
    catch(plan_graph_execute_(GraphInput, Caps, Options, Inputs, Outcome),
          Exception,
          graph_exception(execute, Exception, Outcome)).

plan_graph_execute_(GraphInput, Caps, Options, Inputs, Outcome) :-
    must_list(Options, options),
    is_dict(Inputs),
    graph_option(experts, Options, [], Experts),
    validate_expert_registry(Experts),
    graph_option(budget, Options, default, BudgetArg),
    plan_graph_parse(GraphInput, NormOutcome),
    require_graph_outcome(NormOutcome, Graph),
    plan_graph_validate_(Graph, Caps, BudgetArg, ValidOutcome),
    require_graph_outcome(ValidOutcome, Validated),
    get_dict(graph, Validated, ValidGraph),
    get_dict(budget, Validated, Budget),
    preflight_experts(ValidGraph, Experts),
    graph_option(cancellation_token, Options, none, Token),
    setup_call_cleanup(
        register_worker(Token),
        (   default_plan_budget(DefaultPlanBudget),
            initial_graph_state(ValidGraph, State0),
            aggregate_from_budget(Budget, Agg0),
            get_time(Started),
            Deadline is Started + Budget.time_limit,
            run_loop(ValidGraph, Experts, Inputs, Token, Deadline,
                     DefaultPlanBudget, State0, Agg0, State, Agg,
                     Status, Reason),
            Outcome = ok(graph_result{status:Status,
                                      reason:Reason,
                                      state:State,
                                      budget_remaining:Agg})
        ),
        unregister_worker(Token)).

validate_expert_registry(Registry) :-
    valid_expert_registry(Registry),
    !.
validate_expert_registry(Other) :-
    graph_fault(preflight, invalid_expert_registry(Other)).

valid_expert_registry([]).
valid_expert_registry([expert(Name, Handler)|Rest]) :-
    atom(Name),
    callable(Handler),
    valid_expert_registry(Rest).

%% Fail-closed preflight: every validated op must resolve to a
%% host-supplied expert closure BEFORE the first step executes.
preflight_experts(Graph, Experts) :-
    get_dict(steps, Graph, Steps),
    forall(member(Step, Steps),
           (   get_dict(op, Step, Op),
               plan_capability_required(Op, tool(ToolName)),
               (   memberchk(expert(ToolName, _), Experts)
               ->  true
               ;   graph_fault(preflight, unknown_expert(ToolName))
               )
           )).

initial_graph_state(_Graph, graph_state{status:status_map{},
                                        results:results_map{},
                                        sequence:[]}).

aggregate_from_budget(Budget,
                      graph_agg{steps:Budget.max_steps,
                                tool_calls:Budget.max_total_tool_calls,
                                model_calls:Budget.max_total_model_calls,
                                context_ops:Budget.max_total_context_ops,
                                output_bytes:Budget.max_total_output_bytes}).

step_budget(Default, Agg, Deadline,
            plan_budget{max_steps:Default.max_steps,
                        max_depth:Default.max_depth,
                        max_parallel:Default.max_parallel,
                        max_model_calls:ModelCalls,
                        max_tool_calls:ToolCalls,
                        max_context_ops:ContextOps,
                        max_output_bytes:OutputBytes,
                        time_limit:TimeLimit}) :-
    ToolCalls is min(Default.max_tool_calls, Agg.tool_calls),
    ModelCalls is min(Default.max_model_calls, Agg.model_calls),
    ContextOps is min(Default.max_context_ops, Agg.context_ops),
    OutputBytes is min(Default.max_output_bytes, Agg.output_bytes),
    get_time(Now),
    RemainingTime is max(0.5, Deadline - Now),
    TimeLimit is min(Default.time_limit, RemainingTime).

run_loop(Graph, Experts, Inputs, Token, Deadline, DefaultPlanBudget,
         State0, Agg0, State, Agg, Status, Reason) :-
    (   token_cancelled(Token)
    ->  abort_graph(Graph, State0, _),
        throw(error(rlm_cancelled(Token),
                    context(plan_graph_cancelled)))
    ;   first_ready(Graph, State0, StepId)
    ->  admit_step(Graph, StepId, Experts, Inputs, Token, Deadline,
                   DefaultPlanBudget, State0, Agg0, State, Agg,
                   Status, Reason)
    ;   finish_graph(Graph, State0, State),
        graph_overall_status(State, Status),
        default_reason(Status, Reason),
        Agg = Agg0
    ).

first_ready(Graph, State, StepId) :-
    plan_graph_ready(Graph, State, StepId),
    !.

%% Every step's desugared plan needs at least one tool call and a
%% non-empty output allowance for its result. An unfundable step means
%% the aggregate is exhausted: abort with reason budget, never hand out
%% a zero-valued budget field.
fundable(Agg) :-
    get_dict(tool_calls, Agg, ToolCalls),
    ToolCalls >= 1,
    get_dict(output_bytes, Agg, OutputBytes),
    OutputBytes >= 1.

admit_step(Graph, StepId, Experts, Inputs, Token, Deadline,
           DefaultPlanBudget, State0, Agg0, State, Agg, Status, Reason) :-
    (   \+ fundable(Agg0)
    ->  abort_graph(Graph, State0, Aborted),
        State = Aborted,
        Agg = Agg0,
        Status = aborted,
        Reason = budget
    ;   get_time(Now),
        Now >= Deadline
    ->  abort_graph(Graph, State0, Aborted),
        State = Aborted,
        Agg = Agg0,
        Status = aborted,
        Reason = time
    ;   get_dict(steps, Graph, Steps),
        member(Step, Steps),
        get_dict(id, Step, StepId),
        !,
        execute_one(Graph, Step, Experts, Inputs, Deadline,
                    DefaultPlanBudget, State0, Agg0, Kind, State1, Agg1),
        (   Kind == aborted_budget
        ->  abort_graph(Graph, State1, Aborted),
            State = Aborted,
            Agg = Agg1,
            Status = aborted,
            Reason = budget
        ;   run_loop(Graph, Experts, Inputs, Token, Deadline,
                     DefaultPlanBudget, State1, Agg1, State, Agg,
                     Status, Reason)
        )
    ).

execute_one(Graph, Step, Experts, Inputs, Deadline, DefaultPlanBudget,
            State0, Agg0, Kind, State, Agg) :-
    get_dict(id, Step, StepId),
    get_dict(op, Step, Op),
    get_dict(args, Step, Args),
    get_dict(bind, Step, Bind),
    plan_capability_required(Op, tool(ToolName)),
    mark_step(State0, StepId, running, StateRunning),
    step_budget(DefaultPlanBudget, Agg0, Deadline, StepBudget),
    Desugared = plan([tool(ToolName, literal(Args), Bind),
                      final(var(Bind))]),
    (   catch(step_execute(Desugared, ToolName, Experts, Inputs,
                           StepBudget, StepOutcome),
              Throw,
              (                     (   step_throw(Throw, exception(Cancellation))
                  ->                        StepOutcome = exception(Cancellation)
                  ;                         StepOutcome = error(plan_error{phase:execute,
                                                     kind:expert_exception,
                                                     detail:exception(Throw)})
                  )
              ))
    ->  classify_step(Graph, StepId, StepOutcome, StepBudget,
                      StateRunning, Agg0, Kind, State, Agg)
    ;   throw(graph_fault(internal, step_dispatch_failed))
    ).

step_execute(Desugared, ToolName, Experts, Inputs, StepBudget,
             StepOutcome) :-
    plan_validate(Desugared, [tool(ToolName)], StepBudget,
                  ValidateOutcome),
    (   ValidateOutcome = ok(ValidatedPlan)
    ->  (   memberchk(expert(ToolName, Handler), Experts)
        ->  (   plan_execute(ValidatedPlan,
                             [tools([tool(ToolName, Handler)])],
                             Inputs,
                             StepOutcome)
            ->  true
            ;   StepOutcome = error(plan_error{phase:execute,
                                               kind:plan_failed,
                                               detail:tool(ToolName)})
            )
        ;   StepOutcome = error(plan_error{phase:preflight,
                                           kind:unknown_tool,
                                           detail:tool(ToolName)})
        )
    ;   ValidateOutcome = error(Error)
    ->  StepOutcome = error(Error)
    ).

%% Cancellation is never an ordinary step failure: abort and rethrow the
%% exact token so the awaiting facade observes it.
step_throw(error(rlm_cancelled(Token), Context),
           exception(error(rlm_cancelled(Token), Context))).
step_throw(graph_cancelled(Token),
           exception(error(rlm_cancelled(Token),
                           context(plan_graph_signal)))).

classify_step(Graph, _,
              exception(Cancellation),
              _, StateRunning, Agg0, _, State, Agg) :-
    cancellation_throw(Cancellation),
    !,
    abort_graph(Graph, StateRunning, State),
    Agg = Agg0,
    Cancellation = error(rlm_cancelled(Token), Context),
    throw(error(rlm_cancelled(Token), Context)).
classify_step(_, StepId,
              ok(PlanResult),
              StepBudget, StateRunning, Agg0, completed, State, Agg) :-
    !,
    mark_step(StateRunning, StepId, completed, State1),
    record_step_result(State1, StepId,
                       step_result{step:StepId,
                                   status:completed,
                                   outcome:PlanResult},
                       State),
    get_dict(budget_remaining, PlanResult, Remaining),
    charge_aggregate(Agg0, StepBudget, Remaining, Agg).
classify_step(_, _,
              error(StepError),
              _, StateRunning, Agg0, aborted_budget, StateRunning, Agg0) :-
    budget_exhaustion(StepError),
    !.
classify_step(Graph, StepId,
              error(StepError),
              _, StateRunning, Agg0, failed, State, Agg0) :-
    fail_step(Graph, StepId, error(StepError), StateRunning, State).

%% A step whose plan hit its (derived) budget means the graph-level
%% aggregate can no longer fund the remaining work: abort, never silently
%% continue with a fresh budget.
budget_exhaustion(StepError) :-
    is_dict(StepError),
    (   get_dict(kind, StepError, budget_exhausted)
    ;   get_dict(kind, StepError, budget_exceeded),
        get_dict(phase, StepError, budget)
    ).
/* State helpers --------------------------------------------------------- */

mark_step(State0, StepId, Status, State) :-
    get_dict(status, State0, Statuses),
    put_dict(StepId, Statuses, Status, Statuses1),
    put_dict(status, State0, Statuses1, State).

record_step_result(State0, StepId, Result, State) :-
    get_dict(results, State0, Results),
    put_dict(StepId, Results, Result, Results1),
    put_dict(results, State0, Results1, State1),
    get_dict(sequence, State1, Sequence0),
    append(Sequence0, [StepId], Sequence1),
    put_dict(sequence, State1, Sequence1, State).

charge_aggregate(Agg0, StepBudget, Remaining, Agg) :-
    ToolConsumed is max(0, StepBudget.max_tool_calls - Remaining.tool_calls),
    ModelConsumed is max(0, StepBudget.max_model_calls - Remaining.model_calls),
    ContextConsumed is max(0, StepBudget.max_context_ops - Remaining.context_ops),
    OutputConsumed is max(0, StepBudget.max_output_bytes - Remaining.output_bytes),
    get_dict(tool_calls, Agg0, T0),
    get_dict(model_calls, Agg0, M0),
    get_dict(context_ops, Agg0, C0),
    get_dict(output_bytes, Agg0, O0),
    get_dict(steps, Agg0, S0),
    T1 is max(0, T0 - ToolConsumed),
    M1 is max(0, M0 - ModelConsumed),
    C1 is max(0, C0 - ContextConsumed),
    O1 is max(0, O0 - OutputConsumed),
    S1 is max(0, S0 - 1),
    Agg = graph_agg{steps:S1,
                    tool_calls:T1,
                    model_calls:M1,
                    context_ops:C1,
                    output_bytes:O1}.

fail_step(Graph, StepId, StepOutcome, State0, State) :-
    mark_step(State0, StepId, failed, State1),
    record_step_result(State1, StepId,
                       step_result{step:StepId,
                                   status:failed,
                                   outcome:StepOutcome},
                       State2),
    get_dict(steps, Graph, Steps),
    dependents_closure(Steps, StepId, Dependents),
    foldl(block_one, Dependents, State2, State).

block_one(Dependent, State0, State) :-
    get_dict(status, State0, Statuses),
    (   get_dict(Dependent, Statuses, pending)
    ->  put_dict(Dependent, Statuses, blocked, Statuses1),
        put_dict(status, State0, Statuses1, State)
    ;   State = State0
    ).

dependents_closure(Steps, Seed, Dependents) :-
    expand_dependents(Steps, [Seed], [Seed], ReverseAcc),
    reverse(ReverseAcc, [Seed|Dependents]).

expand_dependents(_, [], Seen, Seen) :-
    !.
expand_dependents(Steps, [Id|Work], Seen0, Acc) :-
    findall(D,
            (   member(S, Steps),
                get_dict(id, S, D),
                get_dict(requires, S, Reqs),
                memberchk(Id, Reqs),
                \+ memberchk(D, Seen0)
            ),
            Ds),
    append(Ds, Work, Work1),
    append(Ds, Seen0, Seen1),
    expand_dependents(Steps, Work1, Seen1, Acc).

abort_graph(Graph, State0, State) :-
    get_dict(steps, Graph, Steps),
    foldl(abort_one, Steps, State0, State).

abort_one(Step, State0, State) :-
    get_dict(id, Step, Id),
    get_dict(status, State0, Statuses),
    (   get_dict(Id, Statuses, completed)
    ->  State = State0
    ;   get_dict(Id, Statuses, failed)
    ->  State = State0
    ;   put_dict(Id, Statuses, abandoned, Statuses1),
        put_dict(status, State0, Statuses1, State)
    ).

finish_graph(Graph, State0, State) :-
    get_dict(steps, Graph, Steps),
    foldl(finish_one, Steps, State0, State).

finish_one(Step, State0, State) :-
    get_dict(id, Step, Id),
    get_dict(status, State0, Statuses),
    (   get_dict(Id, Statuses, _)
    ->  State = State0
    ;   put_dict(Id, Statuses, blocked, Statuses1),
        put_dict(status, State0, Statuses1, State)
    ).

graph_overall_status(State, failed) :-
    get_dict(status, State, Statuses),
    dict_keys(Statuses, Keys),
    member(Key, Keys),
    get_dict(Key, Statuses, S),
    memberchk(S, [failed, blocked]),
    !.
graph_overall_status(_, completed).

default_reason(completed, none).
default_reason(failed, none).

/* Cancellation API (mirrors rlm_graph token plumbing) -------------------- */

plan_graph_cancellation_token(Token) :-
    uuid(Id, [version(4)]),
    atom_concat(plan_graph_cancel_, Id, Token),
    with_mutex(plan_graph_cancel,
               (   retractall(plan_graph_cancel_state(Token, _)),
                   assertz(plan_graph_cancel_state(Token, active)) )).

plan_graph_cancel(Token) :-
    with_mutex(plan_graph_cancel,
               (   retractall(plan_graph_cancel_state(Token, _)),
                   assertz(plan_graph_cancel_state(Token, cancelled)),
                   findall(Thread,
                           plan_graph_cancel_thread(Token, Thread),
                           Threads)
               )),
    forall(member(Thread, Threads),
           catch(thread_signal(Thread, throw(graph_cancelled(Token))),
                 _,
                 true)).

token_cancelled(Token) :-
    Token \== none,
    plan_graph_cancel_state(Token, cancelled).

register_worker(none) :-
    !.
register_worker(Token) :-
    thread_self(Self),
    with_mutex(plan_graph_cancel,
               (   retractall(plan_graph_cancel_thread(Token, _)),
                   assertz(plan_graph_cancel_thread(Token, Self)) )).

unregister_worker(none) :-
    !.
unregister_worker(Token) :-
    retractall(plan_graph_cancel_thread(Token, _)).

/* Async / sync facade ----------------------------------------------------- */

plan_graph_run(GraphInput, Caps, Options, Inputs, Outcome) :-
    plan_graph_run_async(GraphInput, Caps, [inputs(Inputs)|Options],
                         Future),
    rlm_async:rlm_future_await(Future, Outcome).

plan_graph_run_async(GraphInput, Caps, Options, Future) :-
    must_list(Options, options),
    graph_option(graph_id, Options, auto, GraphIdSel),
    graph_run_id(GraphIdSel, GraphId),
    graph_option(run_id, Options, auto, RunIdSel),
    graph_run_id(RunIdSel, RunId),
    graph_option(trace_id, Options, none, TraceId),
    graph_option(session_id, Options, none, SessionId),
    graph_option(inputs, Options, inputs{}, Inputs),
    Metadata = async_metadata{operation:plan_graph_run,
                              graph_id:GraphId,
                              graph_run_id:RunId,
                              trace_id:TraceId,
                              session_id:SessionId},
    rlm_async:rlm_async_submit(
        rlm_plan_graph:plan_graph_execute(GraphInput, Caps, Options, Inputs),
        Metadata,
        Future).

graph_run_id(auto, Id) :-
    !,
    uuid(U, [version(4)]),
    atom_concat(plan_graph_, U, Id).
graph_run_id(Id, Id) :-
    atom(Id).

/* symbol_ref / source_span contract --------------------------------------- */

plan_graph_symbol_ref_valid(Ref) :-
    is_dict(Ref),
    get_dict(name, Ref, Name),
    atom(Name),
    Name \== '',
    get_dict(kind, Ref, Kind),
    atom(Kind),
    Kind \== '',
    dict_keys(Ref, Keys),
    forall(member(Key, Keys),
           memberchk(Key, [name, kind, arity, owner, occurrence])),
    (   get_dict(arity, Ref, Arity)
    ->  integer(Arity),
        Arity >= 0
    ;   true
    ),
    (   get_dict(owner, Ref, Owner)
    ->  atom(Owner)
    ;   true
    ),
    (   get_dict(occurrence, Ref, Occ)
    ->  memberchk(Occ, [definition, reference, any])
    ;   true
    ).

plan_graph_source_span_valid(Span) :-
    is_dict(Span),
    dict_keys(Span, Keys),
    forall(member(Key, Keys), memberchk(Key, [file, start_byte, end_byte])),
    get_dict(file, Span, File),
    atom(File),
    get_dict(start_byte, Span, Start),
    integer(Start),
    Start >= 0,
    get_dict(end_byte, Span, End),
    integer(End),
    End >= 0,
    Start =< End.

%% Bounded resolver over host-supplied index facts. No filesystem, no
%% parser, no extraction: extraction remains owned by issues #96-#98.
plan_graph_resolve_symbol(Index, Ref, Outcome) :-
    (   plan_graph_symbol_ref_valid(Ref)
    ->  resolve_supported(Index, Ref, Outcome)
    ;   Outcome = error(plan_graph_error{phase:resolve,
                                         kind:invalid_ref,
                                         detail:symbol_ref(Ref)})
    ).

resolve_supported(symbol_index{kinds:Kinds, definitions:Definitions},
                  Ref, Outcome) :-
    get_dict(kind, Ref, Kind),
    (   memberchk(Kind, Kinds)
    ->  findall(Span-Prov,
                (   member(symbol_definition(DefRef, Span, Prov),
                           Definitions),
                    ref_matches(Ref, DefRef)
                ),
                Matches),
        maplist(match_span, Matches, Spans),
        sort(Spans, DistinctSpans),
        (   DistinctSpans == []
        ->  Outcome = error(plan_graph_error{phase:resolve,
                                             kind:unresolved,
                                             detail:symbol_ref(Ref)})
        ;   DistinctSpans = [Span]
        ->  Matches = [_-Prov|_],
            Outcome = ok(symbol_binding{span:Span, provenance:Prov})
        ;   Outcome = error(plan_graph_error{phase:resolve,
                                             kind:ambiguous,
                                             detail:spans(DistinctSpans)})
        )
    ;   Outcome = error(plan_graph_error{phase:resolve,
                                         kind:unsupported,
                                         detail:symbol_ref(Ref)})
    ).

%% A definition matches when every key present in the query ref is present
%% in the definition with an equal value. Query occurrence any is a
%% wildcard.
ref_matches(Query, DefRef) :-
    dict_keys(Query, Keys),
    forall(member(Key, Keys),
           (   Key == occurrence,
               get_dict(occurrence, Query, any)
           ->  true
           ;   get_dict(Key, Query, Value),
               get_dict(Key, DefRef, Value)
           )).

match_span(Span-_, Span).

/* JSON extraction (mirrors rlm_plan discipline) --------------------------- */

text_string(Value, String) :-
    string(Value),
    !,
    String = Value.
text_string(Value, String) :-
    atom(Value),
    !,
    atom_string(Value, String).

extract_json_object(Text, Json) :-
    sub_string(Text, Start, _, _, "{"),
    !,
    string_length(Text, Length),
    between_last(Length, 0, End),
    sub_string(Text, End, 1, _, "}"),
    End >= Start,
    JsonLength is End - Start + 1,
    sub_string(Text, Start, JsonLength, _, Json).

between_last(High, Low, Value) :-
    between(Low, High, Offset),
    Value is High - Offset.

