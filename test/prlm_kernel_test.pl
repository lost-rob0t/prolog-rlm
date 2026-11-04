:- begin_tests(prlm_kernel).

:- use_module('../prolog/prlm_kernel').
:- use_module(library(yall)).

% ============================================================
% Helpers
% ============================================================

fresh(Engine) :-
    prlm_engine_new([max_steps(500000)], Engine).

solutions(Engine, Text, Rows) :-
    prlm_query_solutions(Engine, Text, 1000, Rows).

values(Engine, Text, Var, Values) :-
    solutions(Engine, Text, Rows),
    rows_var(Rows, Var, Values).

rows_var([], _, []).
rows_var([Row|Rows], Var, [V|Vs]) :-
    (   get_dict(Var, Row, V) -> true ; V = none ),
    rows_var(Rows, Var, Vs).

rows_of(Source, Text, Rows) :-
    fresh(E),
    prlm_consult_source(E, user, Source, test),
    solutions(E, Text, Rows),
    prlm_engine_destroy(E).

rows_var_is(Source, Text, Var, Expected) :-
    rows_of(Source, Text, Rows),
    rows_var(Rows, Var, Values),
    Values == Expected.

tmp_source_file(Name, Source, File) :-
    format(atom(File), '/tmp/opencode/prlm_test_~w.prlm', [Name]),
    atom_string(SourceAtom, Source),
    setup_call_cleanup(
        open(File, write, S),
        write(S, SourceAtom),
        close(S)).

% ============================================================
% Terms, unification, backtracking
% ============================================================

test(terms_atoms_numbers_structures) :-
    fresh(E),
    solutions(E, "X = foo.", Rows),
    Rows == [row{'X':foo}],
    solutions(E, "X = bar(1, qux(baz)).", Rows2),
    Rows2 == [row{'X':bar(1,qux(baz))}],
    solutions(E, "X = 42.", Rows3),
    Rows3 == [row{'X':42}],
    prlm_engine_destroy(E).

test(lists_are_terms) :-
    fresh(E),
    solutions(E, "X = [a, b, c].", Rows),
    Rows == [row{'X':[a,b,c]}],
    solutions(E, "[H|T] = [a, b, c].", Rows2),
    Rows2 == [row{'H':a, 'T':[b,c]}],
    prlm_engine_destroy(E).

test(unification_structural) :-
    fresh(E),
    solutions(E, "foo(X, b) = foo(a, Y).", Rows),
    Rows == [row{'X':a, 'Y':b}],
    prlm_engine_destroy(E).

test(unification_fails_on_mismatch) :-
    fresh(E),
    solutions(E, "foo(a) = foo(b).", Rows),
    Rows == [],
    solutions(E, "a = b.", Rows2),
    Rows2 == [],
    prlm_engine_destroy(E).

test(occurs_check_option) :-
    prlm_engine_new([occurs_check(true)], E),
    solutions(E, "X = f(X).", Rows),
    Rows == [],
    prlm_engine_destroy(E),
    % default: no occurs check (standard Prolog behaviour)
    fresh(E2),
    solutions(E2, "X = f(X).", _),
    prlm_engine_destroy(E2).

test(backtracking_order_is_deterministic_dfs) :-
    rows_var_is("p(1). p(2). p(3).", "p(X).", 'X', [1, 2, 3]).

test(variables_shared_across_conjunction) :-
    rows_of("p(a). q(a). p(b).", "p(X), q(X).", Rows),
    Rows == [row{'X':a}].

% ============================================================
% Control: conjunction, disjunction, cut, if-then-else
% ============================================================

test(conjunction) :-
    rows_of("p(a). q(b).", "p(X), q(Y).", Rows),
    Rows == [row{'X':a, 'Y':b}].

test(disjunction) :-
    rows_var_is("", "(X = left ; X = right).", 'X', [left, right]).

test(cut_limits_clause_choice) :-
    rows_var_is("q(1) :- !. q(2).", "q(X).", 'X', [1]).

test(cut_in_disjunction_commits) :-
    rows_var_is("x(1).", "(X = 1, ! ; X = 2).", 'X', [1]).

test(cut_after_disjunction_kills_alternatives) :-
    rows_of("x(1).", "(X = 1 ; X = 2), !, Y = X.", Rows),
    Rows == [row{'X':1, 'Y':1}].

test(cut_kills_later_clauses_of_enclosing_predicate) :-
    rows_var_is("outer(R) :- (X = 1 ; X = 2), !, R = X.\nouter(two).",
                "outer(R).", 'R', [1]).

test(cut_scope_is_per_clause_not_global) :-
    rows_var_is("p(a) :- !.\np(b).\nq(1).\nq(2).",
                "p(X), q(Y).", 'Y', [1, 2]).

test(if_then_else_then_branch) :-
    rows_of("", "(1 < 2 -> X = then ; X = else).", Rows),
    Rows == [row{'X':then}].

test(if_then_else_else_branch) :-
    rows_of("", "(1 > 2 -> X = then ; X = else).", Rows),
    Rows == [row{'X':else}].

test(if_then_no_else_fails_when_condition_fails) :-
    rows_of("", "(fail -> X = set).", Rows),
    Rows == [].

test(if_then_commits_condition_alternatives) :-
    rows_var_is("c(1). c(2).", "(c(X) -> Y = once).", 'Y', [once]).

test(negation_as_failure) :-
    rows_of("", "\\+(fail).", Rows),
    length(Rows, 1).

test(negation_fails_when_goal_succeeds) :-
    rows_of("", "\\+(true).", Rows),
    Rows == [].

test(once_commits_to_first_solution) :-
    rows_var_is("m(a). m(b).", "once(m(X)).", 'X', [a]).

test(forall_holds) :-
    rows_of("n(1). n(2). n(3).", "forall(n(X), X > 0).", Rows),
    length(Rows, 1).

test(forall_fails_on_counterexample) :-
    fresh(E),
    prlm_consult_source(E, user, "n(1). n(2). n(3)."),
    \+ solutions(E, "forall(n(X), X < 2).", _Rows),
    prlm_engine_destroy(E).

% ============================================================
% Recursion and arithmetic
% ============================================================

test(recursion_factorial) :-
    rows_var_is("fact(0, 1) :- !.\nfact(N, F) :- N > 0, M is N - 1, fact(M, F0), F is N * F0.",
                "fact(10, F).", 'F', [3628800]).

test(recursion_list_length_in_language) :-
    rows_var_is("len([], 0).\nlen([_|T], N) :- len(T, N0), N is N0 + 1.",
                "len([a, b, c, d, e], N).", 'N', [5]).

test(arithmetic_expressions) :-
    rows_var_is("", "X is (3 + 4) * 2 - 6 // 4.", 'X', [13]).

test(arithmetic_comparisons) :-
    rows_of("", "1 < 2, 2 =< 2, 3 > 2, 3 >= 3, 4 =:= 4, 4 =\\= 5.", Rows),
    length(Rows, 1).

test(arithmetic_deep_recursion_500) :-
    rows_var_is("sum_to(0, 0) :- !.\nsum_to(N, S) :- N > 0, M is N - 1, sum_to(M, S0), S is S0 + N.",
                "sum_to(500, S).", 'S', [125250]).

test(arithmetic_instantiation_error_is_host_error) :-
    % engine errors are host errors, not machine balls: catch/3 cannot trap
    % them; the host layer sees prlm_error(instantiation_error, _).
    catch(rows_of("", "X is Y + 1.", _Rows),
          prlm_error(instantiation_error, _),
          true).

test(arithmetic_division_by_zero_raises) :-
    catch(rows_of("", "X is 1 // 0.", _Rows),
          prlm_error(type_error, _),
          true).

% ============================================================
% findall / call / catch-throw
% ============================================================

test(findall_collects_all_solutions) :-
    rows_var_is("n(1). n(2). n(3).", "findall(X, n(X), L).", 'L', [[1, 2, 3]]).

test(findall_empty) :-
    rows_var_is("", "findall(X, fail, L).", 'L', [[]]).

test(call_n_with_computed_goal) :-
    rows_var_is("double(X, Y) :- Y is X * 2.",
                "G = double(21), call(G, R).", 'R', [42]).

test(catch_matches_ball_and_recovers) :-
    rows_var_is("boom :- throw(oops(42)).",
                "catch(boom, oops(N), R = got(N)).", 'R', [got(42)]).

test(catch_passes_through_non_matching_ball) :-
    % ball does not match the pattern: it escapes the catch, then the machine
    catch(rows_of("boom2 :- throw(other).",
                  "catch(boom2, oops(N), R = got(N)).", _Rows),
          prlm_error(uncaught_throw, Info),
          get_dict(ball, Info, other)).

test(uncaught_ball_escapes_machine) :-
    fresh(E),
    prlm_consult_source(E, user, "boom3 :- throw(kaboom)."),
    catch(prlm_query_solutions(E, "boom3.", 10, _),
          prlm_error(uncaught_throw, Info),
          get_dict(ball, Info, kaboom)),
    prlm_engine_destroy(E).

test(catch_backtracking_enters_body_alternatives) :-
    rows_var_is("z(1). z(2).",
                "catch((X = 1 ; X = 2), _, fail).", 'X', [1, 2]).

% ============================================================
% Term inspection builtins
% ============================================================

test(functor_arg_univ) :-
    rows_of("",
            "functor(t(a, b), F, A), arg(1, t(a, b), X), t(a, b) =.. L.", Rows),
    Rows == [row{'F':t, 'A':2, 'X':a, 'L':[t, a, b]}].

test(copy_term_is_fresh) :-
    rows_of("", "X = f(Y), copy_term(X, C), C = f(7).", Rows),
    length(Rows, 1).

test(structural_equality) :-
    rows_of("", "foo(a) == foo(a), foo(a) \\== foo(b).", Rows),
    length(Rows, 1).

test(type_checks) :-
    rows_of("", "atom(hello), number(3), integer(3), compound(f(x)), nonvar(1).", Rows),
    length(Rows, 1).

test(var_check) :-
    rows_of("", "var(V).", Rows),
    length(Rows, 1).

test(length_builtin) :-
    rows_var_is("", "length([a, b, c], N).", 'N', [3]).

test(standard_order_compare) :-
    rows_of("", "compare(O, 1, 2), O = (<).", Rows),
    length(Rows, 1).

% ============================================================
% Dynamic database
% ============================================================

test(assertz_retract_clause_roundtrip) :-
    fresh(E),
    prlm_consult_source(E, user, "seed(0)."),
    solutions(E, "assertz(df(a)), assertz(df(b)).", _),
    values(E, "df(X).", 'X', [a, b]),
    solutions(E, "clause(df(X), true).", RowsClause),
    length(RowsClause, 2),
    solutions(E, "retract(df(a)).", _),
    values(E, "df(X).", 'X', [b]),
    prlm_engine_destroy(E).

test(runtime_assert_visible_to_recursion) :-
    rows_var_is("reach(X, [X]) :- goal(X).\nreach(X, [X|P]) :- edge(X, Y), reach(Y, P).\ngoal(d).\nedge(a, b). edge(b, c). edge(c, d).",
                "reach(a, P).", 'P', [[a, b, c, d]]).

% ============================================================
% Budgets
% ============================================================

test(step_budget_is_enforced) :-
    prlm_engine_new([max_steps(50)], E),
    prlm_consult_source(E, user, "loop :- loop."),
    catch(prlm_query_solutions(E, "loop.", 10, _),
          prlm_error(budget_exceeded, Info),
          get_dict(limit, Info, 50)),
    !,
    prlm_engine_destroy(E).

test(steps_are_counted) :-
    fresh(E),
    prlm_consult_source(E, user, "p(1). p(2)."),
    solutions(E, "p(X).", _),
    prlm_engine_stats(E, steps(N)),
    N > 0,
    prlm_engine_destroy(E).

% ============================================================
% Modules and source loading
% ============================================================

test(module_definition_and_qualified_calls) :-
    fresh(E),
    prlm_consult_source(E, graph,
        ":- module(graph, [edge/2, path/2]).\nedge(a, b). edge(b, c).\npath(X, Y) :- edge(X, Y).\npath(X, Y) :- edge(X, Z), path(Z, Y).", mtest),
    solutions(E, "graph:path(a, c).", _),
    prlm_engine_destroy(E).

test(module_exports_hide_private_predicates) :-
    fresh(E),
    prlm_consult_source(E, priv,
        ":- module(priv, [open_pred/1]).\nopen_pred(1).\nsecret_pred(2).", ptest),
    % explicit qualification reaches any predicate of the module
    solutions(E, "priv:open_pred(X).", _),
    solutions(E, "priv:secret_pred(X).", _),
    % unqualified resolution from another module only sees exported names
    prlm_consult_source(E, client,
        ":- module(client, [call_export/1]).\n:- use_module(priv).\ncall_export(X) :- open_pred(X).", ctest),
    solutions(E, "client:call_export(X).", _),
    catch((   prlm_consult_source(E, client2,
                  ":- module(client2, [call_private/1]).\ncall_private(X) :- secret_pred(X).", c2test),
              solutions(E, "client2:call_private(X).", _),
              fail
          ),
          prlm_error(existence_error, _),
          true),
    prlm_engine_destroy(E).

test(use_module_imports_exports) :-
    tmp_source_file_named("mod_a.prlm", ":- module(mod_a, [val/1]).\nval(42).\n", FileA),
    tmp_source_file_named("mod_b.prlm",
        ":- module(mod_b, [double/2]).\n:- use_module(mod_a).\ndouble(X, Y) :- val(V), Y is X * V.\n", FileB),
    fresh(E),
    prlm_consult(E, FileB),
    solutions(E, "mod_b:double(2, Y).", Rows),
    Rows == [row{'Y':84}],
    prlm_engine_destroy(E),
    catch(delete_file(FileA), _, true),
    catch(delete_file(FileB), _, true).

tmp_source_file_named(Base, Source, File) :-
    atom_concat('/tmp/opencode/', Base, File),
    atom_string(SourceAtom, Source),
    setup_call_cleanup(
        open(File, write, S),
        write(S, SourceAtom),
        close(S)).

test(consult_is_idempotent_per_engine) :-
    tmp_source_file(idem, ":- module(idem, [v/1]).\nv(1).\n", File),
    fresh(E),
    prlm_consult(E, File),
    prlm_consult(E, File),
    values(E, "idem:v(X).", 'X', [1]),
    prlm_engine_destroy(E),
    catch(delete_file(File), _, true).

test(export_of_undefined_predicate_is_load_error) :-
    fresh(E),
    catch(prlm_consult_source(E, bad, ":- module(bad, [missing/1]).\npresent(1).\n", btest),
          prlm_error(directive_error, Info),
          get_dict(export_undefined, Info, bad:missing/1)),
    prlm_engine_destroy(E).

test(unknown_directive_is_load_error_unless_hooked) :-
    fresh(E),
    catch(prlm_consult_source(E, u, ":- mystery_directive(1).\n", utest),
          prlm_error(directive_error, Info),
          get_dict(directive, Info, mystery_directive(1))),
    prlm_engine_destroy(E),
    % hooked directive is accepted
    assertz(prlm_kernel:prlm_load_directive(_, _, mystery_directive(_))),
    fresh(E2),
    prlm_consult_source(E2, user, ":- mystery_directive(1).\nok(1).", u2test),
    solutions(E2, "ok(X).", _),
    prlm_engine_destroy(E2),
    retractall(prlm_kernel:prlm_load_directive(_, _, mystery_directive(_))).

test(syntax_error_reports_location) :-
    fresh(E),
    catch(prlm_consult_source(E, s, "p(1.\n", stest),
          prlm_error(syntax_error, Info),
          get_dict(file, Info, stest)),
    !,
    prlm_engine_destroy(E).

test(initialization_directive_runs_after_load) :-
    fresh(E),
    prlm_consult_source(E, user,
        ":- dynamic(count/1).\n:- initialization(assertz(count(loaded))).\n", initest),
    values(E, "count(X).", 'X', [loaded]),
    prlm_engine_destroy(E).

test(clause_provenance_records_source) :-
    tmp_source_file(prov, ":- module(prov, [px/1]).\npx(1).\n", File),
    fresh(E),
    prlm_consult(E, File),
    prlm_clause_src(E, prov, px/1, [File-2]),
    prlm_engine_destroy(E),
    catch(delete_file(File), _, true).

% ============================================================
% Untrusted-text boundary and projections
% ============================================================

test(read_goal_is_inert_data) :-
    prlm_read_goal("assertz(danger), X = 1.", Goal, _),
    Goal = (assertz(danger), '$v'('X') = 1),
    % the read goal is a term, never executed; running it in a fresh engine
    % with no such hazard is safe and yields just the binding
    fresh(E),
    prlm_query_all(E, Goal, 10, Envs),
    Envs == [env{'X':1}],
    prlm_engine_destroy(E).

test(read_goal_rejects_reserved_functor) :-
    catch(prlm_read_goal("f('$v'(x)).", _, _),
          prlm_error(type_error, Info),
          get_dict(reserved_functor, Info, '$v')).

test(solutions_are_ground_rows) :-
    fresh(E),
    prlm_consult_source(E, user, "p(a)."),
    solutions(E, "p(X).", Rows),
    Rows == [row{'X':a}],
    forall(member(Row, Rows), ground(Row)),
    prlm_engine_destroy(E).

% ============================================================
% Host primitive whitelist
% ============================================================

test(host_primitive_whitelist_is_stable) :-
    findall(P, prlm_host_primitive(P), Ps0),
    sort(Ps0, Ps),
    Ps == [atom_number_ops/1,
           dict_ops/1,
           dynamic_state/1,
           list_walk/1,
           path_file_ops/1,
           sorting/1,
           source_reader/1,
           structural_ops/1].

% ============================================================
% Test helpers
% ============================================================

:- end_tests(prlm_kernel).
