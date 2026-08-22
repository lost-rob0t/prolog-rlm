runner_load_error :-
    throw(error(runner_load_error,
                context(runner_load_error_after,
                        'intentional load-time failure'))).

:- initialization(runner_load_error, now).
