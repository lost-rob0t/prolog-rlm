:- begin_tests(rlm_chain_message_metadata).

:- use_module('../prolog/rlm_chain').

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

:- end_tests(rlm_chain_message_metadata).
