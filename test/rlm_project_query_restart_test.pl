:- begin_tests(rlm_project_query_restart).

:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module(library(filesex)).

test(project_query_observations_reload_in_a_fresh_process) :-
    tmp_file(project_query_restart, Root),
    make_directory_path(Root),
    setup_call_cleanup(
        true,
        ( run_killed_phase('test/rlm_project_query_restart_phase1.pl', Root),
          run_phase('test/rlm_project_query_restart_phase2.pl', Root)
        ),
        catch(delete_directory_and_contents(Root), _, true)).

run_phase(RelativeScript, Root) :-
    absolute_file_name(RelativeScript, Script, [access(read)]),
    process_create(path(swipl),
                   ['-q', '-s', Script, '--', Root],
                   [process(Pid), stdout(pipe(Out))]),
    setup_call_cleanup(
        true,
        ( read_line_to_string(Out, Marker),
          assertion(Marker == "query_kb_phase_complete"),
          process_wait(Pid, Status),
          assertion(Status == exit(0))
        ),
        ( catch(close(Out), _, true),
          catch(process_kill(Pid, kill), _, true),
          catch(process_wait(Pid, _), _, true)
        )
    ).

run_killed_phase(RelativeScript, Root) :-
    absolute_file_name(RelativeScript, Script, [access(read)]),
    process_create(path(swipl),
                   ['-q', '-s', Script, '--', Root],
                   [process(Pid), stdin(pipe(In)), stdout(pipe(Out))]),
    setup_call_cleanup(
        true,
        ( read_line_to_string(Out, Marker),
          assertion(Marker == "query_kb_phase_complete"),
          process_kill(Pid, kill),
          process_wait(Pid, Status),
          assertion(Status = killed(_))
        ),
        ( catch(close(In), _, true),
          catch(close(Out), _, true),
          catch(process_kill(Pid, kill), _, true),
          catch(process_wait(Pid, _), _, true)
        )
    ).

:- end_tests(rlm_project_query_restart).
