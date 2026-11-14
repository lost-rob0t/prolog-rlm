:- begin_tests(rlm_task_workflow).
:- use_module('../prolog/rlm_task_workflow').

test(dependency_selection) :-
    task_workflow_create(project, r1, ok(S0)),
    task_workflow_add(S0, task{id:design,title:"Design",dependencies:[]}, ok(S1)),
    task_workflow_add(S1, task{id:build,title:"Build",dependencies:[design]}, ok(S2)),
    task_workflow_ready(S2, ok([design])),
    task_workflow_transition(S2, build, active, "start", error(_)),
    task_workflow_transition(S2, design, active, "start", ok(S3)),
    task_workflow_transition(S3, design, done, "trust me", error(_)).
test(missing_dependency_rejected) :-
    task_workflow_create(project,r1,ok(S)),
    task_workflow_add(S,task{id:x,title:"x",dependencies:[unknown]},error(_)).
test(project_revision_invalidates_verified_tasks) :-
    task_workflow_create(project,r1,ok(S0)),
    task_workflow_add(S0,task{id:x,title:"x",dependencies:[]},ok(S1)),
    task_workflow_refresh(S1,r2,ok(S2)), assertion(S2.state_ref==project_state(project,r2)),
    assertion(S2.revision=:=2).
test(no_model_provided_completion) :-
    task_workflow_create(project,r1,ok(S)),
    task_workflow_add(S,task{id:x,title:"x",dependencies:[],status:done},error(_)).
test(blocked_reason_and_history) :-
    task_workflow_create(project,r1,ok(S0)),
    task_workflow_add(S0,task{id:x,title:"x",dependencies:[]},ok(S1)),
    task_workflow_transition(S1,x,blocked,"missing input",ok(S2)),
    task_workflow_ready(S2,ok([])), S2.tasks=[T], assertion(T.reason=="missing input"),
    assertion(S2.events=[_,_]).

:- use_module('../prolog/rlm_spec').
:- use_module('../prolog/rlm_verify').
registry([assertion_provider(check,1,plunit_rlm_task_workflow:args,
    plunit_rlm_task_workflow:evaluate,plunit_rlm_task_workflow:observe,
    _{verifier:_{id:check,version:1},collector:_{id:fixture,version:1},latency:pure,
      evidence_policy:_{required_evidence:true,source_classes:[host],
                       trust_classes:[observed],freshness:current,state_ref:project_state(project,r1)}})]).
args(A) :- is_dict(A).
evaluate(_,O,Status) :- (O.value==true->Status=passed;Status=failed).
observe(_, [Value], _, _{status:passed,value:Value,evidence_refs:[test_receipt],
    source_class:host,trust_class:observed,freshness:current,state_ref:project_state(project,r1)}).
bound(S,F,R) :-
    registry(R), spec_validate(_{schema_version:1,subject:_{project:project},requirements:[_{id:check,
        assertion:assertion(check,_{}),severity:required}]},R,ok(V)),
    spec_freeze(V,[],ok(F)), task_workflow_create(project,r1,ok(A)),
    task_workflow_add(A,task{id:x,title:"x",dependencies:[]},ok(B)),
    task_workflow_bind(B,x,F,ok(S)).
test(verified_completion_and_revision_staleness) :-
    bound(S,F,R),spec_observe(F,[true],R,[],ok(Collected)),
    task_workflow_verify(S,x,Collected,R,ok(Done),ok(Report)),
    assertion(Report.status==passed),Done.tasks=[T],assertion(T.status==done),
    task_workflow_refresh(Done,r2,ok(Stale)),Stale.tasks=[U],
    assertion(U.status==pending),assertion(U.spec==none),assertion(U.verification==none).
test(failed_check_cannot_complete) :-
    bound(S,F,R),spec_observe(F,[false],R,[],ok(Collected)),
    task_workflow_verify(S,x,Collected,R,ok(Failed),ok(Report)),
    assertion(Report.status==rejected),Failed.tasks=[T],assertion(T.status==blocked).
test(missing_evidence_cannot_complete) :-
    bound(S,_,R),task_workflow_verify(S,x,[],R,ok(Failed),ok(_)),
    Failed.tasks=[T],assertion(T.status==blocked).
test(stale_observation_rejected) :-
    bound(S,F,R),spec_observe(F,[true],R,[],ok(C)),C=[O],
    put_dict(state_ref,O,r0,Stale),
    task_workflow_verify(S,x,[Stale],R,error(_),_).
test(model_claim_rejected) :-
    bound(S,F,R),spec_observe(F,[true],R,[],ok(C)),C=[O],
    put_dict(trust_class,O,model_claim,Claim),
    task_workflow_verify(S,x,[Claim],R,error(_),_).
test(reopening_invalidates_descendant) :-
    bound(S,F,R),spec_observe(F,[true],R,[],ok(C)),
    task_workflow_verify(S,x,C,R,ok(Done),ok(_)),
    task_workflow_add(Done,task{id:y,title:"y",dependencies:[x]},ok(Added)),
    task_workflow_transition(Added,y,active,"work",ok(Active)),
    task_workflow_transition(Active,x,pending,"redo",ok(Reset)),
    Reset.tasks=[_,Y],assertion(Y.status==pending),
    task_workflow_ready(Reset,ok([x])).
test(duplicate_ids_rejected) :-
    task_workflow_create(project,r1,ok(A)),T=task{id:x,title:"x",dependencies:[]},
    task_workflow_add(A,T,ok(B)),task_workflow_add(B,T,error(_)).
test(other_project_spec_rejected) :-
    bound(_,F,_),task_workflow_create(other,r1,ok(A)),
    task_workflow_add(A,task{id:x,title:"x",dependencies:[]},ok(B)),
    task_workflow_bind(B,x,F,error(_)).
test(snapshot_validation_rejects_duplicate_ids) :-
    task_workflow_create(project,r1,ok(A)),
    task_workflow_add(A,task{id:x,title:"x",dependencies:[]},ok(B)),B.tasks=[T],
    put_dict(tasks,B,[T,T],Bad),task_workflow_validate(Bad,error(_)).

test(restored_spec_must_obey_binding_contract) :-
    bound(S,_,R),
    spec_validate(_{schema_version:1,subject:_{project:project},requirements:[_{id:check,
        assertion:assertion(check,_{}),severity:optional}]},R,ok(V)),
    spec_freeze(V,[],ok(OptionalSpec)),
    S.tasks=[T],put_dict(spec,T,OptionalSpec,BadTask),put_dict(tasks,S,[BadTask],Bad),
    task_workflow_validate(Bad,error(_)),
    task_workflow_verify(Bad,x,[],R,error(_),_).
test(restored_title_bound) :-
    task_workflow_create(project,r1,ok(A)),
    task_workflow_add(A,task{id:x,title:"x",dependencies:[]},ok(B)),B.tasks=[T],
    length(Cs,4097),maplist(=(0'x),Cs),string_codes(Long,Cs),
    put_dict(title,T,Long,U),put_dict(tasks,B,[U],Bad),task_workflow_validate(Bad,error(_)).
test(restored_closed_keys) :-
    task_workflow_create(project,r1,ok(A)),put_dict(override,A,true,Bad),
    task_workflow_validate(Bad,error(_)).

test(restored_report_must_match_spec) :-
    bound(S,F,R),spec_observe(F,[true],R,[],ok(Obs)),
    task_workflow_verify(S,x,Obs,R,ok(Done),ok(Report)),
    put_dict(spec_ref,Report,wrong,Wrong),Done.tasks=[T],
    put_dict(verification,T,Wrong,U),put_dict(tasks,Done,[U],Bad),
    task_workflow_validate(Bad,error(_)).
test(restored_reason_bound) :-
    bound(S,_,_),S.tasks=[T],length(Cs,4097),maplist(=(0'x),Cs),string_codes(Long,Cs),
    put_dict(reason,T,Long,U),put_dict(tasks,S,[U],Bad),task_workflow_validate(Bad,error(_)).
test(restored_task_closed_keys) :-
    bound(S,_,_),S.tasks=[T],put_dict(override,T,true,U),put_dict(tasks,S,[U],Bad),
    task_workflow_validate(Bad,error(_)).
test(restored_duplicate_dependencies) :-
    task_workflow_create(project,r1,ok(A)),
    task_workflow_add(A,task{id:x,title:"x",dependencies:[]},ok(B)),
    task_workflow_add(B,task{id:y,title:"y",dependencies:[x]},ok(C)),C.tasks=[X,Y],
    put_dict(dependencies,Y,[x,x],U),put_dict(tasks,C,[X,U],Bad),task_workflow_validate(Bad,error(_)).
test(restored_event_revision_coherence) :-
    bound(S,_,_),put_dict(revision,S,999,Bad),task_workflow_validate(Bad,error(_)),
    put_dict(events,S,[event(99,added(x)),event(2,bound(x,ref))],Other),
    task_workflow_validate(Other,error(_)).

test(restored_fabricated_report_without_observations_rejected) :-
    bound(S,F,R),spec_observe(F,[true],R,[],ok(Obs)),
    task_workflow_verify(S,x,Obs,R,ok(Done),ok(_)),
    Fake=verification_report{spec_ref:F.ref,status:passed,
      requirements:[check{id:check,status:passed}],observations:[],evidence_refs:[unrelated_receipt]},
    Done.tasks=[T],put_dict(verification,T,Fake,U),put_dict(tasks,Done,[U],Bad),
    task_workflow_validate(Bad,error(_)).
test(restored_passed_check_requires_linked_observation) :-
    bound(S,F,R),spec_observe(F,[true],R,[],ok(Obs)),
    task_workflow_verify(S,x,Obs,R,ok(Done),ok(Report)),
    put_dict(observations,Report,[],Fake),Done.tasks=[T],
    put_dict(verification,T,Fake,U),put_dict(tasks,Done,[U],Bad),task_workflow_validate(Bad,error(_)).
test(restored_report_evidence_refs_match_checks) :-
    bound(S,F,R),spec_observe(F,[true],R,[],ok(Obs)),
    task_workflow_verify(S,x,Obs,R,ok(Done),ok(Report)),
    put_dict(evidence_refs,Report,[unrelated],Fake),Done.tasks=[T],
    put_dict(verification,T,Fake,U),put_dict(tasks,Done,[U],Bad),task_workflow_validate(Bad,error(_)).

test(rejected_verifier_mismatch_remains_resumable) :-
    bound(S,F,R),spec_observe(F,[true],R,[],ok([O])),
    put_dict(verifier,O,verifier{id:wrong,version:1},Mismatch),
    task_workflow_verify(S,x,[Mismatch],R,ok(Blocked),ok(Report)),
    assertion(Report.status==rejected),task_workflow_validate(Blocked,ok(_)),
    task_workflow_transition(Blocked,x,pending,"recollect",ok(_)).
test(rejected_assertion_mismatch_remains_resumable) :-
    bound(S,F,R),spec_observe(F,[true],R,[],ok([O])),
    put_dict(assertion,O,assertion(other,assertion_args{}),Mismatch),
    task_workflow_verify(S,x,[Mismatch],R,ok(Blocked),ok(Report)),
    assertion(Report.status==rejected),task_workflow_validate(Blocked,ok(_)).
test(rejected_registry_mismatch_remains_resumable) :-
    bound(S,F,R),spec_observe(F,[true],R,[],ok(Obs)),
    R=[assertion_provider(K,V,A,E,C,M)],put_dict(verifier,M,_{id:changed,version:2},NewM),
    NewR=[assertion_provider(K,V,A,E,C,NewM)],
    task_workflow_verify(S,x,Obs,NewR,ok(Blocked),ok(Report)),
    assertion(Report.status==rejected),task_workflow_validate(Blocked,ok(_)).
:- end_tests(rlm_task_workflow).
