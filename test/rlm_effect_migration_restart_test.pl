:- begin_tests(rlm_effect_migration_restart).

:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_effect_migration').
:- use_module(effect_legacy_fixture).
:- use_module(library(process)).
:- use_module(library(readutil)).

crash_phase(source_locked).
crash_phase(source_validated).
crash_phase(backup_complete).
crash_phase(data_flushed).
crash_phase(validated).
crash_phase(before_publication).
crash_phase(after_publication).
crash_phase(published).

test(crash_matrix_converges_without_identity_change,
     [forall(crash_phase(Phase))]) :-
    migration_restart_paths(Phase, Source, Destination),
    setup_call_cleanup(
        legacy_fixture_create(Source, Details),
        ( run_crash_worker(crash, Phase, Source, Destination, Status),
          assertion(Status == exit(97)),
          finish_after_crash(Source, Destination, Report),
          assertion(memberchk(Report.status, [migrated,already_migrated])),
          rlm_effect_store_open(Destination),
          rlm_effect_status(Details.uncertain_attempt, Attempt),
          assertion(Attempt.idempotency_key ==
                    Details.uncertain_provider_key),
          rlm_effect_observation(Details.observed_attempt, Observation),
          assertion(Observation == Details.observation),
          rlm_effect_store_close ),
        cleanup_restart_paths([Source,Destination])).

test(sigkill_at_validated_stage_is_recoverable) :-
    migration_restart_paths(sigkill, Source, Destination),
    setup_call_cleanup(
        legacy_fixture_create(Source, Details),
        ( start_pause_worker(validated, Source, Destination, Pid, In, Out),
          read_line_to_string(Out, Marker),
          assertion(Marker == "migration_phase_ready validated"),
          process_kill(Pid, kill),
          process_wait(Pid, Killed),
          assertion(Killed = killed(_)),
          close(In), close(Out),
          effect_store_migrate(_{source:Source,output:Destination}, Report),
          assertion(Report.status == migrated),
          rlm_effect_store_open(Destination),
          rlm_effect_status(Details.uncertain_attempt, Attempt),
          assertion(Attempt.idempotency_key ==
                    Details.uncertain_provider_key),
          rlm_effect_store_close ),
        cleanup_restart_paths([Source,Destination])).

finish_after_crash(Source, Destination, Report) :-
    ( exists_file(Destination)
    -> effect_store_migrate(_{source:Destination,output:Source}, Report)
    ;  effect_store_migrate(_{source:Source,output:Destination}, Report) ).

run_crash_worker(Mode, Phase, Source, Destination, Status) :-
    worker_arguments(Mode, Phase, Source, Destination, Arguments),
    process_create(path(swipl), Arguments, [process(Pid)]),
    process_wait(Pid, Status).

start_pause_worker(Phase, Source, Destination, Pid, In, Out) :-
    worker_arguments(pause, Phase, Source, Destination, Arguments),
    process_create(path(swipl), Arguments,
                   [process(Pid),stdin(pipe(In)),stdout(pipe(Out))]).

worker_arguments(Mode, Phase, Source, Destination, Arguments) :-
    absolute_file_name('test/effect_migration_crash_worker.pl', Script,
                       [access(read)]),
    Arguments = ['-q','-s',Script,'--',Mode,Phase,Source,Destination].

migration_restart_paths(Tag, Source, Destination) :-
    tmp_file(effect_migration_restart, Base),
    atomic_list_concat([Base,'-',Tag,'.legacy'], Source),
    atom_concat(Source, '.v2', Destination).

cleanup_restart_paths(Paths) :-
    catch(rlm_effect_store_close, _, true),
    forall(member(Path, Paths),
           ( catch(delete_file(Path), _, true),
             atom_concat(Path, '.lock', Lock),
             catch(delete_file(Lock), _, true),
             atom_concat(Path, '.migrating', Temp),
             catch(delete_file(Temp), _, true),
             atom_concat(Temp, '.lock', TempLock),
             catch(delete_file(TempLock), _, true) )).

:- end_tests(rlm_effect_migration_restart).
