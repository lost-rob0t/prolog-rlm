:- module(deterministic_runner,
          [ report_is_valid/1,
            run/1,
            run/2
          ]).

:- use_module(library(http/json), [json_write_dict/3]).
:- use_module(library(lists), [member/2]).
:- use_module(library(option), [option/3]).
:- use_module(library(plunit)).
:- use_module(library(time), [call_with_time_limit/2]).

run(Suites) :-
    run(Suites, []).

run(Suites, Options) :-
    option(run_budget(RunBudget), Options, 45),
    option(test_timeout(TestTimeout), Options, 20),
    registered_test_suites(Registered),
    Suites \= [],
    same_test_suites(Suites, Registered),
    aggregate_test_counts(Suites, SuiteCounts, Discovered),
    forall(member(Count, SuiteCounts), positive_count(Count)),
    length(Suites, SuiteCount),
    format('aggregate_plunit_discovered suites=~d tests=~d~n',
           [SuiteCount, Discovered]),
    catch(call_with_time_limit(RunBudget,
                               run_bounded(Suites,
                                           SuiteCount,
                                           Discovered,
                                           TestTimeout)),
          Exception,
          run_aborted(SuiteCount, Discovered, Exception)).

run_bounded(Expected, SuiteCount, Discovered, TestTimeout) :-
    run_tests(Expected,
              [ summary(Summary),
                timeout(TestTimeout),
                cleanup(false)
              ]),
    summary_counts(Summary,
                   Planned,
                   Passed,
                   Failed,
                   _PlunitTimeout,
                   Blocked,
                   Fixme),
    timeout_count(Timeout),
    completed_test_count(Completed),
    format('aggregate_plunit_summary suites=~d discovered=~d planned=~d completed=~d passed=~d failed=~d timeout=~d blocked=~d fixme=~d~n',
           [SuiteCount, Discovered, Planned, Completed, Passed, Failed,
            Timeout, Blocked, Fixme]),
    result_status(Discovered,
                  Planned,
                  Completed,
                  Passed,
                  Failed,
                  Timeout,
                  Blocked,
                  Fixme,
                  Status),
    report(SuiteCount,
           Discovered,
           Planned,
           Completed,
           Passed,
           Failed,
           Timeout,
           Blocked,
           Fixme,
           Status,
           complete),
    (   Status == pass
    ->  format('aggregate_plunit_complete suites=~d tests=~d~n',
               [SuiteCount, Discovered])
    ;   fail
    ).

run_aborted(SuiteCount, Discovered, Exception) :-
    completed_test_count(Completed),
    completed_result_counts(Passed, Failed, Timeout, Blocked, Fixme),
    format('aggregate_plunit_abort suites=~d discovered=~d completed=~d reason=~q~n',
           [SuiteCount, Discovered, Completed, Exception]),
    report(SuiteCount,
           Discovered,
           unknown,
           Completed,
           Passed,
           Failed,
           Timeout,
           Blocked,
           Fixme,
           fail,
           aborted),
    fail.

report_is_valid(Record) :-
    dict_field_equal(Record, schema, "prolog-rlm.plunit.v1"),
    dict_field_equal(Record, phase, complete),
    dict_field_equal(Record, status, pass),
    get_dict(suites, Record, Suites),
    get_dict(discovered, Record, Discovered),
    get_dict(planned, Record, Planned),
    get_dict(completed, Record, Completed),
    get_dict(passed, Record, Passed),
    get_dict(failed, Record, Failed),
    get_dict(timeout, Record, Timeout),
    get_dict(blocked, Record, Blocked),
    get_dict(fixme, Record, Fixme),
    integer(Suites),
    integer(Discovered),
    integer(Planned),
    integer(Completed),
    integer(Passed),
    integer(Failed),
    integer(Timeout),
    integer(Blocked),
    integer(Fixme),
    Suites > 0,
    Discovered > 0,
    Planned =:= Discovered,
    Completed =:= Planned,
    Passed =:= Discovered,
    Failed =:= 0,
    Timeout =:= 0,
    Blocked =:= 0,
    Fixme =:= 0.

% String/atom tolerance: in-memory records use atoms for some fields while a
% JSON round trip produces strings; both representations must validate.
dict_field_equal(Record, Key, Expected) :-
    get_dict(Key, Record, Actual),
    value_equal(Actual, Expected).

value_equal(Actual, Expected) :-
    Actual == Expected,
    !.
value_equal(Actual, Expected) :-
    atom(Actual),
    string(Expected),
    !,
    atom_string(Actual, Expected).
value_equal(Actual, Expected) :-
    string(Actual),
    atom(Expected),
    atom_string(Actual, Expected).

result_status(Discovered,
              Planned,
              Completed,
              Passed,
              Failed,
              Timeout,
              Blocked,
              Fixme,
              pass) :-
    Discovered > 0,
    Planned =:= Discovered,
    Completed =:= Planned,
    Passed =:= Discovered,
    Failed =:= 0,
    Timeout =:= 0,
    Blocked =:= 0,
    Fixme =:= 0,
    !.
result_status(_, _, _, _, _, _, _, _, fail).

registered_test_suites(Suites) :-
    findall(Unit, plunit:current_test_unit(Unit, _), Units),
    sort(Units, Suites).

same_test_suites(Expected, Registered) :-
    sort(Expected, Normalized),
    length(Expected, ExpectedCount),
    length(Normalized, ExpectedCount),
    Normalized == Registered.

aggregate_test_counts([], [], 0).
aggregate_test_counts([Suite|Suites], [Count|Counts], Total) :-
    findall(Test,
            plunit:current_test(Suite, Test, _, _, _),
            Tests),
    length(Tests, Count),
    aggregate_test_counts(Suites, Counts, Rest),
    Total is Count + Rest.

positive_count(Count) :-
    Count > 0.

summary_counts(Summary, Planned, Passed, Failed, Timeout, Blocked, Fixme) :-
    get_dict(total, Summary, Planned),
    get_dict(passed, Summary, Passed),
    get_dict(failed, Summary, Failed),
    get_dict(timeout, Summary, Timeout),
    get_dict(blocked, Summary, Blocked),
    get_dict(fixme, Summary, Fixme).

completed_test_count(Count) :-
    findall(Unit-Test-Line,
            (   plunit:passed(Unit, Test, Line, _, _)
            ;   plunit:failed(Unit, Test, Line, _, _)
            ;   plunit:timeout(Unit, Test, Line, _, _)
            ),
            Raw),
    sort(Raw, Records),
    length(Records, Count).

completed_result_counts(Passed, Failed, Timeout, Blocked, Fixme) :-
    findall(Unit-Test-Line, plunit:passed(Unit, Test, Line, _, _), PassedTests),
    findall(Unit-Test-Line, plunit:failed(Unit, Test, Line, _, _), FailedTests),
    findall(Unit-Test-Line, plunit:blocked(Unit, Test, Line, _), BlockedTests),
    findall(Unit-Test-Line, plunit:fixme(Unit, Test, Line, _, _), FixmeTests),
    length(PassedTests, Passed),
    length(FailedTests, Failed),
    timeout_count(Timeout),
    length(BlockedTests, Blocked),
    length(FixmeTests, Fixme).

timeout_count(Count) :-
    findall(Unit-Test-Line,
            (   plunit:timeout(Unit, Test, Line, _, _)
            ;   plunit:failed(Unit, Test, Line, Reason, _),
                timeout_reason(Reason)
            ),
            Raw),
    sort(Raw, Records),
    length(Records, Count).

timeout_reason(throw(time_limit_exceeded(_))).
timeout_reason(time_limit_exceeded(_)).

report(SuiteCount,
       Discovered,
       Planned,
       Completed,
       Passed,
       Failed,
       Timeout,
       Blocked,
       Fixme,
       Status,
       Phase) :-
    Record = _{
        schema: "prolog-rlm.plunit.v1",
        phase: Phase,
        status: Status,
        suites: SuiteCount,
        discovered: Discovered,
        planned: Planned,
        completed: Completed,
        passed: Passed,
        failed: Failed,
        timeout: Timeout,
        blocked: Blocked,
        fixme: Fixme
    },
    (   getenv('PLUNIT_GATE_REPORT', Path),
        Path \= ''
    ->  setup_call_cleanup(
            open(Path, write, Stream),
            ( json_write_dict(Stream, Record, [width(0)]),
              nl(Stream) ),
            close(Stream))
    ;   true
    ).
