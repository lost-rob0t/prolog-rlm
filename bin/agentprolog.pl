:- initialization(main, main).

:- prolog_load_context(directory, BinDir),
   directory_file_path(BinDir, '../prolog', CoreDir),
   ( exists_directory(CoreDir)
   -> asserta(user:file_search_path(library, CoreDir))
   ;  true
   ),
   directory_file_path(BinDir, '../agentProlog/prolog', AgentDir),
   asserta(user:file_search_path(agentprolog, AgentDir)).

:- use_module(agentprolog(agentprolog_cli)).

main(Argv) :-
    agentprolog_cli:agentprolog_cli_execute(Argv, ExitCode),
    halt(ExitCode).
