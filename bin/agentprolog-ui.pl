:- initialization(main, main).

:- prolog_load_context(directory, BinDir),
   directory_file_path(BinDir, '../prolog', CoreDir),
   ( exists_directory(CoreDir)
   -> asserta(user:file_search_path(library, CoreDir))
   ;  true
   ),
   directory_file_path(BinDir, '../agentProlog/prolog', AgentDir),
   asserta(user:file_search_path(agentprolog, AgentDir)).

:- use_module(agentprolog(agentprolog_ui)).

main([]) :-
    !,
    agentprolog_ui:agentprolog_ui_server_loop(user_input, user_output),
    halt(0).
main(_) :-
    format(user_error,
           'usage: agentprolog-ui < prolog_agent_ui_v1.ndjson~n',
           []),
    halt(2).
