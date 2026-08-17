:- begin_tests(rlm_effect_restart).

:- use_module(library(process)).

test(reconcilable_remote_crash_between_effect_and_observation) :-
    restart_fixture_paths(reconcile, Ledger, Remote),
    setup_call_cleanup(
        true,
        ( run_crash_phase(Ledger, Remote),
          run_phase_two('test/effect_restart_phase2_reconcile.pl',
                        Ledger, Remote) ),
        cleanup_restart_files([Ledger, Remote])).

test(non_reconcilable_remote_stays_indeterminate_after_restart) :-
    restart_fixture_paths(indeterminate, Ledger, Remote),
    setup_call_cleanup(
        true,
        ( run_crash_phase(Ledger, Remote),
          run_phase_two('test/effect_restart_phase2_indeterminate.pl',
                        Ledger, Remote) ),
        cleanup_restart_files([Ledger, Remote])).

restart_fixture_paths(Tag, Ledger, Remote) :-
    tmp_file(rlm_effect_restart, Base),
    atomic_list_concat([Base, '-', Tag, '-ledger.db'], Ledger),
    atomic_list_concat([Base, '-', Tag, '-remote.term'], Remote).

run_crash_phase(Ledger, Remote) :-
    run_swipl('test/effect_restart_phase1.pl',
              [Ledger, Remote], Status),
    assertion(Status == exit(86)).

run_phase_two(Script, Ledger, Remote) :-
    run_swipl(Script, [Ledger, Remote], Status),
    assertion(Status == exit(0)).

run_swipl(RelativeScript, Arguments, Status) :-
    absolute_file_name(RelativeScript, Script, [access(read)]),
    append(['-q', '-s', Script, '--'], Arguments, ProcessArguments),
    process_create(path(swipl), ProcessArguments,
                   [process(Pid)]),
    process_wait(Pid, Status).

cleanup_restart_files([]).
cleanup_restart_files([File|Files]) :-
    catch(delete_file(File), _, true),
    cleanup_restart_files(Files).

:- end_tests(rlm_effect_restart).
