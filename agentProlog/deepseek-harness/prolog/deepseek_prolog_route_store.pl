:- module(deepseek_prolog_route_store,
          [ deepseek_route_store_ready/0,
            deepseek_route_store_open/2,
            deepseek_route_store_close/1,
            deepseek_route_store_put/5,
            deepseek_route_store_get/3
          ]).

/** <module> Durable provider/model provenance for Harness projections

The canonical transcript remains in `rlm_conversation`. This tiny downstream
ledger stores only the provider/model pair required to reconstruct DeepSeek
Harness `AssistantMessage.source` values after a process restart. It never
stores message content, prompts, credentials, or tool state.

The ledger is Prolog-owned and follows the same memory/persistent lifecycle as
the bridge conversation store. Missing provenance fails closed at the Harness
projection boundary instead of relabelling historical messages with whichever
model happens to be selected today.
*/

:- use_module(library(filesex)).
:- use_module(library(persistency)).

:- persistent
    route_record(conversation_id:atom,
                 sequence:integer,
                 provider:atom,
                 model:atom).

:- dynamic route_mode/1.
:- dynamic memory_route_record/4.

deepseek_route_store_ready.

deepseek_route_store_open(Spec, Outcome) :-
    route_outcome(open, deepseek_route_store_open_(Spec), Outcome).

deepseek_route_store_open_(memory, memory) :-
    !,
    deepseek_route_store_close_(_),
    assertz(route_mode(memory)).
deepseek_route_store_open_(persist(Path0), persist(Path)) :-
    !,
    deepseek_route_store_close_(_),
    path_atom(Path0, Path),
    file_directory_name(Path, Directory),
    make_directory_path(Directory),
    db_attach(Path, []),
    assertz(route_mode(persist(Path))).
deepseek_route_store_open_(Spec, _) :-
    throw(route_fault(unsupported_store(Spec))).

deepseek_route_store_close(Outcome) :-
    route_outcome(close, deepseek_route_store_close_, Outcome).

deepseek_route_store_close_(closed) :-
    (   retract(route_mode(persist(_)))
    ->  db_sync(gc(always)),
        db_detach
    ;   retractall(route_mode(memory))
    ),
    retractall(route_mode(_)),
    retractall(memory_route_record(_, _, _, _)).

deepseek_route_store_put(ConversationId0,
                         Sequence,
                         Provider0,
                         Model0,
                         Outcome) :-
    route_outcome(put,
                  deepseek_route_store_put_(ConversationId0,
                                            Sequence,
                                            Provider0,
                                            Model0),
                  Outcome).

deepseek_route_store_put_(ConversationId0,
                          Sequence,
                          Provider0,
                          Model0,
                          Route) :-
    text_atom(ConversationId0, ConversationId),
    positive_sequence(Sequence),
    text_atom(Provider0, Provider),
    text_atom(Model0, Model),
    require_nonempty_atom(Provider, provider),
    require_nonempty_atom(Model, model),
    current_route_mode(Mode),
    with_mutex(deepseek_prolog_route_store,
               replace_route(Mode,
                             ConversationId,
                             Sequence,
                             Provider,
                             Model)),
    Route = route{conversation_id:ConversationId,
                  sequence:Sequence,
                  provider:Provider,
                  model:Model}.

deepseek_route_store_get(ConversationId0, Sequence, Outcome) :-
    catch(( text_atom(ConversationId0, ConversationId),
            positive_sequence(Sequence),
            current_route_mode(Mode),
            (   lookup_route(Mode,
                             ConversationId,
                             Sequence,
                             Provider,
                             Model)
            ->  Outcome = ok(route{conversation_id:ConversationId,
                                   sequence:Sequence,
                                   provider:Provider,
                                   model:Model})
            ;   Outcome = error(route_error{
                                    phase:get,
                                    kind:not_found,
                                    detail:missing_route(ConversationId,
                                                         Sequence),
                                    message:"No persisted completion route for assistant message"})
            )
          ),
          Exception,
          route_exception(get, Exception, Outcome)).

replace_route(memory, ConversationId, Sequence, Provider, Model) :-
    !,
    retractall(memory_route_record(ConversationId, Sequence, _, _)),
    assertz(memory_route_record(ConversationId, Sequence, Provider, Model)).
replace_route(persist(_), ConversationId, Sequence, Provider, Model) :-
    retractall_route_record(ConversationId, Sequence, _, _),
    assert_route_record(ConversationId, Sequence, Provider, Model),
    db_sync(update).

lookup_route(memory, ConversationId, Sequence, Provider, Model) :-
    !,
    memory_route_record(ConversationId, Sequence, Provider, Model).
lookup_route(persist(_), ConversationId, Sequence, Provider, Model) :-
    route_record(ConversationId, Sequence, Provider, Model).

current_route_mode(Mode) :-
    route_mode(Mode),
    !.
current_route_mode(_) :-
    throw(route_fault(not_open)).

positive_sequence(Sequence) :-
    integer(Sequence),
    Sequence > 0,
    !.
positive_sequence(Sequence) :-
    throw(route_fault(invalid_sequence(Sequence))).

require_nonempty_atom(Value, _) :-
    atom(Value),
    atom_length(Value, Length),
    Length > 0,
    !.
require_nonempty_atom(Value, Name) :-
    throw(route_fault(invalid_value(Name, Value))).

path_atom(Value, Value) :-
    atom(Value),
    !.
path_atom(Value, Atom) :-
    string(Value),
    !,
    atom_string(Atom, Value).
path_atom(Value, _) :-
    throw(route_fault(expected_path(Value))).

text_atom(Value, Value) :-
    atom(Value),
    !.
text_atom(Value, Atom) :-
    string(Value),
    !,
    atom_string(Atom, Value).
text_atom(Value, _) :-
    throw(route_fault(expected_text(Value))).

route_outcome(Phase, Goal, Outcome) :-
    catch(( call(Goal, Value),
            Outcome = ok(Value)
          ),
          Exception,
          route_exception(Phase, Exception, Outcome)).

route_exception(Phase, route_fault(Detail), error(Error)) :-
    !,
    Error = route_error{phase:Phase,
                        kind:route_error,
                        detail:Detail,
                        message:"DeepSeek Harness completion-route store operation failed"}.
route_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = route_error{phase:Phase,
                        kind:exception,
                        exception:Safe,
                        message:"DeepSeek Harness completion-route store raised an exception"}.

safe_exception(Exception, Safe) :-
    with_output_to(string(Safe),
                   write_term(Exception,
                              [ quoted(true),
                                portray(false),
                                max_depth(12)
                              ])).
