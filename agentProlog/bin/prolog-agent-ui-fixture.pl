:- initialization(main, main).

:- use_module('../prolog/prolog_agent_ui_fixture').

main(_) :-
    ui_fixture_server_loop(user_input, user_output).
