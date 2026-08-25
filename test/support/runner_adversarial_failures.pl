:- begin_tests(runner_adversarial_failures).

test(early_failure) :-
    fail.

test(middle_pass) :-
    true.

test(late_failure) :-
    fail.

test(second_late_failure) :-
    fail.

:- end_tests(runner_adversarial_failures).
