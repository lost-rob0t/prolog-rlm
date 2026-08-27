:- initialization(main, main).

:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module('research_approval_validator').

main(_) :-
    (   run_git_root(Root),
        validate_repository(Root)
    ->  halt(0)
    ;   halt(1)
    ).

run_git_root(Root) :-
    process_create(path(git), ['rev-parse', '--show-toplevel'],
                   [ stdin(null), stdout(pipe(Stream)), stderr(null),
                     process(PID) ]),
    read_string(Stream, _, RawRoot),
    close(Stream),
    process_wait(PID, exit(0)),
    normalize_space(string(Root), RawRoot).
