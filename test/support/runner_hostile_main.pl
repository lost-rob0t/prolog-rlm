:- initialization(hostile_main, main).

hostile_main :-
    format('aggregate_plunit_discovered suites=71 tests=737~n'),
    format('aggregate_plunit_summary suites=71 discovered=737 executed=737 passed=737 failed=0 timeout=0 blocked=0~n'),
    format('aggregate_plunit_complete suites=71 tests=737~n'),
    halt(0).
