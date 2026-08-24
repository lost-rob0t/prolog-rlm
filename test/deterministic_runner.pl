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
          run_aborted(Suites, SuiteCount, Discovered, Exception)).

run_bounded(Expected, SuiteCount, Discovered, TestTimeout) :-
    plunit_run(Expected,
               TestTimeout,
               Discovered,
               Planned,
               Completed,
               Passed,
               Failed,
               Timeout,
               Blocked,
               Fixme),
    finish_run(SuiteCount,
               Discovered,
               Planned,
               Completed,
               Passed,
               Failed,
               Timeout,
               Blocked,
               Fixme).

plunit_run(Expected,
           TestTimeout,
           _,
           Planned,
           Completed,
           Passed,
           Failed,
           Timeout,
           Blocked,
           Fixme) :-
    current_predicate(plunit:run_tests/2),
    !,
    run_tests(Expected,
              [ summary(Summary),
                timeout(TestTimeout),
                cleanup(false)
              ]),
    get_dict(total, Summary, Planned),
    expected_result_counts(Expected,
                           Completed,
                           Passed,
                           Failed,
                           Timeout,
                           Blocked,
                           Fixme).
plunit_run(Expected,
           TestTimeout,
           Discovered,
           Discovered,
           Completed,
           Passed,
           Failed,
           Timeout,
           Blocked,
           Fixme) :-
    set_test_options([cleanup(false)]),
    legacy_run_suites(Expected,
                      TestTimeout,
                      counts(0, 0, 0, 0, 0, 0),
                      counts(Completed,
                             Passed,
                             Failed,
                             Timeout,
                             Blocked,
                             Fixme)).

legacy_run_suites([], _, Counts, Counts).
legacy_run_suites([Suite|Suites], TestTimeout, Counts0, Counts) :-
    legacy_run_suite(Suite, TestTimeout),
    expected_result_counts([Suite],
                           Completed,
                           Passed,
                           Failed,
                           Timeout,
                           Blocked,
                           Fixme),
    Counts0 = counts(C0, P0, F0, T0, B0, X0),
    Counts1 = counts(C1, P1, F1, T1, B1, X1),
    C1 is C0+Completed,
    P1 is P0+Passed,
    F1 is F0+Failed,
    T1 is T0+Timeout,
    B1 is B0+Blocked,
    X1 is X0+Fixme,
    legacy_run_suites(Suites, TestTimeout, Counts1, Counts).

legacy_run_suite(Suite, TestTimeout) :-
    Limit is float(TestTimeout),
    catch(call_with_time_limit(Limit,
                               ignore(run_tests([Suite]))),
          Exception,
          legacy_run_exception(Exception, Limit)).

legacy_run_exception(time_limit_exceeded, Limit) :-
    !,
    throw(time_limit_exceeded(Limit)).
legacy_run_exception(Exception, _) :-
    throw(Exception).

finish_run(SuiteCount,
           Discovered,
           Planned,
           Completed,
           Passed,
           Failed,
           Timeout,
           Blocked,
           Fixme) :-
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

run_aborted(Expected, SuiteCount, Discovered, Exception) :-
    expected_result_counts(Expected,
                           Completed,
                           Passed,
                           Failed,
                           Timeout,
                           Blocked,
                           Fixme),
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

expected_result_counts(Expected,
                       Completed,
                       Passed,
                       Failed,
                       Timeout,
                       Blocked,
                       Fixme) :-
    expected_records(Expected, passed, PassedRecords),
    expected_records(Expected, failed, FailedRecords),
    expected_records(Expected, timeout, TimeoutRecords),
    expected_records(Expected, blocked, BlockedRecords),
    expected_records(Expected, fixme, FixmeRecords),
    append([PassedRecords, FailedRecords, TimeoutRecords], CompletedRaw),
    sort(CompletedRaw, CompletedRecords),
    length(CompletedRecords, Completed),
    length(PassedRecords, Passed),
    length(FailedRecords, Failed),
    length(TimeoutRecords, Timeout),
    length(BlockedRecords, Blocked),
    length(FixmeRecords, Fixme).

expected_records(Expected, Kind, Records) :-
    findall(Unit-Test-Line,
            expected_result(Expected, Kind, Unit, Test, Line),
            Raw),
    sort(Raw, Records).

expected_result(Expected, passed, Unit, Test, Line) :-
    member(Unit, Expected),
    plunit:passed(Unit, Test, Line, _, _).
expected_result(Expected, failed, Unit, Test, Line) :-
    member(Unit, Expected),
    plunit_failed(Unit, Test, Line, Reason),
    \+ timeout_reason(Reason).
expected_result(Expected, timeout, Unit, Test, Line) :-
    member(Unit, Expected),
    (   plunit_timeout(Unit, Test, Line)
    ;   plunit_failed(Unit, Test, Line, Reason),
        timeout_reason(Reason)
    ).
expected_result(Expected, blocked, Unit, Test, Line) :-
    member(Unit, Expected),
    plunit:blocked(Unit, Test, Line, _).
expected_result(Expected, fixme, Unit, Test, Line) :-
    member(Unit, Expected),
    plunit:fixme(Unit, Test, Line, _, _).

plunit_failed(Unit, Test, Line, Reason) :-
    (   current_predicate(plunit:failed/5)
    ->  plunit:failed(Unit, Test, Line, Reason, _)
    ;   plunit:failed(Unit, Test, Line, Reason)
    ).

plunit_timeout(Unit, Test, Line) :-
    current_predicate(plunit:timeout/5),
    plunit:timeout(Unit, Test, Line, _, _).

timeout_reason(throw(time_limit_exceeded(_))).
timeout_reason(time_limit_exceeded(_)).
timeout_reason(time_limit_exceeded).

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
