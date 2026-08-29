/* Long-horizon research/design KB for the SPEC/VALIDATE/PLAN architecture
 * (rewrite of the PR #290 design; durable output:
 * docs/research/spec-plan-authority.md).
 *
 * Hardened completion discipline (design-gate enforced):
 *   - a task is authoritative only with status done AND completion evidence
 *     (kb_evidence/2) or a validated decision (kb_decision/4 in state
 *     validated); a bare status(done) fact is never proof;
 *   - dependencies must reference declared tasks (no ghosts);
 *   - the dependency graph must be acyclic;
 *   - persisted state includes status, evidence, decisions with validation
 *     state, and open questions.
 *
 * State persists in research/spec-plan-refinement-kb-state.pl as
 * module-qualified assertz directives written by the kb_* update predicates.
 *
 * Queries:
 *   kb_ready/1, kb_remaining/1, kb_blocked_by/3, kb_dependency_closure/2,
 *   kb_next/1, kb_task_done/1, kb_summary/1
 * Checks:
 *   kb_violation/1, kb_check/0
 * Updates:
 *   kb_mark/2, kb_record_evidence/2, kb_decide/3, kb_validate_decision/2
 */
:- module(spec_plan_refinement_kb,
          [ kb_task/4, kb_depends/2, kb_evidence/2, kb_decision/4,
            kb_open_question/2, kb_ready/1, kb_remaining/1,
            kb_blocked_by/3, kb_dependency_closure/2, kb_next/1,
            kb_task_done/1, kb_mark/2, kb_record_evidence/2,
            kb_decide/3, kb_validate_decision/2,
            kb_violation/1, kb_check/0, kb_summary/1
          ]).

%% ---- base tasks (design pass d*, implementation slices s*) --------------
kb_base_task(d01, research, 'Inventory merged main + unmerged branches; classify IMPLEMENTED/UNMERGED/NEW', pending).
kb_base_task(d02, design,   'Canonical SPEC grammar decision: merged rlm_spec_lang spec(Forms) unchanged; no spec/2', pending).
kb_base_task(d03, design,   'Canonical reference grammar: symbol_ref vs syntax_ref vs source_span; diff sides', pending).
kb_base_task(d04, design,   'Canonical PLAN grammar: rage/288 BASE adoption + explicit D6 deltas', pending).
kb_base_task(d05, design,   'Typed expert dataflow: expr leaves, admission-time binding resolution', pending).
kb_base_task(d06, design,   'Expert contracts, iterative coding-loop ownership, edit_action schema', pending).
kb_base_task(d07, design,   'Assertion-kind packs: language/symbol/build/test requirements', pending).
kb_base_task(d08, design,   'TDD RED/GREEN evidence contract (tdd_evidence pair)', pending).
kb_base_task(d09, design,   'HTTP request/response contracts + network extension points', pending).
kb_base_task(d10, design,   'Network authority mapping (spec grants nothing)', pending).
kb_base_task(d11, design,   'plan_validate_against_spec/4 + replan safety (patches cannot drop obligations)', pending).
kb_base_task(d12, design,   'Durability: durable plan KB with bindings + research KB evidence gating', pending).
kb_base_task(d13, design,   'Implementation dependency DAG S0..S11', pending).
kb_base_task(d14, gate,     'Executable design gate replacing false-green presence checks', pending).
kb_base_task(s00, impl,     'S0: merge rage/288 plan-graph BASE unchanged', pending).
kb_base_task(s01, impl,     'S1: rlm_project_reference normalized reference layer', pending).
kb_base_task(s02, impl,     'S2: project index/retrieval engine (symbol extraction, observations)', pending).
kb_base_task(s03, impl,     'S3: diff sides incl revision resolution', pending).
kb_base_task(s04, impl,     'S4: write engine (edit_action application, effect boundary)', pending).
kb_base_task(s05, impl,     'S5: D6 deltas (expr dataflow, content, obligations, expert contracts)', pending).
kb_base_task(s06, impl,     'S6: assertion provider pack language/build/test/symbol/TDD', pending).
kb_base_task(s07, impl,     'S7: HTTP/network provider pack + normalized observation', pending).
kb_base_task(s08, impl,     'S8: plan_validate_against_spec/4 + patches + replan safety', pending).
kb_base_task(s09, impl,     'S9: durable plan KB (bindings, checkpoints, resume)', pending).
kb_base_task(s10, impl,     'S10: strategy adoption (merge rlm_direct/rlm_spec_strategy; model_step_handler)', pending).
kb_base_task(s11, impl,     'S11: rlm_spec_workflow integration + docs/roadmap reconciliation', pending).

%% ---- dependencies -------------------------------------------------------
kb_depends(d02, d01).
kb_depends(d03, d01).
kb_depends(d04, d01).
kb_depends(d04, d03).
kb_depends(d05, d04).
kb_depends(d06, d05).
kb_depends(d07, d03).
kb_depends(d08, d07).
kb_depends(d09, d03).
kb_depends(d10, d09).
kb_depends(d11, d04).
kb_depends(d11, d07).
kb_depends(d12, d05).
kb_depends(d12, d11).
kb_depends(d13, d02).
kb_depends(d13, d04).
kb_depends(d13, d05).
kb_depends(d13, d06).
kb_depends(d13, d07).
kb_depends(d13, d08).
kb_depends(d13, d09).
kb_depends(d13, d11).
kb_depends(d13, d12).
kb_depends(d14, d02).
kb_depends(d14, d04).
kb_depends(d14, d05).
kb_depends(d14, d07).
kb_depends(d14, d08).
kb_depends(d14, d09).
kb_depends(d14, d11).
kb_depends(d14, d12).
kb_depends(d14, d13).

kb_depends(s00, d04).
kb_depends(s01, s00).
kb_depends(s02, s01).
kb_depends(s03, s02).
kb_depends(s04, s01).
kb_depends(s05, s00).
kb_depends(s05, s04).
kb_depends(s06, s05).
kb_depends(s07, s05).
kb_depends(s08, s06).
kb_depends(s09, s05).
kb_depends(s10, s05).
kb_depends(s11, s08).
kb_depends(s11, s09).
kb_depends(s11, s10).
kb_depends(s11, s07).
kb_depends(s11, s06).

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

%% ---- completion discipline ----------------------------------------------
% A task is done only with persisted status done AND completion evidence or a
% validated decision. Self-attested status(done) alone is never authoritative.
kb_task_done(Task) :-
    kb_task(Task, _, _, done),
    completion_evidence_(Task).

completion_evidence_(Task) :-
    kb_evidence(Task, _).
completion_evidence_(Task) :-
    kb_decision(Task, _, _, validated).

%% ---- queries -----------------------------------------------------------
kb_ready(Task) :-
    kb_task(Task, _, _, pending),
    forall(kb_depends(Task, Dep), kb_task_done(Dep)).

kb_remaining(Task) :-
    kb_task(Task, _, _, Status),
    Status \== done.

kb_blocked_by(Task, Dep, not_done(Dep, Status)) :-
    kb_depends(Task, Dep),
    kb_task(Dep, _, _, Status),
    Status \== done.

kb_blocked_by(Task, Dep, missing_evidence(Dep)) :-
    kb_depends(Task, Dep),
    kb_task(Dep, _, _, done),
    \+ completion_evidence_(Dep).

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
    (   append("d", Digits, Codes)
    ->  number_codes(Id, Digits)
    ;   append("s", Digits, Codes)
    ->  number_codes(Id, Digits)
    ;   Id = 9999
    ).

%% ---- consistency checks (design-gate enforced) --------------------------
:- discontiguous(kb_violation/1).
kb_violation(evidence_free_done(Task)) :-
    kb_status(Task, done),
    \+ completion_evidence_(Task).

kb_violation(ghost_dependency(Task, Dep)) :-
    kb_depends(Task, Dep),
    \+ kb_base_task(Dep, _, _, _).

kb_violation(cycle(Cycle)) :-
    kb_depends(Start, _),
    kb_cycle_dfs(Start, [Start], Reversed),
    reverse(Reversed, Cycle).

% DFS walk over kb_depends/2; a back edge to a node on the current path is a
% cycle witness [Next|Path] (Next -> ... -> Current -> ... -> Start).
kb_cycle_dfs(Node, Path, [Next|Path]) :-
    kb_depends(Node, Next),
    memberchk(Next, Path),
    !.
kb_cycle_dfs(Node, Path, Cycle) :-
    kb_depends(Node, Next),
    \+ memberchk(Next, Path),
    kb_cycle_dfs(Next, [Next|Path], Cycle).

kb_violation(candidate_decision_treated_validated(Task, DecisionId)) :-
    kb_decision(Task, DecisionId, _, candidate),
    kb_task_done(Task).

kb_check :-
    \+ kb_violation(_).

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

kb_record_evidence(Task, EvidenceRef) :-
    (   kb_base_task(Task, _, _, _)
    ->  true
    ;   throw(error(kb_unknown_task(Task), _))
    ),
    ground(EvidenceRef),
    (   kb_evidence(Task, EvidenceRef)
    ->  true
    ;   assertz(kb_evidence(Task, EvidenceRef))
    ),
    save_state_.

kb_decide(Task, DecisionId, Summary) :-
    (   kb_base_task(Task, _, _, _)
    ->  true
    ;   throw(error(kb_unknown_task(Task), _))
    ),
    retractall(kb_decision(Task, DecisionId, _, _)),
    assertz(kb_decision(Task, DecisionId, Summary, candidate)),
    save_state_.

kb_validate_decision(Task, DecisionId) :-
    kb_decision(Task, DecisionId, Summary, candidate),
    retractall(kb_decision(Task, DecisionId, Summary, _)),
    assertz(kb_decision(Task, DecisionId, Summary, validated)),
    save_state_.

save_state_ :-
    state_file_(File),
    findall(T-S, kb_status(T, S), StatusPairs),
    findall(T-E, kb_evidence(T, E), EvidencePairs),
    findall(T-Id-Sum-St, kb_decision(T, Id, Sum, St), DecisionQuads),
    findall(T-Q, kb_open_question(T, Q), QuestionPairs),
    setup_call_cleanup(
        open(File, write, Out),
        (   forall(member(T-S, StatusPairs),
                   format(Out, ':- assertz(spec_plan_refinement_kb:kb_status(~w, ~w)).~n', [T, S])),
            forall(member(T-E, EvidencePairs),
                   format(Out, ':- assertz(spec_plan_refinement_kb:kb_evidence(~w, ~w)).~n', [T, E])),
            forall(member(T-Id-Sum-St, DecisionQuads),
                   format(Out, ':- assertz(spec_plan_refinement_kb:kb_decision(~w, ~w, ~w, ~w)).~n',
                          [T, Id, Sum, St])),
            forall(member(T-Q, QuestionPairs),
                   format(Out, ':- assertz(spec_plan_refinement_kb:kb_open_question(~w, ~w)).~n', [T, Q]))
        ),
        close(Out)
    ).

kb_summary(Summary) :-
    findall(T, kb_task_done(T), Dones),
    findall(T, kb_task(T, _, _, pending), Pendings),
    findall(T, (kb_remaining(T), \+ kb_ready(T)), Blockeds),
    length(Dones, ND), length(Pendings, NP), length(Blockeds, NB),
    format(atom(Summary), 'done=~w pending=~w blocked=~w', [ND, NP, NB]).
