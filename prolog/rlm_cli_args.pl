:- module(rlm_cli_args,
          [ cli_atom_arg/2,
            cli_text_arg/2,
            cli_number_arg/2,
            cli_positive_integer_arg/2,
            cli_positive_number_arg/2,
            cli_nonnegative_number_arg/2,
            cli_require_member/3
          ]).

/** <module> Shared typed-argument validators for CLI parsers

Behavior-preserving extraction from rlm_cli.pl (RLM-DESIGN-574-a, slice 1).
The validators throw `cli_fault/1` terms; callers decide how faults map to
exit codes. pswarm reuses this layer so there is no second argument parser.
*/

cli_atom_arg(Value, Value) :- atom(Value), !.
cli_atom_arg(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
cli_atom_arg(Value, _) :- throw(cli_fault(invalid_argument(Value))).

cli_text_arg(Value, Value) :- string(Value), !.
cli_text_arg(Value, Text) :- atom(Value), !, atom_string(Value, Text).
cli_text_arg(Value, _) :- throw(cli_fault(invalid_text_argument(Value))).

cli_number_arg(Value, Value) :- number(Value), !.
cli_number_arg(Value, Number) :- atom(Value), atom_number(Value, Number), !.
cli_number_arg(Value, Number) :- string(Value), number_string(Number, Value), !.
cli_number_arg(Value, _) :- throw(cli_fault(invalid_number(Value))).

cli_positive_integer_arg(Value, Number) :-
    cli_number_arg(Value, Number), integer(Number), Number > 0, !.
cli_positive_integer_arg(Value, _) :-
    throw(cli_fault(invalid_positive_integer(Value))).

cli_positive_number_arg(Value, Number) :-
    cli_number_arg(Value, Number), Number > 0, !.
cli_positive_number_arg(Value, _) :-
    throw(cli_fault(invalid_positive_number(Value))).

cli_nonnegative_number_arg(Value, Number) :-
    cli_number_arg(Value, Number), Number >= 0, !.
cli_nonnegative_number_arg(Value, _) :-
    throw(cli_fault(invalid_nonnegative_number(Value))).

cli_require_member(Value, Allowed, _) :- memberchk(Value, Allowed), !.
cli_require_member(Value, _, Name) :-
    throw(cli_fault(invalid_option(Name, Value))).
