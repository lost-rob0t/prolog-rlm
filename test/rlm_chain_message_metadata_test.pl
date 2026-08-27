:- begin_tests(rlm_chain_message_metadata).

:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_tool_projection').

test(assistant_tool_history_is_preserved_and_ground) :-
    Input = _{role:assistant,
              content:"",
              tool_calls:[_{id:"call-1",
                            type:"function",
                            function:_{name:"lookup", arguments:"{}"}}],
              reasoning:"checked context",
              reasoning_details:[_{type:"reasoning.text",
                                   text:"checked context"}]},
    message_normalize(Input, ok(Message)),
    assertion(ground(Message)),
    Message.tool_calls = [Call],
    assertion(Call.id == "call-1"),
    assertion(Call.function.name == "lookup"),
    assertion(Message.reasoning == "checked context"),
    Message.reasoning_details = [Detail],
    assertion(Detail.type == "reasoning.text").

test(tool_result_correlation_is_preserved) :-
    Input = _{role:tool,
              content:"result",
              tool_call_id:"call-1",
              name:"lookup"},
    message_normalize(Input, ok(Message)),
    assertion(Message.tool_call_id == "call-1"),
    assertion(Message.name == "lookup").

test(projection_preset_full_is_canonical) :-
    result_visibility_preset(full, ok(Projection)),
    assertion(Projection ==
              result_projection{initial:full,
                                after_consumption:full,
                                retention:durable,
                                retrievable:true}).

test(projection_preset_once_is_canonical) :-
    result_visibility_preset(once, ok(Projection)),
    assertion(Projection.initial == full),
    assertion(Projection.after_consumption == none),
    assertion(Projection.retention == durable),
    assertion(Projection.retrievable == true).

test(projection_preset_reference_is_canonical) :-
    result_visibility_preset(reference, ok(Projection)),
    assertion(Projection.initial == reference),
    assertion(Projection.after_consumption == reference).

test(projection_preset_hidden_is_canonical) :-
    result_visibility_preset(hidden, ok(Projection)),
    assertion(Projection.initial == none),
    assertion(Projection.after_consumption == none).

test(projection_preset_string_normalizes) :-
    result_visibility_preset("once", ok(Projection)),
    assertion(Projection.after_consumption == none).

test(invalid_projection_preset_fails_structurally) :-
    result_visibility_preset(telepathy, error(Error)),
    assertion(Error.kind == validation_error),
    assertion(Error.detail == invalid_visibility_preset(telepathy)).

test(canonical_projection_dict_round_trips) :-
    Input = _{initial:"full",
              after_consumption:"none",
              retention:"durable",
              retrievable:true},
    result_projection_normalize(Input, ok(Projection)),
    assertion(Projection ==
              result_projection{initial:full,
                                after_consumption:none,
                                retention:durable,
                                retrievable:true}).

test(tool_message_projection_is_canonical_and_ground) :-
    Input = _{role:tool,
              content:"result",
              tool_call_id:"call-1",
              name:"lookup"},
    tool_message_projection(Input, once, ok(Message)),
    assertion(ground(Message)),
    assertion(Message.role == tool),
    assertion(Message.tool_call_id == "call-1"),
    assertion(Message.result_projection.initial == full),
    assertion(Message.result_projection.after_consumption == none).

test(non_tool_message_projection_is_rejected) :-
    Input = _{role:assistant, content:"no tool result here"},
    tool_message_projection(Input, once, error(Error)),
    assertion(Error.kind == validation_error),
    assertion(Error.detail == expected_tool_message(assistant)).

test(tool_result_projection_is_canonical_and_ground) :-
    Input = _{tool:lookup,
              call_id:"call-1",
              value:"result"},
    tool_result_projection(Input, reference, ok(Result)),
    assertion(ground(Result)),
    dict_pairs(Result, tool_result, _),
    assertion(Result.tool == lookup),
    assertion(Result.result_projection.initial == reference),
    assertion(Result.result_projection.after_consumption == reference).

test(nonground_tool_result_payload_is_rejected) :-
    Input = _{tool:lookup,
              call_id:"call-1",
              value:_Unbound},
    tool_result_projection(Input, reference, error(Error)),
    assertion(Error.kind == validation_error),
    Error.detail = invalid_tool_result(Rejected),
    assertion(is_dict(Rejected)).

:- end_tests(rlm_chain_message_metadata).
