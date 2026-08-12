:- initialization(main, main).

:- use_module('../prolog/rlm_graph').
:- use_module('support/graph_restart_fixture').

main([File]) :-
    compile_restart_graph(Compiled),
    graph_backend_open(persist(File), Backend),
    graph_run(Compiled,
              _{},
              [backend(Backend), run_id(process_restart)],
              Outcome),
    require_paused(Outcome),
    graph_backend_close(Backend),
    halt(0).
main(_) :-
    format(user_error,
           'usage: swipl -q -s test/graph_restart_phase1.pl -- <checkpoint-file>~n',
           []),
    halt(2).

require_paused(ok(Result)) :-
    Result.status == paused(needs_restart),
    Result.current == resume,
    Result.state.log == [paused],
    !.
require_paused(Outcome) :-
    format(user_error,
           'phase1 did not persist the expected paused state: ~q~n',
           [Outcome]),
    halt(1).
