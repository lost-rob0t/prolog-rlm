:- module(rlm_demo,
          [ rlm_demo_ready/0,
            demo/2,
            demo_all/1,
            demo_context/1,
            demo_tool/1,
            demo_recursion/1,
            demo_agent/1,
            demo_graph/1,
            demo_mcp/1
          ]).

/** <module> Deterministic interactive demonstrations

These demos exercise production runtime APIs without provider credentials.
They are intended for REPL use and for the CLI `demo` command. No fake model
provider is registered here; real direct/RLM model calls remain explicit CLI
operations using the production provider layer.
*/

:- use_module(rlm_context).
:- use_module(rlm_tool).
:- use_module(rlm_recursion_runtime).
:- use_module(rlm_agent).
:- use_module(rlm_graph).
:- use_module(rlm_mcp).

rlm_demo_ready.

demo(all, Result) :- !, demo_all(Result).
demo(context, Result) :- !, demo_context(Result).
demo(tool, Result) :- !, demo_tool(Result).
demo(recursion, Result) :- !, demo_recursion(Result).
demo(agent, Result) :- !, demo_agent(Result).
demo(graph, Result) :- !, demo_graph(Result).
demo(mcp, Result) :- !, demo_mcp(Result).
demo(Name, error(Error)) :-
    Error = demo_error{kind:unknown_demo,
                       demo:Name,
                       available:[all,context,tool,recursion,agent,graph,mcp],
                       message:"unknown deterministic demo"}.

demo_all(Result) :-
    demo_context(Context),
    demo_tool(Tool),
    demo_recursion(Recursion),
    demo_agent(Agent),
    demo_graph(Graph),
    demo_mcp(Mcp),
    Cases = [Context, Tool, Recursion, Agent, Graph, Mcp],
    (   forall(member(Case, Cases), Case.status == pass)
    ->  Status = pass
    ;   Status = fail
    ),
    Result = demo_suite{status:Status,
                        cases:Cases}.

/* External context ------------------------------------------------------ */

demo_context(Result) :-
    catch(demo_context_(Result),
          Exception,
          demo_exception(context, Exception, Result)).

demo_context_(Result) :-
    Source = text("alpha\nbeta needle\ngamma\ndelta needle\nepsilon\n"),
    context_register(Source, [], ok(Ref)),
    setup_call_cleanup(
        true,
        demo_context_handle(Ref.handle, Result),
        context_delete(Ref.handle, _)).

demo_context_handle(Handle, Result) :-
    context_peek(Handle, head(16), [max_bytes(64)], ok(Peek)),
    context_search(Handle,
                   "needle",
                   [max_results(4), max_bytes(256)],
                   ok(Search)),
    length(Search.value, Matches),
    Result = demo_result{
                 name:context,
                 status:pass,
                 value:_{peek:Peek.value,
                         search_matches:Matches,
                         search:Search.value},
                 trace:[Peek.trace, Search.trace]
             }.

/* Capability-gated tool ------------------------------------------------- */

demo_tool(Result) :-
    catch(demo_tool_(Result),
          Exception,
          demo_exception(tool, Exception, Result)).

demo_tool_(Result) :-
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_project_read_tool(Registry, '.', [], ok(_)),
        demo_tool_registry(Registry, Result),
        tool_registry_destroy(Registry)).

demo_tool_registry(Registry, Result) :-
    tool_invoke(Registry,
                [tool(project_read)],
                project_read,
                json{path:"test/fixtures/tool-readable.txt"},
                [],
                ok(Execution),
                Trace),
    Result = demo_result{
                 name:tool,
                 status:pass,
                 value:_{authorization:Execution.authorization,
                         status:Execution.status,
                         content:Execution.value.content,
                         truncated:Execution.value.truncated},
                 trace:[Trace]
             }.

/* Adaptive recursion ---------------------------------------------------- */

demo_recursion(Result) :-
    catch(demo_recursion_(Result),
          Exception,
          demo_exception(recursion, Exception, Result)).

demo_recursion_(Result) :-
    Signals = _{task_complexity:0.9,
                context_chars:180000,
                uncertainty:0.75,
                branch_diversity:0.3,
                current_depth:0,
                remaining_calls:4,
                remaining_tokens:8000},
    Request = _{subject:demo_task(long_context_reasoning),
                parent_identity:demo_root,
                direct_continuation:rlm_demo:demo_direct_handler,
                recursive_rlm:rlm_demo:demo_recursive_handler,
                selector:rlm_demo:prefer_recursive},
    recursion_execute(Signals, Request, [], ok(Execution)),
    Result = demo_result{
                 name:recursion,
                 status:pass,
                 value:_{selected_policy:Execution.selected_policy,
                         result:Execution.result,
                         depth:Execution.next_depth,
                         actual_cost:Execution.actual_cost,
                         usage:Execution.actual_usage},
                 trace:Execution.trace
             }.

prefer_recursive(_, Candidates, Selected) :-
    member(Selected, Candidates),
    Selected.route == recursive_rlm,
    !.

demo_direct_handler(_, Subject,
                    ok(direct(Subject),
                       _{actual_cost:0.001,
                         usage:usage{model_calls:1,total_tokens:24},
                         child_identity:demo_direct})).

demo_recursive_handler(_, Subject,
                       ok(recursive(Subject),
                          _{actual_cost:0.003,
                            usage:usage{model_calls:2,total_tokens:48},
                            child_identity:demo_recursive_child})).

/* Supervised agents ----------------------------------------------------- */

demo_agent(Result) :-
    catch(demo_agent_(Result),
          Exception,
          demo_exception(agent, Exception, Result)).

demo_agent_(Result) :-
    agent_runtime_create([mailbox_size(2), worker_count(2)], Runtime),
    setup_call_cleanup(
        true,
        demo_agent_runtime(Runtime, Result),
        agent_runtime_destroy(Runtime)).

demo_agent_runtime(Runtime, Result) :-
    agent_spawn(Runtime, none, agent_spec(parent), [], ok(Parent)),
    agent_spawn(Runtime, Parent, agent_spec(child), [], ok(Child)),
    agent_children(Runtime, Parent, ok(Children)),
    agent_runtime_status(Runtime, RuntimeStatus),
    agent_cancel(Runtime, Parent, demo_complete, ok(_)),
    agent_status(Runtime, Parent, ok(ParentStatus)),
    agent_status(Runtime, Child, ok(ChildStatus)),
    agent_trace(Runtime, Trace),
    Result = demo_result{
                 name:agent,
                 status:pass,
                 value:_{parent:Parent,
                         child:Child,
                         children:Children,
                         logical_agents:RuntimeStatus.agent_count,
                         worker_pool_size:RuntimeStatus.worker_pool_size,
                         parent_status:ParentStatus.status,
                         child_status:ChildStatus.status},
                 trace:Trace
             }.

/* Durable graph interrupt/resume --------------------------------------- */

demo_graph(Result) :-
    catch(demo_graph_(Result),
          Exception,
          demo_exception(graph, Exception, Result)).

demo_graph_(Result) :-
    demo_graph_spec(Spec),
    demo_graph_registry(Registry),
    graph_compile(Spec, Registry, [], ok(Compiled)),
    graph_backend_open(memory, Backend),
    setup_call_cleanup(
        true,
        demo_graph_backend(Compiled, Backend, Result),
        graph_backend_close(Backend)).

demo_graph_backend(Compiled, Backend, Result) :-
    RunId = demo_graph_resume,
    graph_run(Compiled,
              _{},
              [backend(Backend), run_id(RunId)],
              ok(Paused)),
    graph_checkpoint(Backend, RunId, Snapshot),
    graph_resume(Compiled,
                 Backend,
                 RunId,
                 approved,
                 [],
                 ok(Completed)),
    graph_history(Backend, RunId, History),
    Result = demo_result{
                 name:graph,
                 status:pass,
                 value:_{paused_status:Paused.status,
                         checkpoint_status:Snapshot.status,
                         completed_status:Completed.status,
                         state:Completed.state},
                 trace:History
             }.

demo_graph_spec(
    graph(demo_resume_graph,
          [field(log, list, [], append),
           field(approved, boolean, false, replace)],
          [node(wait, wait_handler),
           node(resume, resume_handler)],
          [edge(start, wait),
           edge(wait, resume),
           edge(resume, end)])).

demo_graph_registry([
    handler(wait_handler, rlm_demo:demo_interrupt_node),
    handler(resume_handler, rlm_demo:demo_resume_node)
]).

demo_interrupt_node(_, _, interrupt(needs_approval, _{log:[paused]})).
demo_resume_node(_, Context,
                 update(_{approved:true, log:[Context.resume]})).

/* MCP facade ------------------------------------------------------------ */

demo_mcp(Result) :-
    catch(demo_mcp_(Result),
          Exception,
          demo_exception(mcp, Exception, Result)).

demo_mcp_(Result) :-
    rlm_mcp_ready,
    mcp_command_normalize(list_tools, ok(ListTools)),
    mcp_command_normalize(call_tool(example, _{value:1}), ok(CallTool)),
    Result = demo_result{
                 name:mcp,
                 status:pass,
                 value:_{facade:version_neutral,
                         supported_protocols:['2025-11-25','2026-07-28'],
                         list_tools:ListTools,
                         call_tool:CallTool},
                 trace:[]
             }.

/* Errors ---------------------------------------------------------------- */

demo_exception(Name, Exception, Result) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Result = demo_result{
                 name:Name,
                 status:fail,
                 value:_{exception:Safe},
                 trace:[]
             }.
