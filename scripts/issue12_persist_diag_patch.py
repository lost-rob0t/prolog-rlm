from pathlib import Path

path = Path('test/rlm_graph_test.pl')
text = path.read_text()
old = '''persistent_resume_case(File, Compiled) :-
    graph_backend_open(persist(File), Backend1),
    graph_run(Compiled,
              _{},
              [backend(Backend1), run_id(persist_resume)],
              ok(Paused)),
    assertion(Paused.status == paused(needs_approval)),
    graph_backend_close(Backend1),
    graph_backend_open(persist(File), Backend2),
    graph_checkpoint(Backend2, persist_resume, Reloaded),
    assertion(Reloaded.status == paused(needs_approval)),
    graph_resume(Compiled,
                 Backend2,
                 persist_resume,
                 approved_after_restart,
                 [],
                 ok(Completed)),
    assertion(Completed.status == completed),
    assertion(Completed.state.log == [paused,approved_after_restart]),
    graph_backend_close(Backend2).
'''
new = '''persistent_resume_case(File, Compiled) :-
    require_persist_stage(open_initial,
                          graph_backend_open(persist(File), Backend1)),
    graph_run(Compiled,
              _{},
              [backend(Backend1), run_id(persist_resume)],
              RunOutcome),
    require_graph_success(persist_initial_run, RunOutcome, Paused),
    require_persist_value(initial_status,
                          Paused.status,
                          paused(needs_approval)),
    require_persist_stage(close_initial,
                          graph_backend_close(Backend1)),
    require_persist_stage(open_reload,
                          graph_backend_open(persist(File), Backend2)),
    require_persist_stage(read_checkpoint,
                          graph_checkpoint(Backend2,
                                           persist_resume,
                                           Reloaded)),
    require_persist_value(reloaded_status,
                          Reloaded.status,
                          paused(needs_approval)),
    graph_resume(Compiled,
                 Backend2,
                 persist_resume,
                 approved_after_restart,
                 [],
                 ResumeOutcome),
    require_graph_success(persist_resume_run, ResumeOutcome, Completed),
    require_persist_value(completed_status,
                          Completed.status,
                          completed),
    require_persist_value(completed_log,
                          Completed.state.log,
                          [paused,approved_after_restart]),
    require_persist_stage(close_reload,
                          graph_backend_close(Backend2)).

require_persist_stage(_, Goal) :-
    call(Goal),
    !.
require_persist_stage(Stage, _) :-
    throw(error(graph_persist_stage_failed(Stage),
                context(plunit_rlm_graph,
                        'persistent graph acceptance stage failed'))).

require_graph_success(_, ok(Result), Result) :- !.
require_graph_success(Stage, Outcome, _) :-
    throw(error(graph_persist_stage_outcome(Stage, Outcome),
                context(plunit_rlm_graph,
                        'persistent graph execution returned a non-success outcome'))).

require_persist_value(_, Actual, Expected) :-
    Actual == Expected,
    !.
require_persist_value(Stage, Actual, Expected) :-
    throw(error(graph_persist_value_mismatch(Stage, Actual, Expected),
                context(plunit_rlm_graph,
                        'persistent graph state did not match expectation'))).
'''
if text.count(old) != 1:
    raise SystemExit('persistent_resume_case block mismatch')
path.write_text(text.replace(old, new, 1))
print('persistent graph diagnostics applied')
