:- module(plan_native_ops_test,
          [ native_adapter/3
          ]).

/* D6-11 plan-native deterministic mutations (recorded verbatim in
   docs/research/spec-plan-authority.md §6.3): the closed set
   sync_remote/1, run/1, index/1, delete/1 executes at the plan layer
   through the canonical boundary (schema -> capability -> authority ->
   durable effect admission -> dispatch -> observe), exactly like a
   tool/3 step — never ambient shell/git access in plan code. The ops
   are excluded from expert mapping and from the future expert registry;
   edit/2 and create/2 remain write-expert-owned per §8.3 and
   deliberately have no plan-native path here.

   These tests exercise the merged plan layer exactly as the plan-graph
   reconciliation will: the canonical desugared form
   plan([tool(Op, literal(Args), Bind), final(var(Bind))]) runs through
   the rlm_plan validate/execute ABIs, and the host plan-native handler
   routes through the canonical rlm_tool registry, which owns schema
   validation, capability re-check, authority, durable effect admission,
   dispatch, and observation. */

:- use_module('../prolog/rlm_plan').
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_authority').

/* The D6-11 closed set with the desugared §6.2 arg terms. The set is
   closed: exactly these four ops, no edit/2, no create/2. */
plan_native_op_case(sync_remote, sync_remote(op(push))).
plan_native_op_case(run, run(command(argv([echo, hi])))).
plan_native_op_case(index, index(scope(all))).
plan_native_op_case(delete, delete(path('scratch.txt'))).

plan_native_set_exactly_four :-
    findall(Op, plan_native_op_case(Op, _), Ops),
    length(Ops, 4),
    \+ member(edit, Ops),
    \+ member(create, Ops).

/* Desugared plan form for a plan-native op, exactly as the plan-graph
   executor produces it. */
plan_native_desugared(Op, Args, Bind,
                      plan([tool(Op, literal(Args), Bind),
                            final(var(Bind))])).

/* Externally observable dispatch counter, independent of the effect
   ledger: duplicate plan-native execution is detectable through this
   counter, not through the durable store. */
:- dynamic native_dispatch/2.
:- dynamic native_trace/2.

reset_native_observations :-
    retractall(native_dispatch(_, _)),
    retractall(native_trace(_, _)).

record_native_dispatch(Op, Detail) :-
    assertz(native_dispatch(Op, Detail)).

native_dispatch_count(Op, Count) :-
    aggregate_all(count, native_dispatch(Op, _), Count).

record_native_trace(Op, Trace) :-
    (   is_dict(Trace),
        get_dict(fingerprint, Trace, Fingerprint)
    ->  assertz(native_trace(Op, Fingerprint))
    ;   assertz(native_trace(Op, none))
    ).

/* Canonical boundary: trusted host adapters, one per plan-native op.
   Adapter bodies are static code-owned behavior — model data never
   reaches call/1 here. */
native_adapter_clause(sync_remote, sync_remote_adapter).
native_adapter_clause(run, run_adapter).
native_adapter_clause(index, index_adapter).
native_adapter_clause(delete, delete_adapter).

sync_remote_adapter(json{op:Op}, json{synced:Op}) :-
    record_native_dispatch(sync_remote, network_sync(Op)).

run_adapter(json{argv:Argv}, json{status:"ran"}) :-
    record_native_dispatch(run, process_argv(Argv)).

index_adapter(json{scope:Scope}, json{indexed:Scope}) :-
    record_native_dispatch(index, index_scope(Scope)).

delete_adapter(json{path:Path}, json{deleted:Path}) :-
    record_native_dispatch(delete, file_delete(Path)).

/* Host schema per plan-native op. Registry effect classes carry the §6.2
   classification onto the closed host vocabulary (network_write /
   process / write for the external-effect ops, read for the observation
   op). */
native_schema(sync_remote,
              tool_schema{name:sync_remote,
                          description:"plan-native remote sync adapter fixture",
                          capability:tool(sync_remote),
                          effect:network_write,
                          arguments:_{type:object,
                                      required:[op],
                                      additional_properties:false,
                                      properties:_{op:_{type:string}}},
                          result:_{type:object,
                                   required:[synced],
                                   additional_properties:false,
                                   properties:_{synced:_{type:string}}},
                          limits:_{time_limit:2.0, max_output_bytes:4096}}).
native_schema(run,
              tool_schema{name:run,
                          description:"plan-native process adapter fixture",
                          capability:tool(run),
                          effect:process,
                          arguments:_{type:object,
                                      required:[argv],
                                      additional_properties:false,
                                      properties:_{argv:_{type:list,
                                                          items:_{type:string}}}},
                          result:_{type:object,
                                   required:[status],
                                   additional_properties:false,
                                   properties:_{status:_{type:string}}},
                          limits:_{time_limit:2.0, max_output_bytes:4096}}).
native_schema(index,
              tool_schema{name:index,
                          description:"plan-native index observation fixture",
                          capability:tool(index),
                          effect:read,
                          arguments:_{type:object,
                                      required:[scope],
                                      additional_properties:false,
                                      properties:_{scope:_{type:string}}},
                          result:_{type:object,
                                   required:[indexed],
                                   additional_properties:false,
                                   properties:_{indexed:_{type:string}}},
                          limits:_{time_limit:2.0, max_output_bytes:4096}}).
native_schema(delete,
              tool_schema{name:delete,
                          description:"plan-native delete adapter fixture",
                          capability:tool(delete),
                          effect:write,
                          arguments:_{type:object,
                                      required:[path],
                                      additional_properties:false,
                                      properties:_{path:_{type:string}}},
                          result:_{type:object,
                                   required:[deleted],
                                   additional_properties:false,
                                   properties:_{deleted:_{type:string}}},
                          limits:_{time_limit:2.0, max_output_bytes:4096}}).

native_registry(Registry) :-
    tool_registry_create(Registry),
    forall(native_schema(Op, Schema),
           tool_register(Registry, Schema,
                         plan_native_ops_test:native_adapter(Op),
                         ok(_))).

% Module-qualified so the closure atom is visible from rlm_plan's trusted
% tool invocation path (mirrors production host handler registration).
native_adapter(Op, Args, Result) :-
    native_adapter_clause(Op, Adapter),
    call(Adapter, Args, Result).

/* Desugared §6.2 arg term -> canonical registry args. Trusted host
   translation on the plan-native path; the plan interpreter performs no
   translation of its own and gains no ambient authority. */
native_registry_args(sync_remote, sync_remote(op(Op)), json{op:Op}).
native_registry_args(run, run(command(argv(Argv))), json{argv:Argv}).
native_registry_args(index, index(scope(Scope)), json{scope:Scope}).
native_registry_args(delete, delete(path(Path)), json{path:Path}).

/* The plan-native handler the plan layer invokes for the desugared
   tool/3 step: a host closure that routes through the canonical
   rlm_tool invoke, so schema, capability, authority, durable admission,
   dispatch, and observation all happen at the canonical boundary. The
   plan binding carries the observed payload; the canonical trace stays
   on the tool layer. */
native_plan_handler(Context, Registry, Op, OpArgs, ToolResult) :-
    native_registry_args(Op, OpArgs, RegistryArgs),
    catch(native_invoke(Context, Registry, Op, RegistryArgs, ToolResult),
          Exception,
          ( record_native_trace(Op, exception(Exception)),
            ToolResult = error(plan_error{phase:execute,
                                          kind:native_invocation_exception,
                                          tool:Op,
                                          message:"plan-native adapter raised"})
          )).

native_invoke(Context, Registry, Op, RegistryArgs, ToolResult) :-
    tool_invoke(Registry, [tool(Op)], Op, RegistryArgs,
                [authority_context(Context)], Outcome, Trace),
    record_native_trace(Op, Trace),
    native_tool_result(Outcome, ToolResult).

native_tool_result(ok(tool_execution{trace:_, value:Payload}), ok(Payload)) :- !.
native_tool_result(approval_required(Pending),
                   error(approval_required(Pending))) :- !.
native_tool_result(error(Error), error(Error)).

dangerous_context(Context) :-
    Context = session(plan_native_ops_dangerous),
    rlm_set_authority(Context, dangerous, ok(_)).

cleanup_context(Context) :-
    catch(rlm_authority_clear(Context), _, true).

setup_effect_store(File) :-
    tmp_file(rlm_plan_native_ops, File),
    rlm_effect_store_open(File),
    reset_native_observations.

cleanup_effect_store(File) :-
    catch(rlm_effect_store_close, _, true),
    catch(delete_file(File), _, true),
    reset_native_observations.

run_native_plan(Registry, Context, Op, Desugared, Expected) :-
    plan_run(Desugared, [tool(Op)],
             [tools([tool(Op,
                         plan_native_ops_test:native_plan_handler(Context,
                                            Registry, Op))])],
             _{}, ok(Result)),
    get_dict(value, Result, Expected).

cross_store_fingerprint_is_stable(Op, Args, Fingerprint) :-
    setup_call_cleanup(
        ( rlm_effect_store_close,
          tmp_file(rlm_plan_native_ops_fresh, Fresh),
          rlm_effect_store_open(Fresh) ),
        ( dangerous_context(Context),
          native_registry(Registry),
          plan_native_desugared(Op, Args, native_bind, Desugared),
          run_native_plan(Registry, Context, Op, Desugared, ok(_)),
          rlm_effect_attempts(_, _, [FreshAttempt]),
          assertion(FreshAttempt.fingerprint == Fingerprint),
          cleanup_context(Context),
          tool_registry_destroy(Registry) ),
        ( rlm_effect_store_close,
          catch(delete_file(Fresh), _, true) )).

:- begin_tests(rlm_plan_native_ops).

/* 1. The D6-11 set is closed: exactly the four ops, never edit/create. */
test(plan_native_set_is_closed) :-
    plan_native_set_exactly_four.

/* 2. An ungranted capability fails closed at the plan layer: whole-plan
   validation rejects the step before any dispatch, and the external
   adapter counter proves no effect ran. */
test(plan_native_ungranted_capability_fails_closed,
     [forall(plan_native_op_case(Op, Args))]) :-
    setup_call_cleanup(
        setup_effect_store(_),
        ( dangerous_context(Context),
          native_registry(Registry),
          plan_native_desugared(Op, Args, native_bind, Desugared),
          plan_run(Desugared, [tool(other)],
                   [tools([tool(Op,
                               plan_native_ops_test:native_plan_handler(
                                   Context, Registry, Op))])],
                   _{}, error(Error)),
          assertion(Error.kind == capability_denied),
          native_dispatch_count(Op, ZeroDispatches),
          assertion(ZeroDispatches =:= 0),
          cleanup_context(Context),
          tool_registry_destroy(Registry) ),
        cleanup_effect_store(_)).

/* External-effect plan-native ops (§6.2 classification) with their
   desugared arg terms. */
plan_native_external_effect_op(sync_remote, sync_remote(op(push))).
plan_native_external_effect_op(run, run(command(argv([echo, hi])))).
plan_native_external_effect_op(delete, delete(path('scratch.txt'))).

/* 3. With the exact per-op capability granted, an external-effect
   plan-native step executes at the plan layer through the canonical
   boundary: the durable effect boundary admits exactly one attempt and
   the attempt carries the content-derived normalized fingerprint. An
   identical re-execution is a replay off that fingerprint — no second
   external dispatch, no second durable attempt — and the same payload
   in a fresh store normalizes to the SAME fingerprint. */
test(plan_native_admitted_effect_produces_normalized_fingerprint,
     [forall(plan_native_external_effect_op(Op, Args))]) :-
    setup_call_cleanup(
        setup_effect_store(_),
        ( dangerous_context(Context),
          native_registry(Registry),
          plan_native_desugared(Op, Args, native_bind, Desugared),
          run_native_plan(Registry, Context, Op, Desugared, ok(Payload)),
          native_dispatch_count(Op, OneDispatch),
          assertion(OneDispatch =:= 1),
          rlm_effect_attempts(_, _, [Attempt]),
          assertion(Attempt.status == observed),
          get_dict(fingerprint, Attempt, Fingerprint),
          assertion(atom(Fingerprint)),
          sub_atom(Fingerprint, 0, _, _, 'sha256:'),
          run_native_plan(Registry, Context, Op, Desugared,
                          ok(ReplayedPayload)),
          assertion(ReplayedPayload == Payload),
          native_dispatch_count(Op, StillOneDispatch),
          assertion(StillOneDispatch =:= 1),
          rlm_effect_attempts(_, _, [SameAttempt]),
          assertion(SameAttempt.fingerprint == Fingerprint),
          cleanup_context(Context),
          tool_registry_destroy(Registry),
          cross_store_fingerprint_is_stable(Op, Args, Fingerprint) ),
        cleanup_effect_store(_)).


/* 4. The observation op (index, effect class observation / §6.2) is not
   externally effectful: it never enters the durable effect store and it
   re-executes fresh on every plan execution — observation is not
   memoized through the effect boundary. */
test(plan_native_observation_op_reexecutes_fresh) :-
    setup_call_cleanup(
        setup_effect_store(_),
        ( dangerous_context(Context),
          native_registry(Registry),
          plan_native_desugared(index, index(scope(all)), native_bind,
                                Desugared),
          run_native_plan(Registry, Context, index, Desugared,
                          ok(json{indexed:all})),
          run_native_plan(Registry, Context, index, Desugared,
                          ok(json{indexed:all})),
          native_dispatch_count(index, TwoFreshDispatches),
          assertion(TwoFreshDispatches =:= 2),
          rlm_effect_attempts(_, _, []),
          cleanup_context(Context),
          tool_registry_destroy(Registry) ),
        cleanup_effect_store(_)).

:- end_tests(rlm_plan_native_ops).
