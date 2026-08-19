:- initialization(main, main).

:- use_module(library(http/json)).
:- use_module('../prolog/deepseek_prolog_bridge').
:- use_module('../prolog/deepseek_prolog_settings').

main(Argv) :-
    settings_path(Argv, SettingsPath),
    deepseek_prolog_bridge:deepseek_bridge_open(SettingsPath, OpenOutcome),
    (   OpenOutcome = ok(_)
    ->  setup_call_cleanup(
            true,
            request_loop,
            deepseek_prolog_bridge:deepseek_bridge_close(_)),
        halt(0)
    ;   OpenOutcome = error(Error),
        write_wire(_{protocol:"prolog_rlm_deepseek_bridge_v1",
                     request_id:null,
                     ok:false,
                     error:Error}),
        halt(1)
    ).

settings_path([], Path) :-
    !,
    deepseek_prolog_settings:deepseek_settings_default_path(Path).
settings_path(["--settings", Path0], Path) :-
    !,
    atom_string(Path, Path0).
settings_path([Path], Path) :-
    atom(Path),
    !.
settings_path(Argv, _) :-
    format(user_error,
           'usage: deepseek-prolog-bridge.pl [--settings PATH]~nreceived: ~q~n',
           [Argv]),
    halt(2).

request_loop :-
    read_line_to_string(user_input, Line),
    (   Line == end_of_file
    ->  true
    ;   (   Line == ""
        ->  true
        ;   handle_line(Line)
        ),
        request_loop
    ).

handle_line(Line) :-
    catch(( atom_string(Atom, Line),
            atom_json_dict(Atom, Request, []),
            deepseek_prolog_bridge:deepseek_bridge_handle(Request, Response)
          ),
          Exception,
          parse_error_response(Exception, Response)),
    write_wire(Response).

parse_error_response(Exception,
                     _{protocol:"prolog_rlm_deepseek_bridge_v1",
                       request_id:null,
                       ok:false,
                       error:Text}) :-
    with_output_to(string(Text),
                   write_term(Exception,
                              [ quoted(true),
                                portray(false),
                                max_depth(12)
                              ])).

write_wire(Response) :-
    json_write_dict(current_output, Response, [width(0)]),
    nl,
    flush_output.
