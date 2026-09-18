:- initialization(main, main).

:- use_module('../prolog/rlm_zara_runtime').

main(Argv) :-
    (   parse_args(Argv, 18765, [], Port, Profiles)
    ->  rlm_zara_runtime:zara_runtime_set_profiles(Profiles),
        rlm_zara_runtime:zara_runtime_server_start(Port),
        format(user_error,
               'Prolog-RLM ZARA-RUNTIME/1 listening on http://localhost:~d/zara-runtime/v1/~n',
               [Port]),
        thread_get_message(_)
    ;   usage,
        halt(2)
    ).

parse_args([], Port, Profiles, Port, Profiles).
parse_args(['--port', Value|Rest], _Port0, Profiles0, Port, Profiles) :-
    atom_number(Value, NextPort),
    integer(NextPort),
    NextPort >= 1,
    NextPort =< 65535,
    !,
    parse_args(Rest, NextPort, Profiles0, Port, Profiles).
parse_args(['--profile', Value|Rest], Port0, Profiles0, Port, Profiles) :-
    !,
    parse_args(Rest, Port0, [Value|Profiles0], Port, Profiles).
parse_args(['--help'|_], _, _, _, _) :-
    usage,
    halt(0).

usage :-
    format(user_error,
           'Usage: prolog-rlm-zara [--port PORT] [--profile PROFILE]...~n',
           []).
