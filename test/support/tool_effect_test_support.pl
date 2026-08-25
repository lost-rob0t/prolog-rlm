:- module(tool_effect_test_support,
          [ reset_tool_mutations/0,
            tool_mutation_count/1,
            tool_last_value/1,
            counting_write_tool/2,
            alternate_write_tool/2,
            gated_counting_write_tool/2,
            gated_alternate_write_tool/2,
            fresh_read_tool/2,
            blocking_write_tool/2,
            arm_binding_gate/0,
            await_binding_gate_entries/0,
            release_binding_gate/0,
            arm_blocking_gate/0,
            release_blocking_write/0,
            await_blocking_write_entered/0,
            write_schema/1,
            fresh_read_schema/1,
            blocking_write_schema/1,
            mutation_file_read/2
          ]).

/* Externally observable mutation counter independent of the effect ledger.
   Duplicate execution is detectable through this counter, not through the
   durable store. */
:- dynamic mutation_counter/1.
:- dynamic last_value/1.
:- dynamic blocking_gate/2.
:- dynamic binding_gate/2.

reset_tool_mutations :-
    retractall(mutation_counter(_)),
    retractall(last_value(_)),
    destroy_blocking_gates,
    destroy_binding_gates,
    assertz(mutation_counter(0)).

destroy_blocking_gates :-
    (   retract(blocking_gate(Entered, Release))
    ->  catch(message_queue_destroy(Entered), _, true),
        catch(message_queue_destroy(Release), _, true),
        destroy_blocking_gates
    ;   true ).

destroy_binding_gates :-
    (   retract(binding_gate(Entered, Release))
    ->  catch(message_queue_destroy(Entered), _, true),
        catch(message_queue_destroy(Release), _, true),
        destroy_binding_gates
    ;   true ).

tool_mutation_count(Count) :-
    (   mutation_counter(Count)
    ->  true
    ;   Count = 0
    ).

tool_last_value(Value) :-
    (   last_value(Value)
    ->  true
    ;   Value = none
    ).

record_mutation(Value) :-
    with_mutex(tool_effect_test_mutations,
               ( retract(mutation_counter(N0)),
                 N is N0+1,
                 assertz(mutation_counter(N)),
                 retractall(last_value(_)),
                 assertz(last_value(Value)) )).

counting_write_tool(Args, json{seen:Value, count:Count}) :-
    get_dict(value, Args, Value),
    record_mutation(Value),
    tool_mutation_count(Count).

/* Same schema/effect/preflight contract as counting_write_tool/2, but a
   materially different trusted execution binding with observably different
   output. This catches accidental cross-binding #57 replay. */
alternate_write_tool(Args, json{seen:Seen, count:Count}) :-
    counting_write_tool(Args, Base),
    Seen is Base.seen+1000,
    Count = Base.count.

gated_counting_write_tool(Args, Result) :-
    enter_binding_gate,
    counting_write_tool(Args, Result).

gated_alternate_write_tool(Args, Result) :-
    enter_binding_gate,
    alternate_write_tool(Args, Result).

enter_binding_gate :-
    binding_gate(Entered, Release),
    thread_send_message(Entered, entered),
    thread_get_message(Release, release).

arm_binding_gate :-
    destroy_binding_gates,
    message_queue_create(Entered),
    message_queue_create(Release),
    assertz(binding_gate(Entered, Release)).

await_binding_gate_entries :-
    binding_gate(Entered, _),
    thread_get_message(Entered, entered),
    thread_get_message(Entered, entered).

release_binding_gate :-
    binding_gate(_, Release),
    thread_send_message(Release, release),
    thread_send_message(Release, release).

fresh_read_tool(Args, json{seen:Value, count:Count}) :-
    get_dict(value, Args, Value),
    record_mutation(Value),
    tool_mutation_count(Count).

blocking_write_tool(Args, json{seen:Value, count:Count}) :-
    get_dict(value, Args, Value),
    blocking_gate(Entered, Release),
    thread_send_message(Entered, entered),
    thread_get_message(Release, release),
    record_mutation(Value),
    tool_mutation_count(Count).

arm_blocking_gate :-
    destroy_blocking_gates,
    message_queue_create(Entered),
    message_queue_create(Release),
    assertz(blocking_gate(Entered, Release)).

await_blocking_write_entered :-
    blocking_gate(Entered, _),
    thread_get_message(Entered, entered).

release_blocking_write :-
    (   blocking_gate(_, Release)
    ->  thread_send_message(Release, release)
    ;   true
    ).

write_schema(Schema) :-
    Schema = tool_schema{name:counting_write,
                         description:"effectful counting write fixture",
                         capability:tool(counting_write),
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
                         limits:_{time_limit:2.0, max_output_bytes:4096}}.

fresh_read_schema(Schema) :-
    Schema = tool_schema{name:fresh_read,
                         description:"read fixture that must not be memoized",
                         capability:tool(fresh_read),
                         effect:read,
                         arguments:_{type:object,
                                     required:[value],
                                     additional_properties:false,
                                     properties:_{value:_{type:integer}}},
                         result:_{type:object,
                                  required:[seen,count],
                                  additional_properties:false,
                                  properties:_{seen:_{type:integer},
                                               count:_{type:integer}}},
                         limits:_{time_limit:2.0, max_output_bytes:4096}}.

blocking_write_schema(Schema) :-
    Schema = tool_schema{name:blocking_write,
                         description:"effectful write that blocks for a gate",
                         capability:tool(blocking_write),
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
                         limits:_{time_limit:10.0, max_output_bytes:4096}}.

write_preflight(Args, Args, operation_details{target_path:"fixture://counting_write"}).

/* File-backed mutation recorder for fresh-process crash fixtures. The
   canonical effect ledger is not used as the externally observable counter. */
mutation_file_read(File, Count) :-
    setup_call_cleanup(
        open(File, read, Stream, [encoding(utf8)]),
        read_term(Stream, Recorded, []),
        close(Stream)),
    (   Recorded = mutation_count(Count)
    ->  true
    ;   Count = 0 ).
