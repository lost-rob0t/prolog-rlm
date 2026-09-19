:- module(prlm_kernel,
          [ prlm_kernel_ready/0,
            prlm_engine_new/1,
            prlm_engine_new/2,
            prlm_engine_destroy/1,
            prlm_engine_stats/2,
            prlm_consult/2,
            prlm_consult_source/3,
            prlm_consult_source/4,
            prlm_query_solutions/4,
            prlm_query_all/4,
            prlm_query_all/5,
            prlm_query_first/3,
            prlm_query_first/4,
            prlm_assertz/3,
            prlm_retract_first/4,
            prlm_current_predicate/3,
            prlm_clause_src/4,
            prlm_module_exports/3,
            prlm_module_of_file/3,
            prlm_read_goal/3,
            prlm_call_first/5,
            prlm_var/1,
            prlm_host_primitive/1
          ]).

/** <module> prlm_kernel — stage0 bootstrap engine of the Prolog-RLM language

This module *is* the stage0 bootstrap of the self-hosted Prolog-RLM language:
a complete Prolog machine implemented in Prolog, with its own term
representation, its own unification, its own backtracking, cut, arithmetic,
module system, source loader, and error reporting.

Why it exists
=============

Prolog-RLM claims to be a language whose RLM semantics (spec, plan, execute,
verify, learn) are part of the language itself, and whose later stages
(stage1, stage2) are written in the language and executed by the language.
That claim is only honest if the engine executing stage1/stage2 code is ours,
not SWI's. This kernel is that engine.

Self-hosting / no-escape property
=================================

Interpreted variables are represented explicitly as the compound term
`'$v'(Name)` where Name is an atom. Unification, dereferencing, backtracking,
cut, and choicepoint management are implemented here over an explicit,
immutable substitution environment (a dict Name -> Term). Because a program
goal containing `'$v'(_)` terms is never a callable SWI goal, the engine is
*structurally incapable* of delegating execution of program code to the host:
there is no `call/1` escape hatch. The only host primitives the engine uses
are declared in prlm_host_primitive/1 below; everything above that line must
be (and in stage1 is) implemented in the language itself (lang X.prlm sources).

The stage0 kernel is allowed to use host primitives — that is what "stage0
bootstrap" means; every self-hosting language starts from a host. The
self-host gate (prlm_selfhost) verifies that stage1/stage2 semantics execute
through this machine only, that the builtin surface is exactly the declared
whitelist, and that stage0 and stage2 agree on a probe corpus.

Execution model
===============

A deterministic depth-first machine with an explicit choicepoint stack:

* Goals are items it(M, Goal, Barrier). M is the defining module used for
  predicate resolution and for assertz/retract/clause. Barrier is the
  choicepoint-stack depth at clause entry; `!` truncates the stack to its
  barrier, giving standard Prolog cut scope, including cut inside
  disjunction and if-then-else branches.
* Environments are immutable dicts; unification is functional
  (unify/4 threads Env0 -> Env), so choicepoints share their captured
  environment and no trail is needed.
* If-then-else commits by truncating the choicepoint stack to the depth
  recorded when the condition started (a commit_keep marker item).
* catch/3 installs a choicepoint that only reacts to thrown balls; normal
  backtracking through it behaves as plain failure.
* throw/1 unwinds the stack to the nearest catch choicepoint; balls with no
  enclosing catch escape the machine as throw(prlm_throw(Ball)).

Every machine step and clause attempt is charged to the engine's step
counter; exhaustion raises prlm_error(budget_exceeded(_)), which upper layers
map onto RLM budget semantics.

Source loading
==============

prlm_consult/2 and prlm_consult_source/3,4 read source through the host
reader (declared host primitive: parse of text into inert terms — the stage1
language re-implements substantial library and runtime logic in-language; the
bootstrap reader is part of the explicitly whitelisted stage0 surface).
Variables in loaded clauses are converted to the '$v'(Name) representation.
Directives handled by the kernel: module/2, use_module/1, dynamic/1,
discontiguous/1, initialization/1. Any other directive is offered to the
multifile hook prlm_load_directive/3 (used by upper layers, e.g.
mcp_export/1) and is a load error if no hook accepts it.

Clause provenance (file, line) is recorded and surfaced through
prlm_clause_src/4 and load errors.

Error model
===========

All engine errors are raised as throw(prlm_error(Type, Info)) with Type one
of: syntax_error, directive_error, existence_error, type_error,
instantiation_error, budget_exceeded, uncaught_throw, internal_error. Upper
layers translate these into structured RLM events; nothing in the engine
writes to streams.
*/

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).

prlm_kernel_ready.

:- discontiguous step/4.
:- discontiguous builtin_dispatch/10.
:- discontiguous resume_cp/5.

% ============================================================
% Host primitive whitelist (the self-host contract)
% ============================================================

%! prlm_host_primitive(?Pred) is nondet
%
% The complete whitelist of host functionality stage0 is built on. The
% stage1 language must be able to re-implement everything above this line.
prlm_host_primitive(dynamic_state/1).        % dynamic storage of closed engine facts
prlm_host_primitive(dict_ops/1).             % dict get/put/del for immutable environments
prlm_host_primitive(list_walk/1).            % list construction/deconstruction/length/append
prlm_host_primitive(atom_number_ops/1).      % atom/number construction, comparison, arithmetic
prlm_host_primitive(structural_ops/1).       % =../2, arg/3, ==/2 on closed terms
prlm_host_primitive(source_reader/1).        % parse of source text into inert terms
prlm_host_primitive(path_file_ops/1).        % path resolution and file existence/read
prlm_host_primitive(sorting/1).              % keysort for clause sequence ordering

% ============================================================
% Engine state (host dynamic storage of closed data)
% ============================================================

:- dynamic engine_opt/2.            % engine_opt(Engine, Opt)
:- dynamic engine_module/3.         % engine_module(Engine, Module, File)
:- dynamic engine_export/3.         % engine_export(Engine, Module, Name/Arity)
:- dynamic engine_import/5.         % engine_import(Engine, From, Name, Arity, To)
:- dynamic engine_clause/6.         % engine_clause(Engine, Module, Name, Arity, Seq, cl(Head, Body, File, Line))
:- dynamic engine_loaded/2.         % engine_loaded(Engine, AbsFile)
:- dynamic engine_init/3.           % engine_init(Engine, Module, Goal)
:- dynamic engine_counter/3.        % engine_counter(Engine, Kind, N)

prlm_engine_new(Engine) :-
    prlm_engine_new([], Engine).

prlm_engine_new(Options, Engine) :-
    gensym_engine(Engine),
    set_options(Options, Engine).

gensym_engine(Engine) :-
    (   retract(engine_counter(global, engine, N0)) -> true ; N0 = 0 ),
    N1 is N0 + 1,
    assertz(engine_counter(global, engine, N1)),
    atom_concat(prlm_engine_, N1, Engine).

set_options([], _).
set_options([Opt|Rest], Engine) :-
    set_option(Opt, Engine),
    set_options(Rest, Engine).

set_option(occurs_check(Bool), Engine) :-
    (   Bool == true ; Bool == false ),
    !,
    retractall(engine_opt(Engine, occurs_check(_))),
    assertz(engine_opt(Engine, occurs_check(Bool))).
set_option(max_steps(N), Engine) :-
    integer(N), N > 0,
    !,
    retractall(engine_opt(Engine, max_steps(_))),
    assertz(engine_opt(Engine, max_steps(N))).
set_option(Opt, _) :-
    throw(prlm_error(type_error, _{engine_option: Opt})).

prlm_engine_destroy(Engine) :-
    retractall(engine_opt(Engine, _)),
    retractall(engine_module(Engine, _, _)),
    retractall(engine_export(Engine, _, _)),
    retractall(engine_import(Engine, _, _, _, _)),
    retractall(engine_clause(Engine, _, _, _, _, _)),
    retractall(engine_loaded(Engine, _)),
    retractall(engine_init(Engine, _, _)),
    retractall(engine_counter(Engine, _, _)).

next_seq(Engine, N) :-
    (   retract(engine_counter(Engine, seq, N0)) -> true ; N0 = 0 ),
    N is N0 + 1,
    assertz(engine_counter(Engine, seq, N)).

fresh_name(Engine, F) :-
    (   retract(engine_counter(Engine, fresh, N0)) -> true ; N0 = 0 ),
    N1 is N0 + 1,
    assertz(engine_counter(Engine, fresh, N1)),
    atom_concat('$f', N1, F).

fresh_name(global, F) :-
    (   retract(engine_counter(global, fresh, N0)) -> true ; N0 = 0 ),
    N1 is N0 + 1,
    assertz(engine_counter(global, fresh, N1)),
    atom_concat('$g', N1, F).

anon_name(N) :-
    (   retract(engine_counter(global, anon, N0)) -> true ; N0 = 0 ),
    N1 is N0 + 1,
    assertz(engine_counter(global, anon, N1)),
    atom_concat('$anon_', N1, N).

%! prlm_engine_stats(Engine, steps(N)) is semidet
%
% Number of machine steps charged to Engine so far. Used by budgets,
% benchmarks and the RSI harness.
prlm_engine_stats(Engine, steps(N)) :-
    engine_counter(Engine, steps, N).

charge(Engine) :-
    (   retract(engine_counter(Engine, steps, N0)) -> true ; N0 = 0 ),
    N1 is N0 + 1,
    assertz(engine_counter(Engine, steps, N1)),
    (   engine_opt(Engine, max_steps(Limit)),
        N1 > Limit
    ->  throw(prlm_error(budget_exceeded, _{steps: N1, limit: Limit}))
    ;   true
    ).

% ============================================================
% Term representation helpers
% ============================================================

%! prlm_var(?T) is semidet
%
% True when T is the engine's explicit variable representation '$v'(Name).
prlm_var('$v'(Name)) :-
    atom(Name).

is_v(T) :-
    nonvar(T),
    functor(T, '$v', 1).

v_name('$v'(Name), Name).

deref(T, Env, T2) :-
    (   is_v(T)
    ->  v_name(T, Name),
        (   get_dict(Name, Env, V)
        ->  (   is_v(V)
            ->  (   v_name(V, VName),
                    VName == Name
                ->  T2 = T                  % self-binding guard
                ;   deref(V, Env, T2)
                )
            ;   T2 = V
            )
        ;   T2 = T
        )
    ;   T2 = T
    ).

% occurs(+Name, +Term, +Env): does variable Name occur in Term?
occurs(Name, T, Env) :-
    deref(T, Env, T1),
    (   is_v(T1)
    ->  v_name(T1, Name)
    ;   compound(T1)
    ->  T1 =.. [_|Args],
        occurs_arg(Name, Args, Env)
    ;   false
    ).

occurs_arg(Name, [A|As], Env) :-
    (   occurs(Name, A, Env)
    ;   occurs_arg(Name, As, Env)
    ).

occurs_check_enabled(Env) :-
    get_dict('$occurs', Env, true).

%! unify(+A, +B, +Env0, -Env) is semidet
%
% The language's own unification over explicit environments. Functional:
% Env0 is never mutated.
unify(A0, B0, Env0, Env) :-
    deref(A0, Env0, A),
    deref(B0, Env0, B),
    unify1(A, B, Env0, Env).

unify1(A, B, Env, Env) :-
    is_v(A),
    is_v(B),
    v_name(A, N),
    v_name(B, N),
    !.
unify1(A, B, Env0, Env) :-
    is_v(A),
    !,
    v_name(A, N),
    (   occurs_check_enabled(Env0),
        occurs(N, B, Env0)
    ->  false
    ;   put_dict(N, Env0, B, Env)
    ).
unify1(A, B, Env0, Env) :-
    is_v(B),
    !,
    unify1(B, A, Env0, Env).
unify1(A, B, Env, Env) :-
    atomic(A),
    atomic(B),
    !,
    A == B.
unify1(A, B, Env0, Env) :-
    compound(A),
    compound(B),
    A =.. [F|As],
    B =.. [F|Bs],
    unify_args(As, Bs, Env0, Env).

unify_args([], [], Env, Env).
unify_args([A|As], [B|Bs], Env0, Env) :-
    unify(A, B, Env0, Env1),
    unify_args(As, Bs, Env1, Env).

rename_shared(T, Engine, M0, M, T2) :-
    (   is_v(T)
    ->  v_name(T, N),
        (   get_dict(N, M0, V)
        ->  M = M0, T2 = V
        ;   fresh_name(Engine, F),
            V = '$v'(F),
            put_dict(N, M0, V, M),
            T2 = V
        )
    ;   compound(T)
    ->  T =.. [F|As],
        rename_args(As, Engine, M0, M, As2),
        T2 =.. [F|As2]
    ;   M = M0, T2 = T
    ).

rename_args([], _, M, M, []).
rename_args([A|As], Engine, M0, M, [A2|As2]) :-
    rename_shared(A, Engine, M0, M1, A2),
    rename_args(As, Engine, M1, M, As2).

%! rename_pair(+H, +B, +Engine, -HR, -BR) is det
%
% Rename head and body with one shared variable map so head variables and
% body variables stay connected after renaming.
rename_pair(H, B, Engine, HR, BR) :-
    rename_shared(H, Engine, env{}, M, HR),
    rename_shared(B, Engine, M, _, BR).

%! project(+Term, +Env, -Closed) is det
%
% Fully dereference against Env; residual variables remain as '$v'(Name)
% compounds, so the result is always a ground host term. A visited-set
% guard terminates the walk when occurs-check-free unification created a
% cyclic environment: a re-entered variable projects as its own '$v'(Name)
% placeholder instead of expanding forever.
project(T0, Env, T) :-
    project_walk(T0, Env, env{}, T).

project_walk(T0, Env, Seen, T) :-
    deref(T0, Env, T1),
    (   is_v(T1)
    ->  T = T1
    ;   compound(T1)
    ->  T1 =.. [F|As],
        project_args(As, F, Env, Seen, As2),
        T =.. [F|As2]
    ;   T = T1
    ).

project_args([], _, _, _, []).
project_args([A|As], F, Env, Seen, [A2|As2]) :-
    (   is_v(A)
    ->  v_name(A, N),
        (   get_dict(N, Seen, true)
        ->  A2 = A
        ;   put_dict(N, Seen, true, Seen1),
            project_walk(A, Env, Seen1, A2)
        )
    ;   project_walk(A, Env, Seen, A2)
    ),
    project_args(As, F, Env, Seen, As2).

% ============================================================
% Standard order of terms
% ============================================================

term_compare(T0a, T0b, Env, Order) :-
    deref(T0a, Env, Ta),
    deref(T0b, Env, Tb),
    rank(Ta, Ra),
    rank(Tb, Rb),
    (   Ra < Rb -> Order = (<)
    ;   Ra > Rb -> Order = (>)
    ;   compare_same_rank(Ra, Ta, Tb, Env, Order)
    ).

rank(T, 0) :- is_v(T), !.
rank(T, 1) :- number(T), !.
rank(T, 2) :- atomic(T), !.
rank(_, 3).

compare_same_rank(0, A, B, _, Order) :-
    (   A == B -> Order = (=)
    ;   v_name(A, NA), v_name(B, NB),
        (   NA @< NB -> Order = (<)
        ;   NA @> NB -> Order = (>)
        ;   Order = (=)
        )
    ).
compare_same_rank(1, A, B, _, Order) :-
    (   A < B -> Order = (<)
    ;   A > B -> Order = (>)
    ;   Order = (=)
    ).
compare_same_rank(2, A, B, _, Order) :-
    (   A @< B -> Order = (<)
    ;   A @> B -> Order = (>)
    ;   Order = (=)
    ).
compare_same_rank(3, A, B, Env, Order) :-
    A =.. [F|As],
    B =.. [F2|Bs],
    (   length(As, LA), length(Bs, LB), LA \== LB
    ->  (   LA < LB -> Order = (<) ; Order = (>) )
    ;   F \== F2
    ->  (   F @< F2 -> Order = (<) ; Order = (>) )
    ;   compare_args(As, Bs, Env, Order)
    ).

compare_args([], [], _, (=)).
compare_args([A|_], [B|_], Env, Order) :-
    term_compare(A, B, Env, O),
    O \== (=),
    !,
    Order = O.
compare_args([_|As], [_|Bs], Env, Order) :-
    compare_args(As, Bs, Env, Order).

% ============================================================
% Arithmetic
% ============================================================

eval_arith(E0, Env, V) :-
    deref(E0, Env, E),
    (   number(E)
    ->  V = E
    ;   is_v(E)
    ->  throw(prlm_error(instantiation_error, _{arith: E}))
    ;   atomic(E)
    ->  throw(prlm_error(type_error, _{arith: not_evaluable(E)}))
    ;   E =.. [F|As],
        eval_arith_f(F, As, Env, V)
    ).

eval_arith_f('-', [A], Env, V) :-
    !,
    eval_arith(A, Env, VA),
    V is -VA.                           % host arithmetic: whitelisted atom_number_ops
eval_arith_f(F, [A, B], Env, V) :-
    bin_arith(F),
    !,
    eval_arith(A, Env, VA),
    eval_arith(B, Env, VB),
    arith_bin(F, VA, VB, V).
eval_arith_f(F, [A], Env, V) :-
    un_arith(F),
    !,
    eval_arith(A, Env, VA),
    arith_un(F, VA, V).
eval_arith_f(F, _, _, _) :-
    throw(prlm_error(type_error, _{arith: unknown_functor(F)})).

bin_arith(+). bin_arith(-). bin_arith(*). bin_arith(/). bin_arith(//).
bin_arith(mod). bin_arith(rem). bin_arith(**). bin_arith(>>). bin_arith(<<).
bin_arith(/\). bin_arith(\/). bin_arith(xor). bin_arith(min). bin_arith(max).

un_arith(abs). un_arith(sign). un_arith(sqrt). un_arith(integer).
un_arith(truncate). un_arith(round). un_arith(ceiling). un_arith(floor).
un_arith(\).

arith_bin(+, A, B, V) :- V is A + B.
arith_bin(-, A, B, V) :- V is A - B.
arith_bin(*, A, B, V) :- V is A * B.
arith_bin(/, A, B, V) :- B =\= 0, V is A / B.
arith_bin(//, A, B, V) :- B =\= 0, V is A // B.
arith_bin(mod, A, B, V) :- B =\= 0, V is A mod B.
arith_bin(rem, A, B, V) :- B =\= 0, V is A rem B.
arith_bin(**, A, B, V) :- V is A ** B.
arith_bin(>>, A, B, V) :- V is A >> B.
arith_bin(<<, A, B, V) :- V is A << B.
arith_bin(/\, A, B, V) :- V is A /\ B.
arith_bin(\/, A, B, V) :- V is A \/ B.
arith_bin(xor, A, B, V) :- V is xor(A, B).
arith_bin(min, A, B, V) :- V is min(A, B).
arith_bin(max, A, B, V) :- V is max(A, B).
arith_bin(F, _, _, _) :-
    throw(prlm_error(type_error, _{arith: undefined(F)})).

arith_un(abs, A, V) :- V is abs(A).
arith_un(sign, A, V) :- V is sign(A).
arith_un(sqrt, A, V) :- A >= 0, V is sqrt(A).
arith_un(integer, A, V) :- V is integer(A).
arith_un(truncate, A, V) :- V is truncate(A).
arith_un(round, A, V) :- V is round(A).
arith_un(ceiling, A, V) :- V is ceiling(A).
arith_un(floor, A, V) :- V is floor(A).
arith_un(\, A, V) :- V is \ A.
arith_un(F, _, _) :-
    throw(prlm_error(type_error, _{arith: undefined(F)})).

arith_cmp(A, B, Env, Op) :-
    eval_arith(A, Env, VA),
    eval_arith(B, Env, VB),
    cmp_ok(Op, VA, VB).

cmp_ok(<, A, B) :- A < B.
cmp_ok(>, A, B) :- A > B.
cmp_ok(=<, A, B) :- A =< B.
cmp_ok(>=, A, B) :- A >= B.
cmp_ok(=:=, A, B) :- A =:= B.
cmp_ok('=\\=', A, B) :- A =\= B.

% ============================================================
% The machine
% ============================================================

% State = st(Goals, Env, CPs)
% Goals: list of it(Module, Goal, Barrier)
% CPs (newest first):
%   cp_clauses(M, Goal, RemainingClauses, RestGoals, Env, Bar)
%   cp_alt(M, BranchGoal, RestGoals, Env, Bar)
%   cp_ifte(M, ElseGoal, RestGoals, Env, Bar)
%   cp_catch(M, Pattern, RecoverGoal, RestGoals, Env, Bar)
%   cp_clause_enum(M, HP, BP, Seq, RestGoals, Env, Bar)

machine_solve(Engine, Module, Goal, Env0, Limit, Envs) :-
    (   engine_opt(Engine, occurs_check(true))
    ->  Env1 = Env0.put('$occurs', true)
    ;   Env1 = Env0
    ),
    catch(machine_loop(Engine, st([it(Module, Goal, 0)], Env1, []), Limit, [], EnvsRev),
          prlm_throw(Ball),
          throw(prlm_error(uncaught_throw, _{ball: Ball}))),
    reverse(EnvsRev, Envs),
    !.
% The cut makes one machine_solve call compute its complete solution list
% exactly once: re-entering it on backtracking must never re-execute
% machine steps. Callers that need solution-by-solution enumeration get the
% whole list and walk it (see sub_first/6).

machine_loop(Engine, st([], Env, CPs), Limit, Acc, Envs) :-
    !,
    (   length(Acc, N), N >= Limit
    ->  Envs = Acc
    ;   backtrack(Engine, CPs, Limit, Resume)
    ->  machine_loop(Engine, Resume, Limit, [Env|Acc], Envs)
    ;   Envs = [Env|Acc]
    ).
machine_loop(Engine, st(_, _, _), Limit, Acc, Envs) :-
    length(Acc, N),
    N >= Limit,
    !,
    Envs = Acc.
machine_loop(Engine, st(Goals, Env, CPs), Limit, Acc, Envs) :-
    step(Engine, st(Goals, Env, CPs), Limit, StepOut),
    (   StepOut == fail
    ->  (   backtrack(Engine, CPs, Limit, Resume)
        ->  machine_loop(Engine, Resume, Limit, Acc, Envs)
        ;   Envs = Acc
        )
    ;   StepOut = continue(State2)
    ->  machine_loop(Engine, State2, Limit, Acc, Envs)
    ).

% backtrack(Engine, CPs, Limit, State): next machine state or fail
backtrack(Engine, [CP|Rest], Limit, State) :-
    resume_cp(Engine, CP, Rest, Limit, R0),
    (   R0 = st(_, _, _)
    ->  State = R0
    ;   backtrack(Engine, Rest, Limit, State)
    ).
backtrack(_, [], _, _) :-
    fail.

resume_cp(Engine, cp_clauses(M, Goal, Alts, RestGoals, Env, Bar), CPsRest, _Limit, State) :-
    !,
    charge(Engine),
    try_clause(Engine, M, Goal, Alts, RestGoals, Env, Bar, CPsRest, State).
resume_cp(Engine, cp_alt(M, BranchGoal, RestGoals, Env, Bar), CPsRest, _Limit, st(Goals, Env, CPsRest)) :-
    !,
    charge(Engine),
    branch_goals(M, BranchGoal, Bar, RestGoals, Goals).
resume_cp(Engine, cp_ifte(M, ElseGoal, RestGoals, Env, Bar), CPsRest, _Limit, st(Goals, Env, CPsRest)) :-
    !,
    charge(Engine),
    branch_goals(M, ElseGoal, Bar, RestGoals, Goals).
resume_cp(Engine, cp_catch(_, _, _, _, _, _), _CPsRest, _Limit, fail) :-
    !.
resume_cp(Engine, cp_clause_enum(M, HP, BP, Seq, RestGoals, Env, Bar), CPsRest, _Limit, State) :-
    !,
    charge(Engine),
    (   enum_clause(Engine, M, HP, BP, Env, Seq, Seq2, Env2, BR)
    ->  length(CPsRest, BaseDepth),
        body_goals(M, BR, BaseDepth, RestGoals, Goals),
        State = st(Goals, Env2,
                   [cp_clause_enum(M, HP, BP, Seq2, RestGoals, Env, Bar)|CPsRest])
    ;   State = fail
    ).

% try_clause(+Engine, +M, +Goal, +Clauses, +RestGoals, +Env, +Bar,
%            +CPsRest, -State)
% Try clauses in order; on first head match, run the (renamed) body and
% push remaining clauses as a choicepoint on top of CPsRest. Cut barrier
% for the body is the stack depth BELOW the push.
try_clause(_Engine, _M, _Goal, [], _, _, _, _, fail) :-
    !.
try_clause(Engine, M, Goal, [cl(H, B, _, _)|Alts], RestGoals, Env, Bar, CPsRest, State) :-
    rename_pair(H, B, Engine, HR, BR),
    (   unify(HR, Goal, Env, Env2)
    ->  (   Alts == []
        ->  CPs2 = CPsRest
        ;   CPs2 = [cp_clauses(M, Goal, Alts, RestGoals, Env, Bar)|CPsRest]
        ),
        length(CPsRest, BaseDepth),
        body_goals(M, BR, BaseDepth, RestGoals, Goals),
        State = st(Goals, Env2, CPs2)
    ;   try_clause(Engine, M, Goal, Alts, RestGoals, Env, Bar, CPsRest, State)
    ).

% fallback simple rename for head-only use
rename_vars(T, Engine, T2) :-
    rename_shared(T, Engine, env{}, _, T2).

body_goals(_, true, _, Rest, Rest) :- !.
body_goals(M, B, Bar, Rest, [it(M, B, Bar)|Rest]).

branch_goals(_, true, _, Rest, Rest) :- !.
branch_goals(M, B, Bar, Rest, [it(M, B, Bar)|Rest]).

cut_cps(CPs, B, Kept) :-
    (   length(Kept, B),
        append(_, Kept, CPs)
    ->  true
    ;   Kept = CPs
    ).

% ============================================================
% Machine steps
% ============================================================

% --- module-qualified goal M:G ---
step(Engine, st([it(_, QM:G, Bar)|Rest], Env, CPs), _Limit, Next) :-
    !,
    charge(Engine),
    deref(QM, Env, QM1),
    (   atom(QM1)
    ->  true
    ;   throw(prlm_error(type_error, _{module_qualifier: QM1}))
    ),
    deref(G, Env, G1),
    Next = continue(st([it(QM1, G1, Bar)|Rest], Env, CPs)).

% --- cut ---
step(Engine, st([it(_, !, B)|Rest], Env, CPs), _Limit, continue(st(Rest, Env, CPs2))) :-
    !,
    charge(Engine),
    cut_cps(CPs, B, CPs2).

% --- conjunction ---
step(Engine, st([it(M, (A, B), Bar)|Rest], Env, CPs), _Limit,
     continue(st([it(M, A, Bar), it(M, B, Bar)|Rest], Env, CPs))) :-
    !,
    charge(Engine).

% --- if-then-else: must be recognised before plain disjunction; any goal
% ';' whose left operand is '->' IS an if-then-else ---
step(Engine, st([it(M, (C -> T ; E), Bar)|Rest], Env, CPs), _Limit,
     continue(st([it(M, C, Bar), it(M, commit_keep(Keep, M, T, Bar), Bar)|Rest],
                 Env,
                 [cp_ifte(M, E, Rest, Env, Bar)|CPs]))) :-
    !,
    charge(Engine),
    length([cp_ifte(M, E, Rest, Env, Bar)|CPs], D),
    Keep is D - 1.

% --- disjunction ---
step(Engine, st([it(M, (A ; B), Bar)|Rest], Env, CPs), _Limit,
     continue(st([it(M, A, Bar)|Rest], Env, [cp_alt(M, B, Rest, Env, Bar)|CPs]))) :-
    !,
    charge(Engine).

% --- if-then (no else): commit to the condition's first solution ---
step(Engine, st([it(M, (C -> T), Bar)|Rest], Env, CPs), _Limit,
     continue(st([it(M, C, Bar), it(M, commit_keep(Keep, M, T, Bar), Bar)|Rest], Env, CPs))) :-
    !,
    charge(Engine),
    length(CPs, Keep).

% --- commit: pop everything above the commit depth, run Then ---
step(Engine, st([it(_, commit_keep(Keep, M, T, Bar), _)|Rest], Env, CPs), _Limit,
     continue(st(Goals, Env, CPs2))) :-
    !,
    charge(Engine),
    cut_cps(CPs, Keep, CPs2),
    branch_goals(M, T, Bar, Rest, Goals).

% --- negation as failure ---
step(Engine, st([it(M, \+(G), _)|Rest], Env, CPs), Limit, Next) :-
    !,
    charge(Engine),
    (   sub_first(Engine, M, G, Env, Limit, _)
    ->  Next = fail
    ;   Next = continue(st(Rest, Env, CPs))
    ).

% --- once ---
step(Engine, st([it(M, once(G), _)|Rest], Env, CPs), Limit, Next) :-
    !,
    charge(Engine),
    (   sub_first(Engine, M, G, Env, Limit, Env2)
    ->  Next = continue(st(Rest, Env2, CPs))
    ;   Next = fail
    ).

% --- forall ---
step(Engine, st([it(M, forall(C, A), _)|Rest], Env, CPs), Limit, Next) :-
    !,
    charge(Engine),
    forall_hold(Engine, M, C, A, Env, Limit),
    Next = continue(st(Rest, Env, CPs)).

% --- catch install ---
step(Engine, st([it(M, catch(G, P, R), Bar)|Rest], Env, CPs), _Limit,
     continue(st([it(M, G, Bar)|Rest], Env, [cp_catch(M, P, R, Rest, Env, Bar)|CPs]))) :-
    !,
    charge(Engine).

% --- throw ---
step(Engine, st([it(_, throw(Ball), _)|Rest], Env, CPs), _Limit, Next) :-
    !,
    charge(Engine),
    (   unwind_catch(CPs, Ball, Env, M, R, Bar, Rest, Env2, CPs2)
    ->  body_goals(M, R, Bar, Rest, Goals),
        Next = continue(st(Goals, Env2, CPs2))
    ;   project(Ball, Env, BallProj),
        throw(prlm_throw(BallProj))
    ).

% --- findall ---
step(Engine, st([it(M, findall(T, G, L), _)|Rest], Env, CPs), Limit, Next) :-
    !,
    charge(Engine),
    sub_all(Engine, M, G, Env, Limit, SubEnvs),
    project_templates(SubEnvs, T, Ts),
    unify(L, Ts, Env, Env2),
    Next = continue(st(Rest, Env2, CPs)).

% --- call/1..7 ---
step(Engine, st([it(M, call(G), Bar)|Rest], Env, CPs), _Limit, Next) :-
    !,
    charge(Engine),
    deref(G, Env, G2),
    callable_check(G2),
    Next = continue(st([it(M, G2, Bar)|Rest], Env, CPs)).
step(Engine, st([it(M, call(G, A1), Bar)|Rest], Env, CPs), _Limit, Next) :-
    !,
    charge(Engine),
    deref(G, Env, G0),
    callable_check(G0),
    apply_args(G0, [A1], G2),
    Next = continue(st([it(M, G2, Bar)|Rest], Env, CPs)).
step(Engine, st([it(M, call(G, A1, A2), Bar)|Rest], Env, CPs), _Limit, Next) :-
    !,
    charge(Engine),
    deref(G, Env, G0),
    callable_check(G0),
    apply_args(G0, [A1, A2], G2),
    Next = continue(st([it(M, G2, Bar)|Rest], Env, CPs)).
step(Engine, st([it(M, call(G, A1, A2, A3), Bar)|Rest], Env, CPs), _Limit, Next) :-
    !,
    charge(Engine),
    deref(G, Env, G0),
    callable_check(G0),
    apply_args(G0, [A1, A2, A3], G2),
    Next = continue(st([it(M, G2, Bar)|Rest], Env, CPs)).
step(Engine, st([it(M, call(G, A1, A2, A3, A4), Bar)|Rest], Env, CPs), _Limit, Next) :-
    !,
    charge(Engine),
    deref(G, Env, G0),
    callable_check(G0),
    apply_args(G0, [A1, A2, A3, A4], G2),
    Next = continue(st([it(M, G2, Bar)|Rest], Env, CPs)).
step(Engine, st([it(M, call(G, A1, A2, A3, A4, A5), Bar)|Rest], Env, CPs), _Limit, Next) :-
    !,
    charge(Engine),
    deref(G, Env, G0),
    callable_check(G0),
    apply_args(G0, [A1, A2, A3, A4, A5], G2),
    Next = continue(st([it(M, G2, Bar)|Rest], Env, CPs)).
step(Engine, st([it(M, call(G, A1, A2, A3, A4, A5, A6), Bar)|Rest], Env, CPs), _Limit, Next) :-
    !,
    charge(Engine),
    deref(G, Env, G0),
    callable_check(G0),
    apply_args(G0, [A1, A2, A3, A4, A5, A6], G2),
    Next = continue(st([it(M, G2, Bar)|Rest], Env, CPs)).

% apply_args(+Callable, +ExtraArgs, -Goal): append extra arguments to an
% atom or an existing compound goal.
apply_args(G0, Extra, Goal) :-
    (   atom(G0)
    ->  Goal =.. [G0|Extra]
    ;   G0 =.. [F|As],
        append(As, Extra, All),
        Goal =.. [F|All]
    ).

% --- true / fail ---
step(Engine, st([it(_, true, _)|Rest], Env, CPs), _Limit, continue(st(Rest, Env, CPs))) :-
    !,
    charge(Engine).
step(Engine, st([it(_, F, _)|Rest], Env, CPs), Limit, fail) :-
    (   F == fail ; F == false ),
    !,
    charge(Engine).

% --- builtins ---
step(Engine, st([it(M, G, Bar)|Rest], Env, CPs), Limit, Next) :-
    compound(G),
    compound_name_arguments(G, F, _),
    builtin_name(F),
    !,
    charge(Engine),
    builtin_dispatch(F, G, Engine, M, Bar, Rest, Env, CPs, Limit, Next).

% --- user predicate: atoms (arity 0) ---
step(Engine, st([it(M, G, Bar)|Rest], Env, CPs), Limit, Next) :-
    atomic(G),
    !,
    charge(Engine),
    resolve_clauses(Engine, M, G, 0, Clauses),
    (   Clauses == []
    ->  throw(prlm_error(existence_error, _{module: M, goal: G}))
    ;   select_first_clause(Engine, M, G, Clauses, Bar, Rest, Env, CPs, Limit, Next)
    ).

% --- user predicate: compounds ---
step(Engine, st([it(M, G, Bar)|Rest], Env, CPs), Limit, Next) :-
    compound(G),
    !,
    charge(Engine),
    compound_name_arguments(G, F, As),
    length(As, Arity),
    resolve_clauses(Engine, M, F, Arity, Clauses),
    (   Clauses == []
    ->  throw(prlm_error(existence_error, _{module: M, goal: G}))
    ;   select_first_clause(Engine, M, G, Clauses, Bar, Rest, Env, CPs, Limit, Next)
    ).

% --- unbound variable in goal position ---
step(_, st([it(_, G, _)|_], _, _), _, _) :-
    is_v(G),
    !,
    throw(prlm_error(instantiation_error, _{call: G})).

select_first_clause(Engine, M, Goal, Clauses, Bar, Rest, Env, CPs, _Limit, Next) :-
    charge(Engine),
    try_clause(Engine, M, Goal, Clauses, Rest, Env, Bar, CPs, State),
    (   State = st(_, _, _)
    ->  Next = continue(State)
    ;   Next = fail
    ).

clause_key(H, F, Arity) :-
    (   compound(H)
    ->  compound_name_arguments(H, F, As),
        length(As, Arity)
    ;   atom(H)
    ->  F = H, Arity = 0
    ;   throw(prlm_error(type_error, _{clause_head: H}))
    ).

% ============================================================
% Builtins
% ============================================================

builtin_name(true).  builtin_name(fail). builtin_name(false).
builtin_name(call).  builtin_name('\\+'). builtin_name(once).
builtin_name(forall). builtin_name(catch). builtin_name(throw).
builtin_name(findall).
builtin_name('=').

builtin_name(unify_with_occurs_check).
builtin_name('\\='). builtin_name('=='). builtin_name('\\==').
builtin_name(var). builtin_name(nonvar). builtin_name(atom).
builtin_name(number). builtin_name(integer). builtin_name(float).
builtin_name(atomic). builtin_name(compound). builtin_name(callable).
builtin_name(ground).
builtin_name(is). builtin_name('<'). builtin_name('>'). builtin_name('=<').
builtin_name('>='). builtin_name('=:='). builtin_name('=\\=').
builtin_name(compare). builtin_name('@<'). builtin_name('@>').
builtin_name('@=<'). builtin_name('@>=').
builtin_name(functor). builtin_name(arg). builtin_name('=..').
builtin_name(copy_term).
builtin_name(assertz). builtin_name(retract). builtin_name(clause).
builtin_name(length).

% control builtins that reshape the goal (the others are step-level)
builtin_dispatch('\\+', G, Engine, M, _, Rest, Env, CPs, Limit, Next) :-
    !,
    arg(1, G, Sub),
    (   sub_first(Engine, M, Sub, Env, Limit, _)
    ->  Next = fail
    ;   Next = continue(st(Rest, Env, CPs))
    ).

goal_arg(G, N, Env, U) :-
    arg(N, G, A0),
    deref(A0, Env, U).

% unification
builtin_dispatch('=', G, _, _, _, Rest, Env, CPs, _Limit, Next) :-
    !,
    goal_arg(G, 1, Env, U1),
    goal_arg(G, 2, Env, U2),
    (   unify(U1, U2, Env, Env2)
    ->  Next = continue(st(Rest, Env2, CPs))
    ;   Next = fail
    ).
builtin_dispatch(unify_with_occurs_check, G, _, _, _, Rest, Env0, CPs, _, Next) :-
    !,
    goal_arg(G, 1, Env0, U1),
    goal_arg(G, 2, Env0, U2),
    Env1 = Env0.put('$occurs', true),
    (   unify(U1, U2, Env1, EnvT)
    ->  (   get_dict('$occurs', Env0, true)
        ->  Env2 = EnvT                       % engine-wide marker: keep it
        ;   del_dict('$occurs', EnvT, _, Env2)
        ),
        Next = continue(st(Rest, Env2, CPs))
    ;   Next = fail
    ).
builtin_dispatch('\\=', G, _, _, _, Rest, Env, CPs, _, Next) :-
    !,
    goal_arg(G, 1, Env, U1),
    goal_arg(G, 2, Env, U2),
    (   unify(U1, U2, Env, _)
    ->  Next = fail
    ;   Next = continue(st(Rest, Env, CPs))
    ).

% structural equality
builtin_dispatch('==', G, _, _, _, Rest, Env, CPs, _, Next) :-
    !,
    goal_arg(G, 1, Env, D1),
    goal_arg(G, 2, Env, D2),
    (   D1 == D2
    ->  Next = continue(st(Rest, Env, CPs))
    ;   Next = fail
    ).
builtin_dispatch('\\==', G, _, _, _, Rest, Env, CPs, _, Next) :-
    !,
    goal_arg(G, 1, Env, D1),
    goal_arg(G, 2, Env, D2),
    (   D1 == D2 -> Next = fail
    ;   Next = continue(st(Rest, Env, CPs))
    ).

% type checks
builtin_dispatch(Type, G, _, _, _, Rest, Env, CPs, _, Next) :-
    type_check_builtin(Type),
    !,
    goal_arg(G, 1, Env, D),
    (   type_ok(Type, D)
    ->  Next = continue(st(Rest, Env, CPs))
    ;   Next = fail
    ).

type_check_builtin(var). type_check_builtin(nonvar). type_check_builtin(atom).
type_check_builtin(number). type_check_builtin(integer). type_check_builtin(float).
type_check_builtin(atomic). type_check_builtin(compound). type_check_builtin(callable).
type_check_builtin(ground).

type_ok(var, D) :- is_v(D).
type_ok(nonvar, D) :- \+ is_v(D).
type_ok(atom, D) :- atom(D).
type_ok(number, D) :- number(D).
type_ok(integer, D) :- integer(D).
type_ok(float, D) :- float(D).
type_ok(atomic, D) :- atomic(D).
type_ok(compound, D) :- compound(D).
type_ok(callable, D) :- atom(D) ; compound(D).
type_ok(ground, D) :- \+ contains_var(D).

contains_var(T) :-
    (   is_v(T)
    ->  true
    ;   compound(T)
    ->  T =.. [_|As],
        once(( member(A, As), contains_var(A) ))
    ;   false
    ).

% arithmetic
builtin_dispatch(is, G, _, _, _, Rest, Env, CPs, _, Next) :-
    !,
    goal_arg(G, 2, Env, E),
    eval_arith(E, Env, V),
    goal_arg(G, 1, Env, A),
    (   unify(A, V, Env, Env2)
    ->  Next = continue(st(Rest, Env2, CPs))
    ;   Next = fail
    ).
builtin_dispatch(Op, G, _, _, _, Rest, Env, CPs, _, Next) :-
    arith_op(Op),
    !,
    goal_arg(G, 1, Env, A),
    goal_arg(G, 2, Env, B),
    (   arith_cmp(A, B, Env, Op)
    ->  Next = continue(st(Rest, Env, CPs))
    ;   Next = fail
    ).

arith_op('<'). arith_op('>'). arith_op('=<'). arith_op('>=').
arith_op('=:='). arith_op('=\\=').

% standard order
builtin_dispatch(compare, G, _, _, _, Rest, Env, CPs, _, Next) :-
    !,
    goal_arg(G, 2, Env, A),
    goal_arg(G, 3, Env, B),
    term_compare(A, B, Env, Order),
    goal_arg(G, 1, Env, O),
    (   unify(O, Order, Env, Env2)
    ->  Next = continue(st(Rest, Env2, CPs))
    ;   Next = fail
    ).
builtin_dispatch(Op, G, _, _, _, Rest, Env, CPs, _, Next) :-
    order_op(Op),
    !,
    goal_arg(G, 1, Env, A),
    goal_arg(G, 2, Env, B),
    term_compare(A, B, Env, O),
    (   order_ok(Op, O)
    ->  Next = continue(st(Rest, Env, CPs))
    ;   Next = fail
    ).

order_op('@<'). order_op('@>'). order_op('@=<'). order_op('@>=').
order_ok('@<', (<)).
order_ok('@>', (>)).

order_ok('@=<', O) :- O \== (>).
order_ok('@>=', O) :- O \== (<).

% term inspection
builtin_dispatch(functor, G, Engine, _, _, Rest, Env, CPs, _, Next) :-
    !,
    goal_arg(G, 1, Env, T),
    goal_arg(G, 2, Env, F),
    goal_arg(G, 3, Env, A),
    (   functor_builtin(T, F, A, Engine, Env, Env2)
    ->  Next = continue(st(Rest, Env2, CPs))
    ;   Next = fail
    ).
builtin_dispatch(arg, G, _, _, _, Rest, Env, CPs, _, Next) :-
    !,
    goal_arg(G, 1, Env, DN),
    (   integer(DN), DN >= 1
    ->  true
    ;   throw(prlm_error(type_error, _{arg: DN}))
    ),
    goal_arg(G, 2, Env, DT),
    (   compound(DT)
    ->  true
    ;   throw(prlm_error(type_error, _{arg: DT}))
    ),
    (   arg(DN, DT, AV)
    ->  goal_arg(G, 3, Env, A),
        (   unify(A, AV, Env, Env2)
        ->  Next = continue(st(Rest, Env2, CPs))
        ;   Next = fail
        )
    ;   Next = fail                        % index beyond arity: clean failure
    ).
builtin_dispatch('=..', G, _, _, _, Rest, Env, CPs, _, Next) :-
    !,
    goal_arg(G, 1, Env, T),
    goal_arg(G, 2, Env, L),
    (   univ_builtin(T, L, Env, Env2)
    ->  Next = continue(st(Rest, Env2, CPs))
    ;   Next = fail
    ).
builtin_dispatch(copy_term, G, Engine, _, _, Rest, Env, CPs, _, continue(st(Rest, Env2, CPs))) :-
    !,
    goal_arg(G, 1, Env, DT),
    rename_vars(DT, Engine, DC),
    goal_arg(G, 2, Env, C),
    unify(C, DC, Env, Env2).               % always succeeds: DC is a fresh copy


% dynamic DB
builtin_dispatch(assertz, G, Engine, M, _, Rest, Env, CPs, _, continue(st(Rest, Env, CPs))) :-
    !,
    goal_arg(G, 1, Env, C),
    machine_assertz(Engine, M, C, Env).
builtin_dispatch(retract, G, Engine, M, _, Rest, Env, CPs, _, Next) :-
    !,
    goal_arg(G, 1, Env, C),
    (   machine_retract(Engine, M, C, Env)
    ->  Next = continue(st(Rest, Env, CPs))
    ;   Next = fail
    ).
builtin_dispatch(clause, G, Engine, M, Bar, Rest, Env, CPs, _, Next) :-
    !,
    goal_arg(G, 1, Env, HP),
    goal_arg(G, 2, Env, BP),
    (   enum_clause(Engine, M, HP, BP, Env, 0, Seq, Env2, BR)
    ->  length(CPs, BaseDepth),
        body_goals(M, BR, BaseDepth, Rest, Goals),
        Next = continue(st(Goals, Env2,
                           [cp_clause_enum(M, HP, BP, Seq, Rest, Env, Bar)|CPs]))
    ;   Next = fail
    ).

% length/2 over proper lists
builtin_dispatch(length, G, _, _, _, Rest, Env, CPs, _, Next) :-
    !,
    goal_arg(G, 1, Env, L),
    (   proper_list_len(L, Env, Len)
    ->  goal_arg(G, 2, Env, N),
        unify(N, Len, Env, Env2),
        Next = continue(st(Rest, Env2, CPs))
    ;   Next = fail
    ).
builtin_dispatch(F, _, _, _, _, _, _, _, _, _) :-
    throw(prlm_error(internal_error, _{builtin: F})).

% enumerate a clause matching (HP :- BP) with Seq > MinSeq; HR/BR share one
% renaming map so head bindings flow into the body.
enum_clause(Engine, M, HP, BP, Env, MinSeq, Seq, Env2, BR) :-
    engine_clause(Engine, M, _, _, Seq, cl(H, B, _, _)),
    Seq > MinSeq,
    rename_pair(H, B, Engine, HR, BR),
    unify(HR, HP, Env, E1),
    unify(BR, BP, E1, Env2).

proper_list_len(X, _, 0) :-
    X == [],
    !.
proper_list_len(X, Env, Len) :-
    deref(X, Env, DX),
    nonvar(DX),
    DX = [_|Tail],                      % host list cell (functor '[|]'/2)
    proper_list_len(Tail, Env, L0),
    Len is L0 + 1.

functor_builtin(T, F, A, Engine, Env0, Env) :-
    deref(T, Env0, DT),
    (   \+ is_v(DT)
    ->  (   compound(DT)
        ->  DT =.. [DF|DAs],
            length(DAs, DA)
        ;   DF = DT,
            DA = 0
        ),
        unify(F, DF, Env0, Env1),
        unify(A, DA, Env1, Env)
    ;   deref(F, Env0, DF),
        deref(A, Env0, DA),
        (   integer(DA), DA >= 0
        ->  true
        ;   throw(prlm_error(type_error, _{functor: DA}))
        ),
        (   DA =:= 0
        ->  atomic(DF),
            unify(T, DF, Env0, Env)
        ;   atom(DF)
        ->  fresh_args(Engine, DA, Args),
            T2 =.. [DF|Args],
            unify(T, T2, Env0, Env)
        ;   throw(prlm_error(type_error, _{functor: DF}))
        )
    ).

fresh_args(_, 0, []) :- !.
fresh_args(Engine, N, [V|Vs]) :-
    N > 0,
    fresh_name(Engine, NF),
    V = '$v'(NF),
    N1 is N - 1,
    fresh_args(Engine, N1, Vs).

univ_builtin(T, L, Env0, Env) :-
    deref(T, Env0, DT),
    (   \+ is_v(DT)
    ->  (   compound(DT)
        ->  DT =.. [F|As],
            TL = [F|As]
        ;   TL = [DT]
        ),
        unify(L, TL, Env0, Env)
    ;   deref(L, Env0, DL),
        (   DL == []
        ->  throw(prlm_error(instantiation_error, _{univ: DL}))
        ;   DL = [F|As],
            (   As == []
            ->  unify(T, F, Env0, Env)
            ;   T2 =.. [F|As],
                unify(T, T2, Env0, Env)
            )
        )
    ).

% machine-level DB writes
machine_assertz(Engine, M, C, Env) :-
    (   C = (H :- B) -> true ; H = C, B = true ),
    deref(H, Env, DH),
    (   compound(DH) ; atom(DH)
    ->  true
    ;   throw(prlm_error(type_error, _{assertz: not_callable(DH)}))
    ),
    rename_shared(C, Engine, env{}, _, C2),
    (   C2 = (H2 :- B2) -> true ; H2 = C2, B2 = true ),
    clause_key(H2, F, Arity),
    next_seq(Engine, N),
    assertz(engine_clause(Engine, M, F, Arity, N, cl(H2, B2, runtime, 0))).

machine_retract(Engine, M, C, Env) :-
    (   C = (H :- B) -> true ; H = C, B = true ),
    deref(H, Env, DH),
    clause_key(DH, F, Arity),
    engine_clause(Engine, M, F, Arity, Seq, cl(CH, CB, _, _)),
    rename_pair(CH, CB, Engine, CHR, CBR),
    unify(CHR, H, Env, _),
    unify(CBR, B, Env, _),
    retract(engine_clause(Engine, M, F, Arity, Seq, cl(CH, CB, _, _))).

callable_check(G) :-
    (   atom(G) -> true
    ;   compound(G) -> true
    ;   throw(prlm_error(type_error, _{call: not_callable(G)}))
    ).

sub_first(Engine, M, G, Env0, Limit, Env) :-
    machine_solve(Engine, M, G, Env0, Limit, Envs),
    member(Env, Envs).

sub_all(Engine, M, G, Env0, Limit, Envs) :-
    machine_solve(Engine, M, G, Env0, Limit, Envs),
    !.

forall_hold(Engine, M, C, A, Env, Limit) :-
    (   sub_first(Engine, M, C, Env, Limit, CEnv),
        \+ sub_first(Engine, M, A, CEnv, Limit, _)
    ->  fail
    ;   true
    ).

unwind_catch([cp_catch(M, P, R, Rest, CPEnv, Bar)|Older], Ball, _, M, R, Bar, Rest, Env2, Older) :-
    unify(Ball, P, CPEnv, Env2),
    !.
unwind_catch([_|Older], Ball, Env, M, R, Bar, Rest, Env2, CPs2) :-
    unwind_catch(Older, Ball, Env, M, R, Bar, Rest, Env2, CPs2).

project_templates([], _, []).
project_templates([Env|Envs], T, [P|Ps]) :-
    project(T, Env, P),
    project_templates(Envs, T, Ps).

% ============================================================
% Public query API
% ============================================================

%! prlm_query_all(+Engine, +Goal, +Limit, -Envs) is det
%! prlm_query_all(+Engine, +Module, +Goal, +Limit, -Envs) is det
%
% Run Goal through the machine, collecting solution environments.
prlm_query_all(Engine, Goal, Limit, Envs) :-
    prlm_query_all(Engine, user, Goal, Limit, Envs).
prlm_query_all(Engine, Module, Goal, Limit, Envs) :-
    machine_solve(Engine, Module, Goal, env{}, Limit, Envs),
    !.

prlm_query_first(Engine, Goal, Env) :-
    prlm_query_first(Engine, user, Goal, Env).

prlm_query_first(Engine, Module, Goal, Env) :-
    prlm_query_all(Engine, Module, Goal, 1, [Env|_]).

%! prlm_query_solutions(+Engine, +GoalText, +Limit, -Rows) is det
%
% Convenience for callers: parse GoalText (untrusted-safe: parse only),
% run it, and return one row dict per solution keyed by the variable names
% appearing in the goal. Values are projected (fully dereferenced, ground).
prlm_query_solutions(Engine, GoalText, Limit, Rows) :-
    prlm_read_goal(GoalText, Goal, VarNames),
    prlm_query_all(Engine, Goal, Limit, Envs),
    rows_from_envs(Envs, VarNames, Rows).

rows_from_envs([], _, []).
rows_from_envs([Env|Envs], VarNames, [Row|Rows]) :-
    row_pairs(VarNames, Env, Pairs),
    dict_create(Row, row, Pairs),
    rows_from_envs(Envs, VarNames, Rows).

row_pairs([], _, []).
row_pairs([Name=Var|Rest], Env, [Key-Val|Pairs]) :-
    deref(Var, Env, DV),
    project(DV, Env, Val),
    (   atom(Name) -> Key = Name ; atom_string(Key, Name) ),
    row_pairs(Rest, Env, Pairs).

%! prlm_read_goal(+Text, -Goal, -VarNames) is det
%
% Parse Text into an engine term. Variables become '$v'(Name). This is the
% boundary where untrusted text becomes inert data — it never executes.
% A terminating full stop is appended when absent.
prlm_read_goal(Text, Goal, VarNames) :-
    ensure_full_stop(Text, Text1),
    setup_call_cleanup(
        open_string(Text1, S),
        read_term(S, Goal0, [variable_names(VNs)]),
        close(S)
    ),
    VarNames = VNs,
    convert_term(Goal0, VNs, Goal).

ensure_full_stop(Text, Text1) :-
    (   atom(Text)
    ->  atom_string(Text, S0)
    ;   S0 = Text
    ),
    (   string_concat(_, Period, S0),
        member(Period, [".", ".\n"])
    ->  S1 = S0
    ;   string_concat(S0, ".", S1)
    ),
    atom_string(Text1, S1).

convert_term(T, VNs, Goal) :-
    check_no_reserved(T),
    bind_named(VNs),
    replace_free(T, Goal).

bind_named([]).
bind_named([Name=Var|Rest]) :-
    (   atom(Name) -> Key = Name ; atom_string(Key, Name) ),
    Var = '$v'(Key),
    bind_named(Rest).

replace_free(T, T2) :-
    (   var(T)
    ->  anon_name(N),
        T = '$v'(N),
        T2 = T
    ;   compound(T)
    ->  T =.. [F|As],
        replace_args(As, As2),
        T2 =.. [F|As2]
    ;   T2 = T
    ).

replace_args([], []).
replace_args([A|As], [A2|As2]) :-
    replace_free(A, A2),
    replace_args(As, As2).

%! prlm_call_first(+Engine, +Module, +Goal0, +OutSpec, -Result) is semidet
%
% Bridge for trusted host code that builds goals with host variables:
% Goal0 may contain unbound host variables; every variable in OutSpec
% (Key - VarTerm) is converted to an engine variable, Goal0 runs once and
% Result is a dict Key -> projected value. Host variables elsewhere in
% Goal0 are converted too (they act as anonymous inputs).
%
% Why this exists: the machine's unifier only understands '$v'(Name)
% variables; raw host variables in goal position cannot unify (fail
% closed). This bridge is the single sanctioned crossing point.
prlm_call_first(Engine, Module, Goal0, OutSpec, Result) :-
    convert_host_vars(Goal0),
    convert_outspec(OutSpec),
    machine_solve(Engine, Module, Goal0, env{}, 1, [Env|_]),
    !,
    outspec_result(OutSpec, Env, Pairs),
    dict_create(Result, result, Pairs).

convert_host_vars(T) :-
    (   var(T)
    ->  fresh_name(global, F),
        T = '$v'(F)
    ;   compound(T)
    ->  T =.. [_|Args],
        maplist(convert_host_vars, Args)
    ;   true
    ).

convert_outspec([]).
convert_outspec([_-Var|Rest]) :-
    convert_host_vars(Var),
    convert_outspec(Rest).

outspec_result([], _, []).
outspec_result([Key-Var|Rest], Env, [Key-Val|Pairs]) :-
    (   is_v(Var)
    ->  v_name(Var, Name),
        (   get_dict(Name, Env, V0) -> true ; V0 = Var ),
        project(V0, Env, Val)
    ;   Val = Var
    ),
    outspec_result(Rest, Env, Pairs).

% ============================================================
% Source loading
% ============================================================

%! prlm_consult(+Engine, +Path) is det
%
% Load a .prlm source file into Engine. Idempotent per absolute path.
prlm_consult(Engine, Path) :-
    (   atom(Path) ; string(Path)
    ->  true
    ;   throw(prlm_error(type_error, _{consult: Path}))
    ),
    (   exists_file(Path)
    ->  true
    ;   throw(prlm_error(existence_error, _{file: Path}))
    ),
    absolute_file_name(Path, Abs),
    (   engine_loaded(Engine, Abs)
    ->  true
    ;   assertz(engine_loaded(Engine, Abs)),
        catch(setup_call_cleanup(
                  open(Abs, read, S),
                  load_stream_module(Engine, S, Abs, auto),
                  close(S)),
              prlm_error(Type, Info),
              (   retractall(engine_loaded(Engine, Abs)),
                  throw(prlm_error(Type, Info))
              )),
        run_initializations(Engine, Abs)
    ).

%! prlm_consult_source(+Engine, +Module, +Text) is det
%! prlm_consult_source(+Engine, +Module, +Text, +FileTag) is det
%
% Load an in-memory source string into Module (use user for the default
% space). FileTag is provenance for clauses and errors.
prlm_consult_source(Engine, Module, Text) :-
    prlm_consult_source(Engine, Module, Text, '<source>').

prlm_consult_source(Engine, Module, Text, FileTag) :-
    (   atom(Module)
    ->  true
    ;   throw(prlm_error(type_error, _{module: Module}))
    ),
    (   Module == user
    ->  true
    ;   (   engine_module(Engine, Module, FileTag) -> true
        ;   assertz(engine_module(Engine, Module, FileTag))
        )
    ),
    setup_call_cleanup(
        open_string(Text, S),
        load_stream_module(Engine, S, FileTag, fixed(Module)),
        close(S)
    ),
    run_initializations(Engine, FileTag).

load_stream_module(Engine, S, File, ModuleSel) :-
    (   ModuleSel = fixed(M) -> Cur = M ; Cur = user ),
    read_loop(S, File, Engine, ModuleSel, Cur).

read_loop(S, File, Engine, ModuleSel, Cur) :-
    (   catch(read_term(S, T0, [term_position(P), variable_names(VNs)]),
              error(syntax_error(What), _),
              throw(prlm_error(syntax_error, _{file: File, what: What})))
    ->  (   T0 == end_of_file
        ->  true
        ;   (   catch(stream_position_data(line_count, P, L), _, L = unknown)
            ->  true
            ;   L = unknown
            ),
            convert_term(T0, VNs, T),
            read_dispatch(S, File, Engine, ModuleSel, Cur, T, L)
        )
    ;   throw(prlm_error(internal_error, _{read: File}))
    ).

read_dispatch(S, File, Engine, ModuleSel, _Cur, (:- module(Name, Exports)), _L) :-
    !,
    (   ModuleSel = fixed(M) -> M == Name  % fixed module must match declaration
    ;   true
    ),
    declare_module(Engine, Name, Exports, File),
    read_loop(S, File, Engine, ModuleSel, Name).
read_dispatch(S, File, Engine, ModuleSel, Cur, (:- D), _L) :-
    !,
    handle_directive(Engine, Cur, D, File),
    read_loop(S, File, Engine, ModuleSel, Cur).
read_dispatch(S, File, Engine, ModuleSel, Cur, (?- G), _L) :-
    !,
    assertz(engine_init(Engine, Cur, G)),
    read_loop(S, File, Engine, ModuleSel, Cur).
read_dispatch(S, File, Engine, ModuleSel, Cur, T, L) :-
    add_clause(Engine, Cur, T, File, L),
    read_loop(S, File, Engine, ModuleSel, Cur).

declare_module(Engine, Name, Exports, File) :-
    (   atom(Name)
    ->  true
    ;   throw(prlm_error(directive_error, _{module: Name}))
    ),
    retractall(engine_module(Engine, Name, File)),
    assertz(engine_module(Engine, Name, File)),
    export_list(Exports, Engine, Name).

add_clause(Engine, M, (H :- B), File, Line) :-
    !,
    clause_key(H, F, Arity),
    next_seq(Engine, N),
    assertz(engine_clause(Engine, M, F, Arity, N, cl(H, B, File, Line))).
add_clause(Engine, M, H, File, Line) :-
    add_clause(Engine, M, (H :- true), File, Line).

check_no_reserved(T) :-
    (   is_reserved_term(T)
    ->  throw(prlm_error(type_error, _{reserved_functor: '$v'}))
    ;   compound(T)
    ->  T =.. [_|As],
        maplist(check_no_reserved, As)
    ;   true
    ).

is_reserved_term(T) :-
    compound(T),
    functor(T, '$v', 1).

handle_directive(_Engine, _M, module(Name, Exports), _File) :-
    !,
    (   atom(Name)
    ->  true
    ;   throw(prlm_error(directive_error, _{module: Name}))
    ),
    retractall(engine_module(Engine, Name, File)),
    assertz(engine_module(Engine, Name, File)),
    export_list(Exports, Engine, Name).
handle_directive(Engine, M, use_module(Spec), File) :-
    !,
    (   use_module_target(Engine, Spec, File, Target)
    ->  bind_imports(Engine, M, Target)
    ;   throw(prlm_error(directive_error, _{use_module: Spec}))
    ).

% Resolve a use_module target: a loadable file (relative to the loading
% file, with or without explicit extension) or an already-loaded module.
use_module_target(Engine, Spec, BaseFile, Target) :-
    filename_text(Spec, S),
    file_directory_name(BaseFile, Dir),
    candidates(S, Dir, Paths),
    member(Path, Paths),
    exists_file(Path),
    !,
    prlm_consult(Engine, Path),
    prlm_module_of_file(Engine, Path, Target).
use_module_target(Engine, Spec, _, Target) :-
    atom(Spec),
    engine_module(Engine, Spec, _),
    !,
    Target = Spec.

filename_text(Spec, S) :-
    (   atom(Spec) -> atom_string(S, Spec)
    ;   format(string(S), '~w', [Spec])     % e.g. '.'(mod_a, prlm) -> "mod_a.prlm"
    ).

candidates(S, Dir, Paths) :-
    findall(P,
            (   member(Raw, [S]),
                member(Ext, ["", ".prlm"]),
                atom_concat(Raw, Ext, Raw2),
                (   sub_atom(Dir, 0, 1, _, '/'), Dir \== '/'
                ->  directory_file_path(Dir, Raw2, P)
                ;   P = Raw2
                )
            ),
            Paths0),
    sort(Paths0, Paths).                    % dedupe, deterministic order
handle_directive(_Engine, _M, dynamic(_), _File) :-
    !.
handle_directive(_, _, discontiguous(_), _) :-
    !.
handle_directive(Engine, M, initialization(G), _) :-
    !,
    assertz(engine_init(Engine, M, G)).
handle_directive(Engine, M, D, _) :-
    (   prlm_load_directive(Engine, M, D)
    ->  true
    ;   throw(prlm_error(directive_error, _{directive: D}))
    ).

export_list([], _, _).
export_list([N/A|Rest], Engine, Module) :-
    (   atom(N), integer(A), A >= 0
    ->  true
    ;   throw(prlm_error(directive_error, _{export: N/A}))
    ),
    (   engine_export(Engine, Module, N/A) -> true
    ;   assertz(engine_export(Engine, Module, N/A))
    ),
    export_list(Rest, Engine, Module).

resolve_use_path(Spec, BaseFile, Path) :-
    (   atom(Spec) -> P = Spec
    ;   Spec = library(S) -> atom_string(P, S)
    ;   throw(prlm_error(directive_error, _{use_module: Spec}))
    ),
    file_directory_name(BaseFile, Dir),
    (   Dir \== '.', Dir \== '/', \+ sub_atom(Dir, 0, 1, _, '<')
    ->  directory_file_path(Dir, P, P1),
        (   exists_file(P1) -> Path = P1 ; Path = P )
    ;   Path = P
    ).

bind_imports(Engine, From, To) :-
    forall(engine_export(Engine, To, N/A),
           (   \+ engine_import(Engine, From, N, A, To)
           ->  assertz(engine_import(Engine, From, N, A, To))
           ;   true
           )).

run_initializations(Engine, File) :-
    prlm_module_of_file(Engine, File, M),
    forall(engine_init(Engine, M, G),
           catch(machine_solve(Engine, M, G, env{}, 1, _),
                 prlm_error(Type, Info),
                 throw(prlm_error(Type, Info.put(file, File))))),
    retractall(engine_init(Engine, M, _)).

%! prlm_module_of_file(+Engine, +Path, -Module) is det
%
% The module name a consulted file declared (user when none).
prlm_module_of_file(Engine, Path, Module) :-
    (   atom(Path), sub_atom(Path, 0, _, _, '/')
    ->  Abs = Path
    ;   catch(absolute_file_name(Path, Abs), _, Abs = Path)
    ),
    (   engine_module(Engine, Module, Abs)
    ->  true
    ;   Module = user
    ).

% clause resolution: local module first, then imports
resolve_clauses(Engine, M, F, A, Clauses) :-
    findall(Seq-cl(H, B, File, Line),
            engine_clause(Engine, M, F, A, Seq, cl(H, B, File, Line)),
            Local),
    keysort(Local, LocalSorted),
    (   LocalSorted \== []
    ->  pairs_values(LocalSorted, Clauses)
    ;   findall(To-Seq-cl(H, B, File, Line),
                (   engine_import(Engine, M, F, A, To),
                    engine_clause(Engine, To, F, A, Seq, cl(H, B, File, Line))
                ),
                Imported),
        Imported \== [],
        keysort(Imported, ImportedSorted),
        pairs_values(ImportedSorted, Clauses)
    ),
    !.
% Deterministic: empty result must survive backtracking unchanged.
resolve_clauses(_, _, _, _, []).

% ============================================================
% Public DB/introspection API
% ============================================================

prlm_assertz(Engine, Module, Clause) :-
    (   Clause = (Head :- Body) -> true ; Head = Clause, Body = true ),
    prlm_assertz_clause(Engine, Module, Head, Body).

prlm_assertz_clause(Engine, Module, Head, Body) :-
    clause_key(Head, F, Arity),
    next_seq(Engine, N),
    assertz(engine_clause(Engine, Module, F, Arity, N, cl(Head, Body, runtime, 0))).

prlm_retract_first(Engine, Module, Name, Arity) :-
    engine_clause(Engine, Module, Name, Arity, Seq, _),
    retract(engine_clause(Engine, Module, Name, Arity, Seq, _)).

prlm_current_predicate(Engine, Module, Name/Arity) :-
    engine_clause(Engine, Module, Name, Arity, _, _).
prlm_current_predicate(Engine, Module, Name/Arity) :-
    engine_export(Engine, Module, Name/Arity).

prlm_clause_src(Engine, Module, Name/Arity, Srcs) :-
    findall(File-Line,
            engine_clause(Engine, Module, Name, Arity, _, cl(_, _, File, Line)),
            Srcs).

prlm_module_exports(Engine, Module, Exports) :-
    findall(N/A, engine_export(Engine, Module, N/A), Exports).

% multifile + dynamic hook for unknown directives (mcp_export/1 etc.).
% Trusted upper layers may assert additional handlers at runtime.
:- multifile prlm_load_directive/3.
:- dynamic prlm_load_directive/3.
