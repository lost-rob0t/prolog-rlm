from pathlib import Path

path = Path('prolog/rlm_graph.pl')
text = path.read_text()
old = '''emit_event(Config, Snapshot0, Type, Fields, Snapshot) :-
    Sequence is Snapshot0.event_sequence+1,
    Event = graph_event{sequence:Sequence,
                        type:Type,
                        run_id:Snapshot0.run_id,
                        graph_id:Snapshot0.graph_id,
                        fields:Fields},
    backend_append_event(Config.backend,
                         Snapshot0.run_id,
                         Sequence,
                         Event),
    call_event_handler(Config.event_handler, Event),
    put_dict(event_sequence, Snapshot0, Sequence, Snapshot).
'''
new = '''emit_event(Config, Snapshot0, Type, Fields0, Snapshot) :-
    Sequence is Snapshot0.event_sequence+1,
    canonical_graph_value(Fields0, Fields),
    Event = graph_event{sequence:Sequence,
                        type:Type,
                        run_id:Snapshot0.run_id,
                        graph_id:Snapshot0.graph_id,
                        fields:Fields},
    backend_append_event(Config.backend,
                         Snapshot0.run_id,
                         Sequence,
                         Event),
    call_event_handler(Config.event_handler, Event),
    put_dict(event_sequence, Snapshot0, Sequence, Snapshot).

canonical_graph_value(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_graph_pair, Pairs0, Pairs),
    dict_pairs(Value, graph_data, Pairs).
canonical_graph_value(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_graph_value, Values0, Values).
canonical_graph_value(Value, Value) :-
    atomic(Value),
    !.
canonical_graph_value(Value, Value) :-
    ground(Value),
    !.
canonical_graph_value(Value, _) :-
    throw(graph_fault(stream, non_ground_event_value(Value))).

canonical_graph_pair(Key-Value0, Key-Value) :-
    atom(Key),
    !,
    canonical_graph_value(Value0, Value).
canonical_graph_pair(Key-_, _) :-
    throw(graph_fault(stream, invalid_event_field_key(Key))).
'''
if text.count(old) != 1:
    raise SystemExit('emit_event block mismatch')
path.write_text(text.replace(old, new, 1))
print('persistent event payloads canonicalized')
