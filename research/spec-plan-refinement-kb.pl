/* Long-horizon research/design KB for the SPEC/PLAN authority refinement
 * driven by PR #290 feedback.  This KB is the working control plane for the
 * refinement pass itself; the durable output is docs/research/spec-plan-authority.md.
 *
 * Statuses persist across processes in research/spec-plan-refinement-kb-state.pl
 * (written as module-qualified assertz directives by kb_mark/2).
 *
 * Queries:
 *   kb_ready(Task)                 - pending task with all dependencies done
 *   kb_remaining(Task)             - not done
 *   kb_blocked_by(Task, Dep, Why)
 *   kb_dependency_closure(Task, Deps)
 *   kb_next(Task)                  - suggested next task (lowest id, ready)
 *   kb_summary(Summary)
 */
:- module(spec_plan_refinement_kb,
          [ kb_task/4, kb_depends/2, kb_evidence/2, kb_decision/4,
            kb_open_question/2, kb_ready/1, kb_remaining/1,
            kb_blocked_by/3, kb_dependency_closure/2, kb_next/1,
            kb_task_done/1, kb_mark/2, kb_validate_decision/2,
            kb_summary/1
          ]).

%% ---- base tasks (initial statuses) -------------------------------------
kb_base_task(t01, research, 'Survey merged runtime evidence vs PR #290 assumptions', pending).
kb_base_task(t02, design,   'D1: SPEC grammar delta over rlm_spec_lang closed symbols', pending).
kb_base_task(t03, design,   'D2: SPEC type system (structural/argument/reference types)', pending).
kb_base_task(t04, design,   'D3: validateSpec hard gate + structured spec_fault diagnostics', pending).
kb_base_task(t05, design,   'D4: Frozen Spec semantics (gate ordering, repair, replan)', pending).
kb_base_task(t06, design,   'D5: SPEC->PLAN compiler (plan_seed_from_spec)', pending).
kb_base_task(t07, design,   'D6/D7: PLAN grammar + plan schema validator deltas', pending).
kb_base_task(t08, design,   'D8: dependency representation (graph KB, ready derivation)', pending).
kb_base_task(t09, design,   'D9: durable plan-state representation', pending).
kb_base_task(t10, design,   'D10: normalized references (symbolRef/sourceSpan/revisionRef)', pending).
kb_base_task(t11, design,   'D11: language-independent symbol model + adapters', pending).
kb_base_task(t12, design,   'D12: project retrieval engine + diff semantics', pending).
kb_base_task(t13, design,   'D13: project write engine (durable effect boundary)', pending).
kb_base_task(t14, design,   'D14: project validation engine (assertion kinds)', pending).
kb_base_task(t15, design,   'D15: expert mapping (intent -> expert -> capability)', pending).
kb_base_task(t16, design,   'D16: context compiler integration per ready step', pending).
kb_base_task(t17, design,   'D17: intent system (features, candidates, validation)', pending).
kb_base_task(t18, design,   'D18: strategy selection (direct/symbolic/recursive symbolic)', pending).
kb_base_task(t19, design,   'D19: lambda-RLM combinator mapping', pending).
kb_base_task(t20, design,   'D20: long-horizon KB representation (this KB, generalized)', pending).
kb_base_task(t21, design,   'D21: failure knowledge flow (candidate constraints)', pending).
kb_base_task(t22, design,   'D22: implementation dependency graph (slices S1..S10)', pending).
kb_base_task(t23, gate,     'Design-consistency check script (schemas + example)', pending).

%% ---- dependencies ------------------------------------------------------
kb_depends(t02, t01).
kb_depends(t03, t02).
kb_depends(t04, t03).
kb_depends(t05, t04).
kb_depends(t06, t05).
kb_depends(t07, t01).
kb_depends(t08, t07).
kb_depends(t09, t08).
kb_depends(t10, t01).
kb_depends(t11, t10).
kb_depends(t12, t11).
kb_depends(t13, t11).
kb_depends(t14, t11).
kb_depends(t15, t12).
kb_depends(t15, t13).
kb_depends(t15, t14).
kb_depends(t16, t15).
kb_depends(t17, t01).
kb_depends(t18, t17).
kb_depends(t18, t16).
kb_depends(t19, t18).
kb_depends(t19, t07).
kb_depends(t20, t01).
kb_depends(t21, t01).
kb_depends(t22, t05).
kb_depends(t22, t06).
kb_depends(t22, t09).
kb_depends(t22, t12).
kb_depends(t22, t13).
kb_depends(t22, t14).
kb_depends(t22, t15).
kb_depends(t22, t16).
kb_depends(t22, t17).
kb_depends(t22, t18).
kb_depends(t22, t19).
kb_depends(t22, t20).
kb_depends(t22, t21).
kb_depends(t23, t02).
kb_depends(t23, t04).
kb_depends(t23, t06).
kb_depends(t23, t07).
kb_depends(t23, t10).
kb_depends(t23, t18).
kb_depends(t23, t22).

%% ---- task view with persisted overrides --------------------------------
:- dynamic(kb_status/2).
:- dynamic(kb_evidence/2).
:- dynamic(kb_decision/4).
:- dynamic(kb_open_question/2).

state_file_(File) :-
    (   kb_state_file_(F)
    ->  File = F
    ;   File = 'spec-plan-refinement-kb-state.pl'
    ).

:- dynamic(kb_state_file_/1).
:- prolog_load_context(file, Src),
   file_directory_name(Src, Dir),
   atomic_list_concat([Dir, '/spec-plan-refinement-kb-state.pl'], File),
   assertz(kb_state_file_(File)).

consult_state_ :-
    state_file_(File),
    exists_file(File),
    consult(File).

:- (   catch(consult_state_, E, (print_message(error, E), fail))
   ->  true
   ;   true
   ).

kb_task(Task, Kind, Title, Status) :-
    kb_base_task(Task, Kind, Title, Initial),
    (   kb_status(Task, S)
    ->  Status = S
    ;   Status = Initial
    ).

%% ---- queries -----------------------------------------------------------
kb_ready(Task) :-
    kb_task(Task, _, _, pending),
    forall(kb_depends(Task, Dep), kb_task_done(Dep)).

kb_remaining(Task) :-
    kb_task(Task, _, _, Status),
    Status \== done.

kb_task_done(Task) :- kb_task(Task, _, _, done).

kb_blocked_by(Task, Dep, not_done(Dep, Status)) :-
    kb_depends(Task, Dep),
    kb_task(Dep, _, _, Status),
    Status \== done.

kb_dependency_closure(Task, Deps) :-
    kb_closure_(Task, [Task], Deps0),
    sort(Deps0, Deps).

kb_closure_(Task, Seen, Deps) :-
    findall(D, kb_depends(Task, D), Direct),
    foldl(kb_closure_step_(Seen), Direct, [], Acc0),
    foldl(kb_closure_sub_(Seen), Direct, Acc0, Deps).

kb_closure_step_(_Seen, Dep, Acc, [Dep|Acc]).

kb_closure_sub_(Seen, Dep, Acc0, Acc) :-
    (   memberchk(Dep, Seen)
    ->  Acc = Acc0
    ;   kb_closure_(Dep, [Dep|Seen], Sub),
        foldl(kb_closure_step_(Seen), Sub, Acc0, Acc)
    ).

kb_next(Task) :-
    setof(Id-Task, kb_ready_rank_(Task, Id), [_-Task|_]).

kb_ready_rank_(Task, Id) :-
    kb_ready(Task),
    task_id_(Task, Id).

task_id_(Task, Id) :-
    atom_codes(Task, Codes),
    (   append("t", Digits, Codes)
    ->  number_codes(Id, Digits)
    ;   Id = 9999
    ).

%% ---- updates -----------------------------------------------------------
kb_mark(Task, Status) :-
    memberchk(Status, [pending, in_progress, done]),
    (   kb_base_task(Task, _, _, _)
    ->  true
    ;   throw(error(kb_unknown_task(Task), _))
    ),
    retractall(kb_status(Task, _)),
    assertz(kb_status(Task, Status)),
    save_state_.

save_state_ :-
    state_file_(File),
    findall(T-S, kb_status(T, S), Pairs),
    setup_call_cleanup(
        open(File, write, Out),
        forall(member(T-S, Pairs),
               format(Out, ':- assertz(spec_plan_refinement_kb:kb_status(~w, ~w)).~n', [T, S])),
        close(Out)
    ).

kb_validate_decision(Task, DecisionId) :-
    kb_decision(Task, DecisionId, Summary, candidate),
    retractall(kb_decision(Task, DecisionId, Summary, _)),
    assertz(kb_decision(Task, DecisionId, Summary, validated)),
    save_state_.

kb_summary(Summary) :-
    findall(T, kb_task_done(T), Dones),
    findall(T, kb_task(T, _, _, pending), Pendings),
    findall(T, (kb_remaining(T), \+ kb_ready(T)), Blockeds),
    length(Dones, ND), length(Pendings, NP), length(Blockeds, NB),
    format(atom(Summary), 'done=~w pending=~w blocked=~w', [ND, NP, NB]).
