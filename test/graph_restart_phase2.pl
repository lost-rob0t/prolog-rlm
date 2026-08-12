:- initialization(main, main).

:- use_module('../prolog/rlm_graph').
:- use_module('support/graph_restart_fixture').

main([File]) :-
    compile_restart_graph(Compiled),
    graph_backend_open(persist(File), Backend),
    graph_checkpoint(Backend, process_restart, Snapshot),
    require_checkpoint(Snapshot),
    graph_resume(Compiled,
                 Backend,
                 process_restart,
                 resumed_after_process_restart,
                 [],
                 Outcome),
    require_completed(Outcome),
    graph_backend_close(Backend),
    halt(0).
main(_) :-
    format(user_error,
           'usage: swipl -q -s test/graph_restart_phase2.pl -- <checkpoint-file>~n',
           []),
    halt(2).

require_checkpoint(Snapshot) :-
    Snapshot.status == paused(needs_restart),
    Snapshot.current == resume,
    Snapshot.state.log == [paused],
    !.
require_checkpoint(Snapshot) :-
    format(user_error,
           'phase2 could not reload the expected checkpoint: ~q~n',
           [Snapshot]),
    halt(1).

require_completed(ok(Result)) :-
    Result.status == completed,
    Result.state.approved == true,
    Result.state.log == [paused,resumed_after_process_restart],
    !.
require_completed(Outcome) :-
    format(user_error,
           'phase2 did not resume to the expected completed state: ~q~n',
           [Outcome]),
    halt(1).
