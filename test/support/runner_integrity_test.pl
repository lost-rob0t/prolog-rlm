:- begin_tests(runner_integrity).

:- use_module(library(filesex)).
:- use_module(library(http/json), [json_read_dict/2]).
:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module('../deterministic_runner.pl', [report_is_valid/1]).

test(known_focused_runner_cannot_replace_aggregate_main) :-
    run_script('test/runner_main_ownership_probe.pl', [], Status, Output),
    assertion(Status == exit(0)),
    assertion(sub_string(Output, _, _, _, "aggregate_main_owner=probe")),
    assertion(\+ sub_string(Output, _, _, _, "canonical_async_case=")),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_complete")),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_summary")).

test(arbitrary_future_main_is_rejected_before_loading) :-
    run_script('test/support/runner_hostile_guard_probe.pl', [], Status, Output),
    assertion(Status == exit(0)),
    assertion(sub_string(Output, _, _, _, "aggregate_main")),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_complete")).

test(replacement_main_sentinels_are_not_aggregate_evidence) :-
    tmp_file( runner_integrity_report, Report),
    setup_call_cleanup(
        true,
        ( run_script_with_report('test/support/runner_partial_spoof.pl',
                                 [], Report, Status, Output),
          assertion(Status == exit(0)),
          assertion(sub_string(Output, _, _, _,
                               "aggregate_plunit_complete")),
          assertion(\+ exists_file(Report)) ),
        catch(delete_file(Report), _, true)).

test(inconsistent_report_counts_are_invalid) :-
    Valid = _{
        schema: "prolog-rlm.plunit.v1",
        phase: complete,
        status: pass,
        suites: 1,
        discovered: 2,
        planned: 2,
        completed: 2,
        passed: 2,
        failed: 0,
        timeout: 0,
        blocked: 0,
        fixme: 0
    },
    assertion(report_is_valid(Valid)),
    Bad = Valid.put(planned, 1),
    assertion(\+ report_is_valid(Bad)).

test(load_error_after_registration_is_nonzero) :-
    run_script('test/support/runner_unstrict_load_probe.pl', [],
               UnstrictStatus,
               UnstrictOutput),
    assertion(UnstrictStatus == exit(0)),
    assertion(sub_string(UnstrictOutput, _, _, _,
                         "runner_unstrict_registered_suite_passed")),
    assertion(sub_string(UnstrictOutput, _, _, _, "Initialization goal raised exception")),
    run_script('test/support/runner_strict_load_probe.pl', [],
               StrictStatus,
               _),
    assertion(StrictStatus \== exit(0)).

test(missing_included_file_is_nonzero) :-
    run_script('test/support/runner_missing_file_probe.pl', [], Status, _),
    assertion(Status \== exit(0)).

test(unregistered_candidate_is_rejected) :-
    run_script('test/support/runner_inventory_probe.pl', [], Status, _),
    assertion(Status == exit(0)).

test(early_late_and_multiple_failures_are_nonzero) :-
    run_scenario(failures, Status, Output),
    assertion(Status \== exit(0)),
    assertion(sub_string(Output, _, _, _, "failed=3")),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_complete")).

test(blocked_test_is_not_complete) :-
    run_scenario(blocked, Status, Output),
    assertion(Status \== exit(0)),
    assertion(sub_string(Output, _, _, _, "blocked=1")),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_complete")).

test(condition_skipped_test_is_not_complete) :-
    run_scenario(condition, Status, Output),
    assertion(Status \== exit(0)),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_complete")).

test(suite_setup_failure_is_nonzero) :-
    run_scenario(setup, Status, Output),
    assertion(Status \== exit(0)),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_complete")).

test(duplicate_test_names_are_both_discovered) :-
    run_scenario(duplicate, Status, Output),
    assertion(Status == exit(0)),
    assertion(sub_string(Output, _, _, _,
                         "aggregate_plunit_discovered suites=1 tests=2")),
    assertion(sub_string(Output, _, _, _,
                         "aggregate_plunit_complete suites=1 tests=2")).

test(per_test_timeout_is_nonzero) :-
    get_time(Start),
    run_scenario(timeout, Status, Output),
    get_time(Finish),
    Elapsed is Finish-Start,
    assertion(Status \== exit(0)),
    assertion(Elapsed < 35.0),
    assertion(sub_string(Output, _, _, _, "time_limit_exceeded(20.0)")),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_complete")).

test(signal_termination_is_not_success) :-
    absolute_file_name('test/support/runner_signal_probe.pl', Script,
                       [access(read)]),
    process_create(path(swipl), ['-q', '-s', Script],
                   [process(Pid), stdout(null), stderr(null)]),
    process_kill(Pid, term),
    process_wait(Pid, Status),
    assertion(Status \== exit(0)).

test(empty_selection_cannot_report_success) :-
    run_scenario(empty, Status, Output),
    assertion(Status \== exit(0)),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_discovered")),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_complete")).

test(subset_execution_cannot_report_success) :-
    run_scenario(subset, Status, Output),
    assertion(Status \== exit(0)),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_discovered")),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_complete")).

test(passing_scenario_writes_valid_report) :-
    tmp_file(runner_integrity_pass, Report),
    setup_call_cleanup(
        true,
        ( run_script_with_report('test/support/run_runner_scenario.pl',
                                 [passing], Report, Status, Output),
          assertion(Status == exit(0)),
          assertion(sub_string(Output, _, _, _,
                               "aggregate_plunit_complete suites=1 tests=1")),
          setup_call_cleanup(
              open(Report, read, Stream),
              json_read_dict(Stream, Record),
              close(Stream)),
          assertion(report_is_valid(Record)) ),
        catch(delete_file(Report), _, true)).

test(whole_run_budget_is_bounded_inside_a_test) :-
    get_time(Start),
    run_scenario(slow, Status, Output),
    get_time(Finish),
    Elapsed is Finish-Start,
    assertion(Status \== exit(0)),
    assertion(Elapsed < 10.0),
    assertion(sub_string(Output, _, _, _, "time_limit_exceeded")),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_complete")).

test(whole_run_budget_aborts_between_tests) :-
    get_time(Start),
    run_scenario(budget_setup, Status, Output),
    get_time(Finish),
    Elapsed is Finish-Start,
    assertion(Status \== exit(0)),
    assertion(Elapsed < 10.0),
    assertion(sub_string(Output, _, _, _, "aggregate_plunit_abort")),
    assertion(\+ sub_string(Output, _, _, _, "aggregate_plunit_complete")).

run_scenario(Name, Status, Output) :-
    run_script('test/support/run_runner_scenario.pl', [Name], Status, Output).

run_script(Relative, Arguments, Status, Output) :-
    absolute_file_name(Relative, Script, [access(read)]),
    append(['-q', '-s', Script, '--'], Arguments, ProcessArguments),
    process_create(path(swipl), ProcessArguments,
                   [ process(Pid),
                     stdout(pipe(Stdout)),
                     stderr(pipe(Stderr))
                   ]),
    read_string(Stdout, _, StandardOutput),
    read_string(Stderr, _, ErrorOutput),
    close(Stdout),
    close(Stderr),
    process_wait(Pid, Status),
    string_concat(StandardOutput, ErrorOutput, Output).

run_script_with_report(Relative, Arguments, Report, Status, Output) :-
    absolute_file_name(Relative, Script, [access(read)]),
    append(['-q', '-s', Script, '--'], Arguments, ProcessArguments),
    process_create(path(swipl), ProcessArguments,
                   [ process(Pid),
                     stdout(pipe(Stdout)),
                     stderr(pipe(Stderr)),
                     environment(['PLUNIT_GATE_REPORT'=Report])
                   ]),
    read_string(Stdout, _, StandardOutput),
    read_string(Stderr, _, ErrorOutput),
    close(Stdout),
    close(Stderr),
    process_wait(Pid, Status),
    string_concat(StandardOutput, ErrorOutput, Output).

:- end_tests(runner_integrity).
