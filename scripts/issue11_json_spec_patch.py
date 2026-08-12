from pathlib import Path

path = Path('prolog/rlm_agent.pl')
text = path.read_text()
old = '''normalize_agent_spec(agent_spec(Name), Spec) :-
    !,
    require_name_atom(Name, Normalized),
    Spec = agent_spec{name:Normalized, mode:worker, metadata:_{}}.
normalize_agent_spec(Spec0, Spec) :-
    is_dict(Spec0),
    !,
    (   ground(Spec0)
    ->  true
    ;   throw(agent_fault(non_ground_agent_spec))
    ),
    dict_value_default(name, Spec0, anonymous, Name0),
    dict_value_default(mode, Spec0, worker, Mode0),
    dict_value_default(metadata, Spec0, _{}, Metadata),
    require_name_atom(Name0, Name),
    require_name_atom(Mode0, Mode),
    (   is_dict(Metadata), ground(Metadata)
    ->  true
    ;   throw(agent_fault(invalid_agent_metadata(Metadata)))
    ),
    Spec = agent_spec{name:Name, mode:Mode, metadata:Metadata}.
normalize_agent_spec(Spec, _) :-
    throw(agent_fault(invalid_agent_spec(Spec))).
'''
new = '''normalize_agent_spec(agent_spec(Name), Spec) :-
    !,
    require_name_atom(Name, Normalized),
    Spec = agent_spec{name:Normalized,
                      mode:worker,
                      metadata:agent_metadata{}}.
normalize_agent_spec(Spec0, Spec) :-
    is_dict(Spec0),
    !,
    dict_value_default(name, Spec0, anonymous, Name0),
    dict_value_default(mode, Spec0, worker, Mode0),
    dict_value_default(metadata, Spec0, agent_metadata{}, Metadata0),
    require_name_atom(Name0, Name),
    require_name_atom(Mode0, Mode),
    normalize_agent_metadata(Metadata0, Metadata),
    Spec = agent_spec{name:Name, mode:Mode, metadata:Metadata}.
normalize_agent_spec(Spec, _) :-
    throw(agent_fault(invalid_agent_spec(Spec))).

normalize_agent_metadata(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(normalize_agent_metadata_pair, Pairs0, Pairs),
    dict_pairs(Value, agent_metadata, Pairs).
normalize_agent_metadata(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(normalize_agent_metadata, Values0, Values).
normalize_agent_metadata(Value, Value) :-
    atomic(Value),
    !.
normalize_agent_metadata(Value, _) :-
    throw(agent_fault(invalid_agent_metadata(Value))).

normalize_agent_metadata_pair(Key-Value0, Key-Value) :-
    atom(Key),
    !,
    normalize_agent_metadata(Value0, Value).
normalize_agent_metadata_pair(Key-_, _) :-
    throw(agent_fault(invalid_agent_metadata_key(Key))).
'''
if text.count(old) != 1:
    raise SystemExit('expected exactly one normalize_agent_spec block')
path.write_text(text.replace(old, new, 1))
print('json agent spec canonicalization applied')
