:- initialization(main, main).

:- use_module('../prolog/rlm_zara_runtime').

main(Argv) :-
    (   parse_args(Argv, Port)
    ->  rlm_zara_runtime:zara_runtime_server_start(Port),
        format(user_error,
               'Prolog-RLM ZARA-RUNTIME/1 listening on http://localhost:~d/zara-runtime/v1/~n',
               [Port]),
        thread_get_message(_)
    ;   usage,
        halt(2)
    ).

parse_args([], 18765).
parse_args(['--port', Value], Port) :-
    atom_number(Value, Port),
    integer(Port),
    Port >= 1,
    Port =< 65535,
    !.
parse_args(['--help'], _) :-
    usage,
    halt(0).

usage :-
    format(user_error,
           'Usage: swipl -q -s bin/prolog-rlm-zara.pl -- [--port PORT]~n',
           []).
