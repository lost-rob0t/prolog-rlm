:- module(effect_restart_support,
          [ crash_request/1,
            remote_submit/3,
            remote_read/2,
            assert_remote_count/2
          ]).

crash_request(request{provider:fake_remote,
                      operation:generate,
                      payload:payload{prompt:"crash-window-fixture"}}).

remote_submit(File, IdempotencyKey, Result) :-
    (   exists_file(File)
    ->  remote_read(File, Existing),
        Count0 = Existing.submit_count
    ;   Count0 = 0
    ),
    Count is Count0+1,
    Result = remote_result{job_id:fake_job_1,
                           value:"effect-recorded"},
    State = remote_state{idempotency_key:IdempotencyKey,
                         submit_count:Count,
                         result:Result},
    setup_call_cleanup(
        open(File, write, Stream, [encoding(utf8)]),
        ( write_term(Stream, State,
                     [quoted(true), fullstop(true), nl(true)]),
          flush_output(Stream) ),
        close(Stream)).

remote_read(File, State) :-
    setup_call_cleanup(
        open(File, read, Stream, [encoding(utf8)]),
        read_term(Stream, State, []),
        close(Stream)).

assert_remote_count(File, Expected) :-
    remote_read(File, State),
    (   State.submit_count =:= Expected
    ->  true
    ;   format(user_error,
               'unexpected fake remote submit count: expected ~w got ~w~n',
               [Expected, State.submit_count]),
        fail
    ).
