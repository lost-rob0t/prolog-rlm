from pathlib import Path


def replace_once(path, old, new):
    file_path = Path(path)
    text = file_path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one replacement, found {count}: {old[:80]!r}")
    file_path.write_text(text.replace(old, new, 1))


def insert_once(path, marker, addition):
    replace_once(path, marker, addition + marker)


def materialize_async_test():
    text = Path('.github/agent-graph-canonical.patch').read_text()
    start_marker = 'diff --git a/test/rlm_agent_graph_async_test.pl b/test/rlm_agent_graph_async_test.pl\n'
    end_marker = 'diff --git a/docs/agent-runtime.md b/docs/agent-runtime.md\n'
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    section = text[start:end]
    hunk = section.index('@@')
    hunk_end = section.index('\n', hunk)
    output = []
    for line in section[hunk_end + 1:].splitlines():
        if line.startswith('+') and not line.startswith('+++'):
            output.append(line[1:])
    Path('test/rlm_agent_graph_async_test.pl').write_text('\n'.join(output) + '\n')


# Agent public surface and module contract.
replace_once(
    'prolog/rlm_agent.pl',
    '''            agent_spawn/5,\n            agent_send/5,\n            agent_pump/4,\n''',
    '''            agent_spawn/5,\n            agent_spawn_async/5,\n            agent_send/5,\n            agent_send_async/5,\n            agent_pump/4,\n            agent_pump_async/4,\n''')
replace_once(
    'prolog/rlm_agent.pl',
    '''            agent_children/3,\n            agent_cancel/4,\n            agent_trace/2,\n''',
    '''            agent_children/3,\n            agent_cancel/4,\n            agent_cancel_async/4,\n            agent_trace/2,\n''')
replace_once(
    'prolog/rlm_agent.pl',
    '''Capabilities are inherited by subset: a child may drop parent authority but can\nnever add authority the parent did not have.\n*/\n''',
    '''Capabilities are inherited by subset: a child may drop parent authority but can\nnever add authority the parent did not have.\n\nLatency-bearing public operations are canonical async-first. The async API\nsubmits one execute predicate to `rlm_async`; the synchronous API starts that\nsame operation and awaits its Future. Code already executing inside canonical\nasynchronous work uses the execute ABI directly rather than nesting a Future\nwait. The runtime's separate bounded worker pool remains responsible for\nlogical-agent host work and mailbox/backpressure semantics.\n*/\n''')
replace_once(
    'prolog/rlm_agent.pl',
    ''':- use_module(library(thread_pool)).\n:- use_module(rlm_tool,\n''',
    ''':- use_module(library(thread_pool)).\n:- use_module(rlm_async, []).\n:- use_module(rlm_tool,\n''')
replace_once(
    'prolog/rlm_agent.pl',
    '''agent_spawn(Runtime, Parent, Spec0, RequestedCapabilities, Outcome) :-\n    catch(agent_spawn_(Runtime,\n                       Parent,\n                       Spec0,\n                       RequestedCapabilities,\n                       Outcome),\n          Exception,\n          agent_api_exception(spawn, Exception, Outcome)).\n''',
    '''agent_spawn_async(Runtime, Parent, Spec0, RequestedCapabilities, Future) :-\n    agent_spawn_task_metadata(Runtime, Parent, Metadata),\n    rlm_async:rlm_async_submit(\n        rlm_agent:agent_spawn_execute(Runtime,\n                                      Parent,\n                                      Spec0,\n                                      RequestedCapabilities),\n        Metadata,\n        Future).\n\nagent_spawn(Runtime, Parent, Spec0, RequestedCapabilities, Outcome) :-\n    agent_spawn_async(Runtime, Parent, Spec0, RequestedCapabilities, Future),\n    await_agent_future(Future, Outcome).\n\nagent_spawn_execute(Runtime, Parent, Spec0, RequestedCapabilities, Outcome) :-\n    catch(agent_spawn_(Runtime,\n                       Parent,\n                       Spec0,\n                       RequestedCapabilities,\n                       Outcome),\n          Exception,\n          agent_api_exception(spawn, Exception, Outcome)).\n''')
replace_once(
    'prolog/rlm_agent.pl',
    '''agent_send(Runtime, Agent, Message, Options, Outcome) :-\n    catch(agent_send_(Runtime, Agent, Message, Options, Outcome),\n          Exception,\n          agent_api_exception(send, Exception, Outcome)).\n''',
    '''agent_send_async(Runtime, Agent, Message, Options, Future) :-\n    agent_task_metadata(agent_send, Runtime, Agent, Options, Metadata),\n    rlm_async:rlm_async_submit(\n        rlm_agent:agent_send_execute(Runtime, Agent, Message, Options),\n        Metadata,\n        Future).\n\nagent_send(Runtime, Agent, Message, Options, Outcome) :-\n    agent_send_async(Runtime, Agent, Message, Options, Future),\n    await_agent_future(Future, Outcome).\n\nagent_send_execute(Runtime, Agent, Message, Options, Outcome) :-\n    catch(agent_send_(Runtime, Agent, Message, Options, Outcome),\n          Exception,\n          agent_api_exception(send, Exception, Outcome)).\n''')
replace_once(
    'prolog/rlm_agent.pl',
    '''agent_pump(Runtime, Agent, Options, Outcome) :-\n    catch(agent_pump_(Runtime, Agent, Options, Outcome),\n          Exception,\n          agent_api_exception(pump, Exception, Outcome)).\n''',
    '''agent_pump_async(Runtime, Agent, Options, Future) :-\n    agent_task_metadata(agent_pump, Runtime, Agent, Options, Metadata),\n    rlm_async:rlm_async_submit(\n        rlm_agent:agent_pump_execute(Runtime, Agent, Options),\n        Metadata,\n        Future).\n\nagent_pump(Runtime, Agent, Options, Outcome) :-\n    agent_pump_async(Runtime, Agent, Options, Future),\n    await_agent_future(Future, Outcome).\n\nagent_pump_execute(Runtime, Agent, Options, Outcome) :-\n    catch(agent_pump_(Runtime, Agent, Options, Outcome),\n          Exception,\n          agent_api_exception(pump, Exception, Outcome)).\n''')
replace_once(
    'prolog/rlm_agent.pl',
    '''agent_cancel(Runtime, agent(AgentId), Reason, Outcome) :-\n    catch(agent_cancel_(Runtime, AgentId, Reason, Outcome),\n          Exception,\n          agent_api_exception(cancel, Exception, Outcome)).\n''',
    '''agent_cancel_async(Runtime, Agent, Reason, Future) :-\n    agent_task_metadata(agent_cancel, Runtime, Agent, [], Metadata),\n    rlm_async:rlm_async_submit(\n        rlm_agent:agent_cancel_execute(Runtime, Agent, Reason),\n        Metadata,\n        Future).\n\nagent_cancel(Runtime, Agent, Reason, Outcome) :-\n    agent_cancel_async(Runtime, Agent, Reason, Future),\n    await_agent_future(Future, Outcome).\n\nagent_cancel_execute(Runtime, Agent, Reason, Outcome) :-\n    catch(agent_cancel_execute_(Runtime, Agent, Reason, Outcome),\n          Exception,\n          agent_api_exception(cancel, Exception, Outcome)).\n\nagent_cancel_execute_(Runtime, agent(AgentId), Reason, Outcome) :-\n    agent_cancel_(Runtime, AgentId, Reason, Outcome).\nagent_cancel_execute_(_, Agent, _, _) :-\n    throw(agent_fault(invalid_agent(Agent))).\n''')
replace_once(
    'prolog/rlm_agent.pl',
    '''cancel_children(Runtime, [Child|Children], Reason) :-\n    agent_cancel(Runtime, Child, Reason, _),\n    cancel_children(Runtime, Children, Reason).\n''',
    '''cancel_children(Runtime, [Child|Children], Reason) :-\n    agent_cancel_execute(Runtime, Child, Reason, _),\n    cancel_children(Runtime, Children, Reason).\n''')
replace_once(
    'prolog/rlm_agent.pl',
    '''agent_plan_handler(Runtime, Parent, Spec, Capabilities, Child) :-\n    agent_spawn(Runtime, Parent, Spec, Capabilities, Outcome),\n''',
    '''agent_plan_handler(Runtime, Parent, Spec, Capabilities, Child) :-\n    agent_spawn_execute(Runtime, Parent, Spec, Capabilities, Outcome),\n''')
insert_once(
    'prolog/rlm_agent.pl',
    '''agent_api_exception(Phase, agent_fault(Fault), error(Error)) :-\n''',
    '''await_agent_future(Future, Outcome) :-\n    setup_call_cleanup(\n        true,\n        rlm_async:rlm_future_await(Future, Outcome),\n        rlm_async:rlm_future_destroy(Future)).\n\nagent_spawn_task_metadata(Runtime0, Parent0, Metadata) :-\n    metadata_runtime_id(Runtime0, RuntimeId),\n    metadata_agent_id(Parent0, ParentId),\n    Metadata = async_metadata{\n                   operation:agent_spawn,\n                   runtime_id:RuntimeId,\n                   parent_agent:ParentId,\n                   trace_id:none,\n                   session_id:none\n               }.\n\nagent_task_metadata(Operation, Runtime0, Agent0, Options, Metadata) :-\n    metadata_runtime_id(Runtime0, RuntimeId),\n    metadata_agent_id(Agent0, AgentId),\n    metadata_option(trace_id, Options, none, TraceId),\n    metadata_option(session_id, Options, none, SessionId),\n    Metadata = async_metadata{\n                   operation:Operation,\n                   runtime_id:RuntimeId,\n                   agent_id:AgentId,\n                   trace_id:TraceId,\n                   session_id:SessionId\n               }.\n\nmetadata_runtime_id(agent_runtime(Id), Id) :-\n    ground(Id),\n    !.\nmetadata_runtime_id(_, unknown).\n\nmetadata_agent_id(none, none) :- !.\nmetadata_agent_id(agent(Id), Id) :-\n    ground(Id),\n    !.\nmetadata_agent_id(_, unknown).\n\nmetadata_option(Name, Options, Default, Value) :-\n    (   is_list(Options),\n        member(Option, Options),\n        nonvar(Option),\n        Option =.. [Name, Found],\n        ground(Found)\n    ->  Value = Found\n    ;   Value = Default\n    ).\n\nagent_api_exception(_, Exception, _) :-\n    agent_control_exception(Exception),\n    !,\n    throw(Exception).\n\n''')
insert_once(
    'prolog/rlm_agent.pl',
    '''safe_exception(Exception, Safe) :-\n''',
    '''agent_control_exception(rlm_async_cancelled(_)).\nagent_control_exception('$aborted').\nagent_control_exception(abort).\n\n''')

Path('prolog/rlm_agent_async.pl').write_text(''':- module(rlm_agent_async,\n          [ agent_spawn_async/5,\n            agent_send_async/5,\n            agent_pump_async/4,\n            agent_cancel_async/4\n          ]).\n\n/** <module> Compatibility facade for canonical asynchronous agent operations\n\nThe canonical async/task implementation lives in rlm_agent. This module remains\nfor callers that import the historical async facade directly and delegates only\nto asynchronous predicates. It never enters a synchronous public wrapper.\n*/\n\n:- use_module(rlm_agent, []).\n\nagent_spawn_async(Runtime, Parent, Spec, Capabilities, Future) :-\n    rlm_agent:agent_spawn_async(Runtime, Parent, Spec, Capabilities, Future).\n\nagent_send_async(Runtime, Agent, Message, Options, Future) :-\n    rlm_agent:agent_send_async(Runtime, Agent, Message, Options, Future).\n\nagent_pump_async(Runtime, Agent, Options, Future) :-\n    rlm_agent:agent_pump_async(Runtime, Agent, Options, Future).\n\nagent_cancel_async(Runtime, Agent, Reason, Future) :-\n    rlm_agent:agent_cancel_async(Runtime, Agent, Reason, Future).\n''')

# Graph canonical run/resume surface.
replace_once(
    'prolog/rlm_graph.pl',
    '''            graph_backend_close/1,\n            graph_run/4,\n            graph_resume/6,\n            graph_checkpoint/3,\n''',
    '''            graph_backend_close/1,\n            graph_run/4,\n            graph_run_async/4,\n            graph_resume/6,\n            graph_resume_async/6,\n            graph_checkpoint/3,\n''')
replace_once(
    'prolog/rlm_graph.pl',
    '''execution events for interrupt/resume and history inspection.\n*/\n''',
    '''execution events for interrupt/resume and history inspection.\n\nGraph run/resume are canonical async-first. The asynchronous surfaces submit one\nexecute predicate to `rlm_async`; synchronous run/resume start that same\noperation and await its Future. Inline subgraphs call the execute ABI directly,\nso canonical graph work never nests a Future wait merely to compose a subgraph.\n*/\n''')
replace_once(
    'prolog/rlm_graph.pl',
    ''':- use_module(library(uuid)).\n:- use_module(rlm_graph_persist).\n''',
    ''':- use_module(library(uuid)).\n:- use_module(rlm_async, []).\n:- use_module(rlm_graph_persist).\n''')
replace_once(
    'prolog/rlm_graph.pl',
    '''graph_run(Compiled, InitialState0, Options, Outcome) :-\n    catch(graph_run_guarded(Compiled, InitialState0, Options, Outcome),\n          Exception,\n          graph_execution_exception(Exception, Outcome)).\n''',
    '''graph_run_async(Compiled, InitialState0, Options, Future) :-\n    graph_run_task_metadata(Compiled, Options, Metadata),\n    rlm_async:rlm_async_submit(\n        rlm_graph:graph_run_execute(Compiled, InitialState0, Options),\n        Metadata,\n        Future).\n\ngraph_run(Compiled, InitialState0, Options, Outcome) :-\n    graph_run_async(Compiled, InitialState0, Options, Future),\n    await_graph_future(Future, Outcome).\n\ngraph_run_execute(Compiled, InitialState0, Options, Outcome) :-\n    catch(graph_run_guarded(Compiled, InitialState0, Options, Outcome),\n          Exception,\n          graph_execution_exception(Exception, Outcome)).\n''')
replace_once(
    'prolog/rlm_graph.pl',
    '''graph_resume(Compiled, Backend, RunId, Resume0, Options, Outcome) :-\n    catch(graph_resume_guarded(Compiled,\n                               Backend,\n                               RunId,\n                               Resume0,\n                               Options,\n                               Outcome),\n          Exception,\n          graph_execution_exception(Exception, Outcome)).\n''',
    '''graph_resume_async(Compiled, Backend, RunId, Resume0, Options, Future) :-\n    graph_resume_task_metadata(Compiled, RunId, Options, Metadata),\n    rlm_async:rlm_async_submit(\n        rlm_graph:graph_resume_execute(Compiled,\n                                       Backend,\n                                       RunId,\n                                       Resume0,\n                                       Options),\n        Metadata,\n        Future).\n\ngraph_resume(Compiled, Backend, RunId, Resume0, Options, Outcome) :-\n    graph_resume_async(Compiled, Backend, RunId, Resume0, Options, Future),\n    await_graph_future(Future, Outcome).\n\ngraph_resume_execute(Compiled, Backend, RunId, Resume0, Options, Outcome) :-\n    catch(graph_resume_guarded(Compiled,\n                               Backend,\n                               RunId,\n                               Resume0,\n                               Options,\n                               Outcome),\n          Exception,\n          graph_execution_exception(Exception, Outcome)).\n''')
replace_once(
    'prolog/rlm_graph.pl',
    '''    graph_run(Subgraph, State, SubOptions, SubOutcome),\n''',
    '''    graph_run_execute(Subgraph, State, SubOptions, SubOutcome),\n''')
insert_once(
    'prolog/rlm_graph.pl',
    '''graph_options(Options, Config, Token, OwnToken) :-\n''',
    '''await_graph_future(Future, Outcome) :-\n    setup_call_cleanup(\n        true,\n        rlm_async:rlm_future_await(Future, Outcome),\n        rlm_async:rlm_future_destroy(Future)).\n\ngraph_run_task_metadata(Compiled, Options, Metadata) :-\n    metadata_graph_id(Compiled, GraphId),\n    metadata_option(run_id, Options, auto, RunId),\n    graph_task_metadata(graph_run, GraphId, RunId, Options, Metadata).\n\ngraph_resume_task_metadata(Compiled, RunId0, Options, Metadata) :-\n    metadata_graph_id(Compiled, GraphId),\n    metadata_ground(RunId0, unknown, RunId),\n    graph_task_metadata(graph_resume, GraphId, RunId, Options, Metadata).\n\ngraph_task_metadata(Operation, GraphId, RunId, Options, Metadata) :-\n    metadata_option(trace_id, Options, none, TraceId),\n    metadata_option(session_id, Options, none, SessionId),\n    Metadata = async_metadata{\n                   operation:Operation,\n                   graph_id:GraphId,\n                   graph_run_id:RunId,\n                   trace_id:TraceId,\n                   session_id:SessionId\n               }.\n\nmetadata_graph_id(Compiled, GraphId) :-\n    is_dict(Compiled),\n    get_dict(id, Compiled, Id),\n    ground(Id),\n    !,\n    GraphId = Id.\nmetadata_graph_id(_, unknown).\n\nmetadata_option(Name, Options, Default, Value) :-\n    (   is_list(Options),\n        member(Option, Options),\n        nonvar(Option),\n        Option =.. [Name, Found],\n        ground(Found)\n    ->  Value = Found\n    ;   Value = Default\n    ).\n\nmetadata_ground(Value, _, Value) :-\n    ground(Value),\n    !.\nmetadata_ground(_, Default, Default).\n\n''')
insert_once(
    'prolog/rlm_graph.pl',
    '''graph_execution_exception(graph_cancelled(Token), error(Error)) :-\n''',
    '''graph_execution_exception(Exception, _) :-\n    graph_control_exception(Exception),\n    !,\n    throw(Exception).\n\n''')
insert_once(
    'prolog/rlm_graph.pl',
    '''require_compiled_graph(Compiled) :-\n''',
    '''graph_control_exception(rlm_async_cancelled(_)).\ngraph_control_exception(rlm_cancelled(_)).\ngraph_control_exception(chain_cancelled(_)).\ngraph_control_exception(cancelled(_)).\ngraph_control_exception('$aborted').\ngraph_control_exception(abort).\n\n''')

Path('prolog/rlm_graph_async.pl').write_text(''':- module(rlm_graph_async,\n          [ graph_run_async/4,\n            graph_resume_async/6\n          ]).\n\n/** <module> Compatibility facade for canonical asynchronous graph operations\n\nThe canonical async/task implementation lives in rlm_graph. This module remains\nfor callers that import the historical async facade directly and delegates only\nto asynchronous predicates. It never enters a synchronous public wrapper.\n*/\n\n:- use_module(rlm_graph, []).\n\ngraph_run_async(Compiled, Input, Options, Future) :-\n    rlm_graph:graph_run_async(Compiled, Input, Options, Future).\n\ngraph_resume_async(Compiled, Backend, RunId, Resume, Options, Future) :-\n    rlm_graph:graph_resume_async(Compiled,\n                                 Backend,\n                                 RunId,\n                                 Resume,\n                                 Options,\n                                 Future).\n''')

# Top-level module imports canonical async surfaces from their owning modules.
replace_once(
    'prolog/rlm.pl',
    '''The public completion/query direction is canonical async -> sync await. The\nrecursion gate is evaluated before scheduling, and even a rejected request is\nrepresented by a Future on the async surface. No public async task calls the\npublic synchronous predicate.\n''',
    '''Latency-bearing completion/query, provider/chain, tool/MCP, agent, and graph\nsurfaces follow one direction: canonical execute semantics -> async Future ->\nsync await. The recursion gate is evaluated before completion scheduling, and\neven a rejected completion request is represented by a Future on the async\nsurface. No public async task calls its public synchronous predicate, and\ninternal canonical async work uses execute ABIs instead of nested Future waits.\n''')
replace_once(
    'prolog/rlm.pl',
    '''                agent_spawn/5,\n                agent_send/5,\n                agent_pump/4,\n                agent_status/3,\n                agent_children/3,\n                agent_cancel/4,\n                agent_trace/2,\n                agent_tool_handler/4\n              ]).\n:- use_module(rlm_agent_async,\n              [ agent_spawn_async/5,\n                agent_send_async/5,\n                agent_pump_async/4,\n                agent_cancel_async/4\n              ]).\n''',
    '''                agent_spawn/5,\n                agent_spawn_async/5,\n                agent_send/5,\n                agent_send_async/5,\n                agent_pump/4,\n                agent_pump_async/4,\n                agent_status/3,\n                agent_children/3,\n                agent_cancel/4,\n                agent_cancel_async/4,\n                agent_trace/2,\n                agent_tool_handler/4\n              ]).\n''')
replace_once(
    'prolog/rlm.pl',
    '''                graph_backend_close/1,\n                graph_run/4,\n                graph_resume/6,\n                graph_checkpoint/3,\n                graph_history/3,\n                graph_cancellation_token/1,\n                graph_cancel/1\n              ]).\n:- use_module(rlm_graph_async,\n              [ graph_run_async/4,\n                graph_resume_async/6\n              ]).\n''',
    '''                graph_backend_close/1,\n                graph_run/4,\n                graph_run_async/4,\n                graph_resume/6,\n                graph_resume_async/6,\n                graph_checkpoint/3,\n                graph_history/3,\n                graph_cancellation_token/1,\n                graph_cancel/1\n              ]).\n''')

materialize_async_test()
replace_once(
    'test/run_tests.pl',
    ''':- consult(rlm_agent_test).\n:- consult(rlm_graph_test).\n''',
    ''':- consult(rlm_agent_test).\n:- consult(rlm_graph_test).\n:- consult(rlm_agent_graph_async_test).\n''')

# Documentation keeps the public/internal scheduler split explicit.
replace_once(
    'docs/agent-runtime.md',
    '''agent_spawn(+Runtime, +Parent, +Spec, +Capabilities, -Outcome).\nagent_send(+Runtime, +Agent, +Message, +Options, -Outcome).\nagent_pump(+Runtime, +Agent, +Options, -Outcome).\nagent_status(+Runtime, +Agent, -Outcome).\nagent_children(+Runtime, +Agent, -Children).\nagent_cancel(+Runtime, +Agent, +Reason, -Outcome).\nagent_trace(+Runtime, -Events).\n```\n\n''',
    '''agent_spawn(+Runtime, +Parent, +Spec, +Capabilities, -Outcome).\nagent_spawn_async(+Runtime, +Parent, +Spec, +Capabilities, -Future).\nagent_send(+Runtime, +Agent, +Message, +Options, -Outcome).\nagent_send_async(+Runtime, +Agent, +Message, +Options, -Future).\nagent_pump(+Runtime, +Agent, +Options, -Outcome).\nagent_pump_async(+Runtime, +Agent, +Options, -Future).\nagent_status(+Runtime, +Agent, -Outcome).\nagent_children(+Runtime, +Agent, -Children).\nagent_cancel(+Runtime, +Agent, +Reason, -Outcome).\nagent_cancel_async(+Runtime, +Agent, +Reason, -Future).\nagent_trace(+Runtime, -Events).\n```\n\nSpawn, send, pump, and cancellation are canonical async-first operations. Each\n`*_async` predicate submits one `*_execute` operation to `rlm_async`; each sync\npredicate starts that same operation and awaits its Future. Trusted library\ncode already running inside a canonical async worker calls the execute ABI\ndirectly instead of starting and waiting on a nested Future.\n\nThe execute predicates are a trusted host/library composition ABI, not part of\nmodel-generated callable resolution. `rlm_async` schedules public API work; the\nagent runtime's separate bounded worker pool still bounds blocking mailbox host\nwork and preserves actor fairness, backpressure, and supervision semantics.\n\n''')
insert_once(
    'docs/graph-runtime.md',
    '''## Public API\n''',
    '''## Canonical async execution\n\nLatency-bearing run/resume operations are async-first:\n\n```prolog\ngraph_run_async(+Compiled, +InitialState, +Options, -Future).\ngraph_run(+Compiled, +InitialState, +Options, -Outcome).\ngraph_resume_async(+Compiled, +Backend, +RunId, +Resume, +Options, -Future).\ngraph_resume(+Compiled, +Backend, +RunId, +Resume, +Options, -Outcome).\n```\n\nThe async surfaces submit `graph_run_execute/4` and `graph_resume_execute/6`.\nThe synchronous surfaces start those same operations and await their Futures.\nInline subgraphs call the execute ABI directly, preventing nested Future waits\nwhen a graph already occupies an `rlm_async` worker. Compilation, schema\nvalidation, checkpoint lookup/history, and backend metadata remain immediate.\n\nFuture metadata carries operation, graph ID, requested run ID, trace ID and\nsession ID when available. Execute predicates remain a trusted host/library\ncomposition ABI and are not model-callable graph registry entries.\n\n''')

# Fail loudly if the transformed tree does not contain the core invariants.
checks = {
    'prolog/rlm_agent.pl': [
        'agent_send_execute',
        'agent_cancel_execute(Runtime, Child, Reason, _)',
        'agent_spawn_execute(Runtime, Parent, Spec, Capabilities, Outcome)',
    ],
    'prolog/rlm_graph.pl': [
        'graph_run_execute(Subgraph, State, SubOptions, SubOutcome)',
        'graph_execution_exception(Exception, _)',
        'graph_control_exception(rlm_async_cancelled(_))',
    ],
    'test/rlm_agent_graph_async_test.pl': [
        'subgraph_execute_abi_avoids_nested_future_deadlock_under_saturation',
    ],
}
for path, needles in checks.items():
    text = Path(path).read_text()
    for needle in needles:
        if needle not in text:
            raise SystemExit(f'{path}: missing invariant {needle!r}')
