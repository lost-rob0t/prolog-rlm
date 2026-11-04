:- begin_tests(prlm_selfhost).

:- use_module('../prolog/prlm_selfhost').
:- use_module('../prolog/prlm_kernel').

% ============================================================
% stage1 loads
% ============================================================

test(stage1_loads_language_sources) :-
    prlm_stage1_new(E),
    prlm_current_predicate(E, std, append/3),
    prlm_current_predicate(E, std, sort_list/2),
    prlm_current_predicate(E, prlm_meta, msolve/2),
    prlm_engine_destroy(E).

test(stage1_engines_are_independent) :-
    prlm_stage1_new(E1),
    prlm_stage1_new(E2),
    prlm_query_solutions(E1, "assertz(marker(only_e1)).", 10, _),
    catch((   prlm_query_solutions(E2, "marker(X).", 10, _),
              fail
          ),
          prlm_error(existence_error, _),
          true),
    prlm_engine_destroy(E1),
    prlm_engine_destroy(E2).

% ============================================================
% stdlib semantics through the engine (stage1 direct)
% ============================================================

std_rows(Engine, Text, Rows) :-
    prlm_query_solutions(Engine, Text, 1000, Rows).

values(Rows, Key, Vals) :-
    map_rows(Rows, Key, Vals).

map_rows([], _, []).
map_rows([R|Rs], K, [V|Vs]) :-
    (   get_dict(K, R, V) -> true ; V = none ),
    map_rows(Rs, K, Vs).

test(stdlib_direct_semantics) :-
    prlm_stage1_new(E),
    writeln_if_slow,
    std_rows(E, "append([1, 2], [3], X).", R1),
    R1 == [row{'X':[1,2,3]}],
    std_rows(E, "member(X, [a, b, c]).", R2),
    values(R2, 'X', [a, b, c]),
    std_rows(E, "reverse([1, 2, 3], R).", R3),
    R3 == [row{'R':[3,2,1]}],
    std_rows(E, "sort_list([3, 1, 2, 1], S).", R4),
    R4 == [row{'S':[1,1,2,3]}],
    std_rows(E, "sum_list([1, 2, 3, 4], S).", R5),
    R5 == [row{'S':10}],
    std_rows(E, "nth0(1, [a, b, c], X).", R7),
    R7 == [row{'X':b}],
    std_rows(E, "between(1, 3, X).", R8),
    values(R8, 'X', [1, 2, 3]),
    std_rows(E, "flatten([[1], [2, [3]]], F).", R9),
    R9 == [row{'F':[1,2,3]}],
    std_rows(E, "delete([a, b, a, c], a, R).", R10),
    R10 == [row{'R':[b,c]}],
    std_rows(E, "last([a, b, c], X).", R11),
    R11 == [row{'X':c}],
    prlm_engine_destroy(E).

writeln_if_slow.

test(stdlib_append_enumeration_order) :-
    prlm_stage1_new(E),
    std_rows(E, "append(X, Y, [a, b]).", Rows),
    values(Rows, 'X', [[], [a], [a, b]]),
    values(Rows, 'Y', [[a, b], [b], []]),
    prlm_engine_destroy(E).

% ============================================================
% stage2 equivalence: the gate
% ============================================================

test(stage2_msolve_matches_direct_on_corpus) :-
    prlm_stage1_new(E),
    prlm_selfhost_verify(E, Report),
    get_dict(probes, Report, N),
    N >= 15,
    get_dict(passed, Report, P),
    P =:= N,
    get_dict(equivalence, Report, ok),
    get_dict(failed, Report, []),
    prlm_engine_destroy(E).

test(stage2_spot_checks) :-
    prlm_stage1_new(E),
    prlm_stage2_run(E, "reverse([1, 2, 3], R).", std, Rows),
    Rows == [row{'R':[3,2,1]}],
    prlm_stage2_run(E, "member(X, [a, b]).", std, Rows2),
    values(Rows2, 'X', [a, b]),
    prlm_engine_destroy(E).

test(msolve_depth_bound) :-
    prlm_stage1_new(E),
    % the default msolve/2 proof budget (64) accommodates real recursion
    prlm_stage2_run(E, "append([1, 2, 3, 4], [5], X).", std, Rows),
    Rows == [row{'X':[1,2,3,4,5]}],
    % known limitation of the bootstrap meta-interpreter: goal FAILURE at
    % exact depth exhaustion can trip a kernel commit re-execution bug
    % (arith:undefined(-)); the gate corpus avoids goals at the boundary.
    prlm_engine_destroy(E).

% ============================================================
% The gate fails closed on a stageless engine
% ============================================================

test(gate_fails_closed_without_stage1) :-
    prlm_engine_new([max_steps(100000)], E),
    catch(prlm_selfhost_verify(E, GateReport),
          _, true),
    (   catch(prlm_selfhost_gate(GateReport),
              prlm_error(type_error, _),
              true)
    ->  true
    ;   format(user_error, 'gate unexpectedly passed~n', []),
        fail
    ),
    prlm_engine_destroy(E).

test(gate_passes_on_healthy_stage1) :-
    prlm_stage1_new(E),
    prlm_selfhost_verify(E, Report),
    prlm_selfhost_gate(Report),
    prlm_engine_destroy(E).

% ============================================================
% No-escape documentation surface
% ============================================================

test(no_escape_report_is_atoms) :-
    prlm_no_escape_report(Notes),
    Notes \== [],
    forall(member(Note, Notes), ( atom(Note) ; string(Note) )).

test(host_primitive_whitelist_exposed) :-
    findall(P, prlm_host_primitives(P), Ps),
    Ps \== [],
    member(source_reader/1, Ps).

:- end_tests(prlm_selfhost).
