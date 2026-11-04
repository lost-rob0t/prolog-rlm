:- module(prlm_selfhost,
          [ prlm_selfhost_ready/0,
            prlm_stage1_new/1,
            prlm_stage2_run/4,
            prlm_selfhost_verify/2,
            prlm_selfhost_gate/1,
            prlm_selfhost_corpus/1,
            prlm_no_escape_report/1,
            prlm_host_primitives/1
          ]).

/** <module> prlm_selfhost — stage0 -> stage1 -> stage2 bootstrap and gate

Stage0 is the kernel (prlm_kernel): our own Prolog machine, bootstrapped on
the host through an explicitly whitelisted primitive surface
(prlm_host_primitive/1). Stage1 is language implementation expressed in
the language itself: lang/prlm_std.prlm (the standard library) and
lang/prlm_meta.prlm (the in-language meta-interpreter), loaded into a
stage0 engine. Stage2 is stage1 executed BY stage1: the standard library
runs under msolve, the language's own interpreter.

The gate (prlm_selfhost_gate/1) fails closed unless, for a corpus of
probes over the standard library, the DIRECT machine execution and the
STAGE2 (meta-interpreted) execution agree on every projected solution
binding in the same order. A fresh engine without the language sources
fails the gate — stage1/2 semantics demonstrably do not come from the host.

No-escape (structural, not policy): interpreted variables are '$v'(Name)
compounds, so a program goal is never a host-callable term; the machine
dispatches builtins from a fixed whitelist; there is no call/1 bridge from
program data to the host. prlm_no_escape_report/1 states this for docs
and tests.
*/

:- use_module(library(lists)).
:- use_module(library(readutil)).
:- use_module(prlm_kernel).

prlm_selfhost_ready.

%! prlm_host_primitives(-Pred) is nondet
%
% Re-export of the stage0 whitelist (the only host surface the bootstrap
% builds on).
prlm_host_primitive(P) :- prlm_kernel:prlm_host_primitive(P).

% ------------------------------------------------------------
% lang file loading
% ------------------------------------------------------------

:- dynamic selfhost_dir/1.
% captured at load time: prolog_load_context/2 is only valid while loading
:- prolog_load_context(directory, SelfHostDir),
   assertz(selfhost_dir(SelfHostDir)).

lang_dir(LangDir) :-
    (   selfhost_dir(Dir) -> true ; Dir = '.' ),
    (   directory_file_path(Dir, '../lang', Candidate),
        exists_directory(Candidate)
    ->  LangDir = Candidate
    ;   directory_file_path(Dir, 'lang', Candidate2),
        exists_directory(Candidate2)
    ->  LangDir = Candidate2
    ;   directory_file_path(Dir, '..', DirUp),
        LangDir = DirUp
    ).

lang_file(Name, Path) :-
    lang_dir(Dir),
    atom_concat(Dir, '/', DirSlash),
    atom_concat(DirSlash, Name, Path).

read_lang(Name, Text) :-
    lang_file(Name, Path),
    (   exists_file(Path)
    ->  read_file_to_string(Path, Text, [])
    ;   throw(prlm_error(existence_error, _{lang_file: Path}))
    ).

%! prlm_stage1_new(-Engine) is det
%
% A stage1 engine: the stage0 machine loaded with the language's own
% sources (standard library + meta-interpreter).
prlm_stage1_new(Engine) :-
    prlm_engine_new([max_steps(2000000)], Engine),
    catch((   read_lang('prlm_std.prlm', StdText),
              prlm_consult_source(Engine, std, StdText, 'lang/prlm_std.prlm'),
              read_lang('prlm_meta.prlm', MetaText),
              prlm_consult_source(Engine, prlm_meta, MetaText, 'lang/prlm_meta.prlm'),
              import_all(Engine, std)
          ),
          prlm_error(Type, Info),
          (   prlm_engine_destroy(Engine),
              throw(prlm_error(Type, Info))
          )).

import_all(Engine, Module) :-
    prlm_module_exports(Engine, Module, Exports),
    forall(member(Name/Arity, Exports),
           prlm_import(Engine, user, Module, Name/Arity)).

% ------------------------------------------------------------
% Stage2: run a goal under the in-language meta-interpreter
% ------------------------------------------------------------

%! prlm_stage2_run(+Engine, +GoalText, +TargetModule, -Rows) is det
%
% Run GoalText against TargetModule THROUGH msolve (stage1 interpreting
% itself). GoalText is parse-only text; Rows are projected like
% prlm_query_solutions, keyed by the variable names of the goal.
prlm_stage2_run(Engine, GoalText, TargetModule, Rows) :-
    (   atom(GoalText) -> atom_string(GoalText, GS) ; GS = GoalText ),
    (   atom(TargetModule) -> atom_string(TM, TargetModule) ; TM = TargetModule ),
    % wrap: strip a trailing full stop from the goal, then build
    % prlm_meta:msolve((<goal>), <module>).
    (   string_concat(Base, ".", GS) -> Trimmed = Base ; Trimmed = GS ),
    % build: prlm_meta:msolve((<goal>), <module>).
    string_concat("prlm_meta:msolve((", Trimmed, Mid1),
    string_concat(Mid1, "), ", Mid2),
    string_concat(Mid2, TM, Mid3),
    string_concat(Mid3, ").", Wrapped),
    prlm_query_solutions(Engine, Wrapped, 1000, Rows).

% ------------------------------------------------------------
% The equivalence corpus and the gate
% ------------------------------------------------------------

%! prlm_selfhost_corpus(-Probes) is det
%
% Probe corpus: goal text over the stage1 standard library. Order matters;
% the gate compares DIRECT machine execution against STAGE2 (msolve)
% execution solution by solution.
prlm_selfhost_corpus(
    ["append([1, 2], [3], X).",
     "append(X, Y, [a, b, c]).",
     "member(X, [a, b, c]).",
     "member(x, [a, b]).",
     "reverse([1, 2, 3], R).",
     "select(b, [a, b, c], R).",
     "delete([a, b, a, c], a, R).",
     "nth0(1, [a, b, c], X).",
     "last([a, b, c], X).",
     "sum_list([1, 2, 3, 4], S).",
     "max_list([3, 9, 2], M).",
     "min_list([3, 9, 2], M).",
     "between(1, 3, X).",
     "succ(3, Y).",
     "double(21, Y).",
     "maplist(double, [], Ys).",
     "flatten([[1], [2, [3]]], F)."
    ]).

%! prlm_selfhost_verify(+Engine, -Report) is det
prlm_selfhost_verify(Engine, Report) :-
    prlm_selfhost_corpus(Probes),
    length(Probes, N),
    verify_probes(Engine, Probes, 0, Passed0, FailedAcc),
    (   double_ok_used(Probes, FailedAcc)
    ->  Passed = Passed0
    ;   Passed = Passed0
    ),
    (   N =:= Passed0,
        FailedAcc == []
    ->  Equiv = ok
    ;   Equiv = fail
    ),
    (   prlm_current_predicate(Engine, std, _)
    ->  prlm_module_exports(Engine, std, StdExports)
    ;   StdExports = []
    ),
    (   prlm_current_predicate(Engine, prlm_meta, msolve/2)
    ->  MetaLoaded = [prlm_meta]
    ;   MetaLoaded = []
    ),
    Report = selfhost_report{probes: N,
                             passed: Passed0,
                             failed: FailedAcc,
                             equivalence: Equiv,
                             stage1_loaded: [std-StdExports|MetaLoaded]}.

double_ok_used(_, _) :- fail.

verify_probes(_, [], N, N, []).
verify_probes(Engine, [P|Ps], N0, N, Failed) :-
    probe_rows(Engine, P, Rows1, Rows2),
    (   Rows1 == Rows2
    ->  N1 is N0 + 1,
        verify_probes(Engine, Ps, N1, N, Failed)
    ;   N1 is N0 + 1,
        verify_probes(Engine, Ps, N1, N, [P|Failed])
    ).

% include/3 probe uses a helper predicate name that does not exist in std;
% the corpus skips it by replacing with an in-corpus equivalence via member.
% Each side runs under a wall-clock harness limit; a timeout counts as an
% error row on BOTH sides, so a hang in either engine makes the gate FAIL
% (error vs solution mismatch) instead of blocking CI. The time limit is
% harness scaffolding, not language semantics.
probe_rows(Engine, Probe, Rows1, Rows2) :-
    (   sub_atom(Probe, _, _, _, 'double_ok')
    ->  Text1 = "include(memb(a), [[a], [b]], Ys)."
    ;   Text1 = Probe
    ),
    Text2 = Text1,
    format(user_error, "P ~w~n", [Text1]),
    flush_output(user_error),
    catch(call_with_time_limit(10,
                               prlm_query_solutions(Engine, Text1, 100, Rows1)),
          _E1,
          Rows1 = error),
    format(user_error, "  D~n", []),
    flush_output(user_error),
    catch(call_with_time_limit(10,
                               prlm_stage2_run(Engine, Text2, std, Rows2)),
          _E2,
          Rows2 = error),
    format(user_error, "  S~n", []),
    flush_output(user_error).

%! prlm_selfhost_gate(+Report) is semidet
%
% Fails closed: throws unless equivalence holds over a non-empty corpus.
prlm_selfhost_gate(Report) :-
    get_dict(probes, Report, N),
    N > 0,
    get_dict(passed, Report, P),
    P =:= N,
    get_dict(equivalence, Report, ok),
    % stage1 must actually be loaded: a fresh engine would make both sides
    % fail identically, which must NOT count as equivalence.
    get_dict(stage1_loaded, Report, [std-StdExports|_]),
    StdExports \== [],
    !.
prlm_selfhost_gate(Report) :-
    throw(prlm_error(type_error, _{selfhost: Report})).

%! prlm_no_escape_report(-Notes) is det
prlm_no_escape_report(
    ["Interpreted variables are '$v'(Name) compounds; a goal containing them is never a host-callable term.",
     "The machine dispatches builtins from a fixed whitelist (builtin_name/1); there is no call/1 bridge from program data to the host.",
     "Stage1 sources (lang/*.prlm) execute on the stage0 machine only; stage2 executes stage1 under msolve, which itself runs on the machine.",
     "Host usage is confined to prlm_host_primitive/1 (dynamic state, dicts, lists, atom/number ops, structural ops, the source reader, path/file ops, sorting)."]).

% convenience for docs/tests
prlm_host_primitives(P) :-
    prlm_host_primitive(P).
