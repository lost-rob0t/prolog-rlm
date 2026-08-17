:- begin_tests(rlm_effect_restart).

:- use_module(library(process)).
:- use_module(library(readutil)).

test(completed_observation_replays_after_fresh_process_restart) :-
    restart_fixture_paths(completed, Ledger, Remote),
    setup_call_cleanup(
        true,
        ( run_phase_two('test/effect_restart_phase1_completed.pl',
                        Ledger, Remote),
          run_phase_two('test/effect_restart_phase2_completed.pl',
                        Ledger, Remote) ),
        cleanup_restart_files([Ledger, Remote])).

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

test(effect_store_rejects_second_process_owner_and_recovers_after_sigkill) :-
    restart_store_path(owner, Ledger, LockFile),
    setup_call_cleanup(
        true,
        run_store_owner_fixture(Ledger),
        cleanup_restart_files([Ledger, LockFile])).

test(observation_only_crash_repairs_status_and_event_exactly_once) :-
    run_projection_crash_fixture(observation_only).

test(observed_revision_crash_repairs_event_exactly_once) :-
    run_projection_crash_fixture(attempt_observed).

run_projection_crash_fixture(Case) :-
    restart_fixture_paths(Case, Ledger, Remote),
    atom_concat(Ledger, '.state', State),
    atom_concat(Ledger, '.lock', Lock),
    setup_call_cleanup(
        true,
        ( run_projection_phase_one(Case, Ledger, State, Remote),
          run_swipl('test/effect_projection_crash_phase2.pl',
                    [Ledger, State, Remote], Status),
          assertion(Status == exit(0)) ),
        cleanup_restart_files([Ledger, Lock, State, Remote])).

run_projection_phase_one(Case, Ledger, State, Remote) :-
    absolute_file_name('test/effect_projection_crash_phase1.pl', Script,
                       [access(read)]),
    append(['-q', '-s', Script, '--'],
           [Case, Ledger, State, Remote], ProcessArguments),
    setup_call_cleanup(
        process_create(path(swipl), ProcessArguments,
                       [process(Pid),stdin(pipe(In)),stdout(pipe(Out))]),
        ( read_line_to_string(Out, Marker),
          assertion(Marker == "projection_boundary_durable"),
          process_kill(Pid, kill),
          process_wait(Pid, Killed),
          assertion(Killed = killed(_)) ),
        cleanup_owner_process(Pid, In, Out)).

restart_fixture_paths(Tag, Ledger, Remote) :-
    tmp_file(rlm_effect_restart, Base),
    atomic_list_concat([Base, '-', Tag, '-ledger.db'], Ledger),
    atomic_list_concat([Base, '-', Tag, '-remote.term'], Remote).

restart_store_path(Tag, Ledger, LockFile) :-
    tmp_file(rlm_effect_restart, Base),
    atomic_list_concat([Base, '-', Tag, '-ledger.db'], Ledger),
    atom_concat(Ledger, '.lock', LockFile).

run_store_owner_fixture(Ledger) :-
    absolute_file_name('test/effect_store_owner_phase1.pl', Script,
                       [access(read)]),
    append(['-q', '-s', Script, '--'], [Ledger], ProcessArguments),
    setup_call_cleanup(
        process_create(path(swipl), ProcessArguments,
                       [ process(Pid),
                         stdin(pipe(In)),
                         stdout(pipe(Out))
                       ]),
        ( read_line_to_string(Out, Marker),
          assertion(Marker == "owner_ready"),
          run_swipl('test/effect_store_contender.pl',
                    [Ledger, blocked],
                    BlockedStatus),
          assertion(BlockedStatus == exit(0)),
          process_kill(Pid, kill),
          process_wait(Pid, KilledStatus),
          assertion(KilledStatus = killed(_)),
          run_swipl('test/effect_store_contender.pl',
                    [Ledger, open],
                    ReopenStatus),
          assertion(ReopenStatus == exit(0)) ),
        cleanup_owner_process(Pid, In, Out)).

cleanup_owner_process(Pid, In, Out) :-
    catch(close(In), _, true),
    catch(close(Out), _, true),
    catch(process_kill(Pid, kill), _, true),
    catch(process_wait(Pid, _), _, true).

run_crash_phase(Ledger, Remote) :-
    absolute_file_name('test/effect_restart_phase1.pl', Script, [access(read)]),
    append(['-q', '-s', Script, '--'], [Ledger, Remote], ProcessArguments),
    setup_call_cleanup(
        process_create(path(swipl), ProcessArguments,
                       [process(Pid), stdout(pipe(Out))]),
        ( read_line_to_string(Out, Marker),
          assertion(Marker == "remote_committed"),
          process_kill(Pid, kill),
          process_wait(Pid, Status),
          assertion(Status = killed(_)) ),
        close(Out)).

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
