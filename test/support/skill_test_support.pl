:- module(skill_test_support,
          [ reset_capture/0,
            capture_planner/2,
            captured_prompt/1
          ]).

:- dynamic captured_prompt/1.

reset_capture :-
    retractall(captured_prompt(_)).

capture_planner(Request, ok(Output)) :-
    get_dict(messages, Request, [Message|_]),
    get_dict(content, Message, Prompt),
    assertz(captured_prompt(Prompt)),
    Plan = plan([final(literal("skill-ok"))]),
    Output = planner_output{plan:Plan,
                            usage:_{prompt_tokens:1,
                                    completion_tokens:1,
                                    total_tokens:2,
                                    cost:0.0}}.
