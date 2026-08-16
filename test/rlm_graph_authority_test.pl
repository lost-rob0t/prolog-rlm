:- begin_tests(rlm_graph_authority).

:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_graph').
:- use_module('../prolog/rlm_tool').

:- dynamic graph_mutation_count/1.

graph_authority_schema([
    field(done, boolean, false, replace)
]).

graph_tool_schema(
    tool_schema{name:graph_authority_write,
                description:"graph authority side-effect fixture",
                capability:tool(graph_authority_write),
                effect:write,
                arguments:_{type:object,
                            required:[value],
                            additional_properties:false,
                            properties:_{value:_{type:integer}}},
                result:_{type:object,
                         required:[seen,count],
                         additional_properties:false,
                         properties:_{seen:_{type:integer},
                                      count:_{type:integer}}},
                limits:_{time_limit:1.0, max_output_bytes:4096}}).

reset_graph_mutations :-
    retractall(graph_mutation_count(_)),
    assertz(graph_mutation_count(0)).

graph_write_tool(Args, _{seen:Args.value, count:Count}) :-
    with_mutex(plunit_rlm_graph_authority_mutation,
               ( retract(graph_mutation_count(Current)),
                 Count is Current+1,
                 assertz(graph_mutation_count(Count)) )).

graph_side_effect_node(Registry, _, _, Result) :-
    rlm_tool:tool_invoke_execute(
        Registry,
        [tool(graph_authority_write)],
        graph_authority_write,
        _{value:1},
        [],
        ToolResult),
    graph_node_from_tool_result(ToolResult, Result).

graph_node_from_tool_result(
    tool_async_result{outcome:approval_required(Pending)},
    interrupt(approval_required(Pending.id), _{})) :-
    !.
graph_node_from_tool_result(
    tool_async_result{outcome:ok(_)},
    update(_{done:true})) :-
    !.
graph_node_from_tool_result(
    tool_async_result{outcome:error(Error)},
    _) :-
    throw(error(graph_authority_tool_failed(Error), _)).

compile_graph_authority(Registry, Compiled) :-
    graph_authority_schema(Schema),
    Spec = graph(graph_authority,
                 Schema,
                 [node(side_effect, side_effect_handler)],
                 [edge(start, side_effect), edge(side_effect, end)]),
    GraphRegistry = [handler(side_effect_handler,
                             plunit_rlm_graph_authority:graph_side_effect_node(
                                 Registry))],
    graph_compile(Spec, GraphRegistry, [], ok(Compiled)).

setup_graph_authority(Registry, Backend, Context, Compiled) :-
    reset_graph_mutations,
    tool_registry_create(Registry),
    graph_tool_schema(Schema),
    tool_register(Registry,
                  Schema,
                  plunit_rlm_graph_authority:graph_write_tool,
                  ok(_)),
    graph_backend_open(memory, Backend),
    Context = session(graph_authority_session),
    rlm_authority_clear(Context),
    compile_graph_authority(Registry, Compiled).

cleanup_graph_authority(Registry, Backend, Context) :-
    catch(rlm_authority_clear(Context), _, true),
    catch(graph_backend_close(Backend), _, true),
    catch(tool_registry_destroy(Registry), _, true).

test(graph_side_effect_pauses_for_shared_authority_without_worker_hostage) :-
    setup_call_cleanup(
        setup_graph_authority(Registry, Backend, Context, Compiled),
        ( graph_run(Compiled,
                    _{},
                    [ backend(Backend),
                      run_id(graph_authority_run),
                      session_id(graph_authority_session)
                    ],
                    ok(Paused)),
          Paused.status = paused(approval_required(ApprovalId)),
          assertion(Paused.current == end),
          graph_mutation_count(Before),
          assertion(Before =:= 0),
          rlm_pending_approval(Context, ApprovalId, Pending),
          assertion(Pending.state == pending),
          rlm_pending_resolution_async(ApprovalId, ResolutionFuture),
          rlm_async_runtime_status(Scheduler),
          assertion(Scheduler.running =:= 0),
          assertion(Scheduler.queued =:= 0),
          rlm_approve(ApprovalId, ok(Transition)),
          assertion(Transition.state == executing),
          rlm_future_await(ResolutionFuture, 2.0, Resolution),
          Resolution = tool_pending_resolution{outcome:ok(Value)},
          assertion(Value.seen =:= 1),
          graph_mutation_count(After),
          assertion(After =:= 1),
          graph_resume(Compiled,
                       Backend,
                       graph_authority_run,
                       approved,
                       [session_id(graph_authority_session)],
                       ok(Completed)),
          assertion(Completed.status == completed),
          graph_mutation_count(Final),
          assertion(Final =:= 1)
        ),
        cleanup_graph_authority(Registry, Backend, Context)).

:- end_tests(rlm_graph_authority).
