:- initialization(main, main).

:- use_module('../prolog/rlm_literate_org').

main(Argv) :-
    (   parse_args(Argv, Mode, OrgPath, Root)
    ->  run_mode(Mode, OrgPath, Root, Outcome),
        print_outcome(Outcome),
        exit_for_outcome(Mode, Outcome)
    ;   usage,
        halt(2)
    ).

parse_args(["--check", OrgPath], check, OrgPath, ".").
parse_args(["--check", OrgPath, Root], check, OrgPath, Root).
parse_args([OrgPath], tangle, OrgPath, ".").
parse_args([OrgPath, Root], tangle, OrgPath, Root).

run_mode(tangle, OrgPath, Root, Outcome) :-
    org_tangle_file(OrgPath, Root, Outcome).
run_mode(check, OrgPath, Root, Outcome) :-
    org_tangle_check(OrgPath, Root, Outcome).

print_outcome(Outcome) :-
    write_term(Outcome, [quoted(true), portray(true)]),
    nl.

exit_for_outcome(tangle, ok(_)) :- halt(0).
exit_for_outcome(check, ok(Check)) :-
    ( Check.status == current -> halt(0) ; halt(1) ).
exit_for_outcome(_, error(_)) :- halt(1).

usage :-
    format(user_error,
           'usage: swipl -q -s scripts/tangle-org-source.pl -- [--check] SOURCE.org [ROOT]~n',
           []).
