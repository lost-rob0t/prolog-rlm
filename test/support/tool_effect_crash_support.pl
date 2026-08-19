:- module(tool_effect_crash_support,
          [ crash_write_schema/1,
            crash_write_tool/2,
            crash_mutation_file_read/2,
            set_crash_mutation_file/1
          ]).

:- dynamic crash_mutation_file/1.

set_crash_mutation_file(File) :-
    retractall(crash_mutation_file(_)),
    assertz(crash_mutation_file(File)).

/** <module> File-backed write tool for the tool-effect crash fixture.

   The handler records an externally observable side effect in a file and
   then blocks until the parent process kills it.  The durable effect ledger
   is never used as the externally observable counter. */

crash_write_schema(Schema) :-
    Schema = tool_schema{name:crash_write,
                         description:"file-backed write tool for crash fixture",
                         capability:tool(crash_write),
                         effect:write,
                         arguments:_{type:object,
                                     required:[value],
                                     additional_properties:false,
                                     properties:_{value:_{type:integer}}},
                         result:_{type:object,
                                  required:[seen,count],
                                  additional_properties:false,
                                  properties:_{seen:_{type:integer},
                                               count:_{type:integer}}},
                         limits:_{time_limit:30.0, max_output_bytes:4096}}.

crash_write_tool(Args, json{seen:Value, count:Count}) :-
    get_dict(value, Args, Value),
    (   crash_mutation_file(File)
    ->  true
    ;   File = '/tmp/rlm-tool-crash-mutation.term'
    ),
    crash_mutation_bump(File, Count),
    format(user_output, 'remote_committed~n', []),
    flush_output,
    message_queue_create(Block),
    thread_get_message(Block, never_released).

crash_mutation_bump(File, Count) :-
    (   exists_file(File)
    ->  crash_mutation_file_read(File, Count0)
    ;   Count0 = 0
    ),
    Count is Count0+1,
    setup_call_cleanup(
        open(File, write, Stream, [encoding(utf8)]),
        format(Stream, 'mutation_count(~w).~n', [Count]),
        close(Stream)).

crash_mutation_file_read(File, Count) :-
    setup_call_cleanup(
        open(File, read, Stream, [encoding(utf8)]),
        read_term(Stream, Term, []),
        close(Stream)),
    (   Term = mutation_count(Count)
    ->  true
    ;   Count = 0 ).
