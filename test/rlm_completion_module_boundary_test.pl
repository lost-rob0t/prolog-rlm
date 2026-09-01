:- begin_tests(rlm_completion_module_boundary).

/* Issue #328: a hostile host defining same-named helpers in `user` must not
   replace rlm_completion's local text/value normalization (and its
   completion_fault(expected_text/1) semantics) with an import fallback.
   The regression runs a fresh SWI process that plays the host, so the
   canonical load order (rlm_completion triggering rlm_direct's load) is
   reproduced outside this PlUnit process. */

:- use_module(library(process)).
:- use_module(library(readutil)).

test(hostile_host_keeps_runtime_ownership_via_library_rlm) :-
    run_hostile_host(rlm).

test(hostile_host_keeps_runtime_ownership_completion_first) :-
    run_hostile_host(completion_first).

test(hostile_host_ownership_is_independent_of_module_load_order) :-
    run_hostile_host(direct_first).

run_hostile_host(Mode) :-
    absolute_file_name('test/support/issue328_hostile_host.pl', Script,
                       [access(read)]),
    setup_call_cleanup(
        process_create(path(swipl),
                       ['-q', '-t', 'main', '-s', Script, '--', Mode],
                       [ process(Pid),
                         stdout(pipe(Out)),
                         stderr(pipe(Err)) ]),
        ( read_line_to_string(Out, Line),
          assertion(Line == "hostile_host_boundary_ok") ),
        ( close(Out),
          read_string(Err, _, ErrText),
          close(Err),
          assertion(\+ sub_string(ErrText, _, _, _,
                                  "redefine imported_procedure")),
          process_wait(Pid, Status),
          assertion(Status == exit(0)) )).

:- end_tests(rlm_completion_module_boundary).