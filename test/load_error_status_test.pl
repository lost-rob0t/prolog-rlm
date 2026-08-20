:- begin_tests(load_error_status).

:- use_module(library(process)).

test(reported_load_error_exits_nonzero) :-
    process_create(path(swipl),
                   ['--on-error=status',
                    '-q',
                    '-g', halt,
                    '-s', 'test/support/load_error_fixture.pl'],
                   [ process(Pid),
                     stdout(null),
                     stderr(null)
                   ]),
    process_wait(Pid, Status),
    assertion(Status = exit(Code)),
    assertion(Code =\= 0).

:- end_tests(load_error_status).
