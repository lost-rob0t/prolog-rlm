:- module(rlm_task_workflow,
    [ task_workflow_create/3, task_workflow_validate/2, task_workflow_add/3,
      task_workflow_transition/5, task_workflow_ready/2,
      task_workflow_bind/4, task_workflow_verify/6, task_workflow_refresh/3 ]).

/** Pure, bounded task state for hosts implementing project/run journals.
    No filesystem, command execution, scheduler, or model authority is added.
    Frozen specs and observations enter only through a trusted host, never a
    model tool accepting a claimed success flag. Persistence is host-owned.
*/
:- use_module(library(lists)).
:- meta_predicate result(0,?,?).
:- use_module(rlm_spec, [spec_inspect/2]).
:- use_module(rlm_verify, [spec_verify/4]).
:- use_module(rlm_evidence, [observation_normalize/2, evidence_policy_accepts/3]).

task_workflow_create(Project, Ref, Outcome) :-
    result((identity(Project), identity(Ref),
      State=task_workflow{version:1,project:Project,state_ref:project_state(Project,Ref),revision:0,tasks:[],events:[]}),State,Outcome).
task_workflow_validate(State, Outcome) :- result(validate(State),State,Outcome).
task_workflow_add(State, Input, Outcome) :-
    result((validate(State), closed_keys(Input,[id,title,dependencies]),
      identity(Input.id), string(Input.title), string_length(Input.title,N), N=<4096,
      is_list(Input.dependencies), sort(Input.dependencies,Deps),
      length(Deps,Count),length(Input.dependencies,Count),
      \+ task(State,Input.id,_), length(State.tasks,Size), Size<256,
      forall(member(D,Deps),task(State,D,_)),
      T=task{id:Input.id,title:Input.title,dependencies:Deps,status:pending,
             reason:"",spec:none,verification:none},
      append(State.tasks,[T],Tasks), advance(State,Tasks,added(Input.id),Next)),Next,Outcome).
task_workflow_transition(State, Id, Status, Reason, Outcome) :-
    result((validate(State), task(State,Id,T),
      memberchk(Status,[pending,active,blocked,cancelled]), string(Reason),
      string_length(Reason,N),N=<4096,
      (Status==active -> dependencies_done(State,T) ; true),
      put_dict(_{status:Status,reason:Reason,verification:none},T,U),
      replace_task(State,Id,U,Tasks), invalidate_dependents(Tasks,Id,Invalidated),
      advance(State,Invalidated,transition(Id,Status,Reason),Next)),Next,Outcome).
task_workflow_ready(State, Outcome) :-
    result((validate(State),findall(Id,(task(State,Id,T),T.status==pending,
                                     dependencies_done(State,T)),Ids)),Ids,Outcome).
task_workflow_bind(State, Id, Frozen, Outcome) :-
    result((validate(State), task(State,Id,T), valid_bound_spec(State,Frozen),
      put_dict(_{spec:Frozen,status:pending,verification:none},T,U),
      replace_task(State,Id,U,Tasks),invalidate_dependents(Tasks,Id,Invalidated),
      advance(State,Invalidated,bound(Id,Frozen.ref),Next)),Next,Outcome).

task_workflow_verify(State, Id, Observations, Registry, Outcome, Verification) :-
    catch((validate(State), task(State,Id,T), T.spec\==none,
      dependencies_done(State,T), is_list(Observations),
      maplist(current_observation(State.state_ref),Observations),
      spec_verify(T.spec,Observations,Registry,Verification), Verification=ok(Report),
      (Report.status==passed -> Status=done ; Status=blocked),
      put_dict(_{status:Status,verification:Report,reason:"verification"},T,U),
      replace_task(State,Id,U,Tasks),invalidate_dependents(Tasks,Id,Invalidated),
      advance(State,Invalidated,verified(Id,Report.status),Next)
      -> Outcome=ok(Next)
      ; Outcome=error(task_workflow_error(invalid_verification)),
        (var(Verification)->Verification=error(invalid_verification);true)),
      E,(control_exception(E),Outcome=error(task_workflow_error(E)),
         (var(Verification)->Verification=error(E);true))).
current_observation(Ref,O) :- observation_normalize(O,ok(N)),
    N.state_ref==Ref,N.freshness==current,memberchk(N.trust_class,[observed,trusted]),
    N.source_class\==model_claim.

task_workflow_refresh(State, Revision, Outcome) :-
    result((validate(State),identity(Revision),Ref=project_state(State.project,Revision),
      (Ref==State.state_ref -> Next=State
      ; maplist(invalidate,State.tasks,Tasks),
        advance(State,Tasks,state_changed(State.state_ref,Ref),Changed),
        put_dict(state_ref,Changed,Ref,Next))),Next,Outcome).
invalidate(T,U) :-
    (memberchk(T.status,[done,active]) -> Status=pending ; Status=T.status),
    put_dict(_{status:Status,verification:none,spec:none},T,U).

validate(S) :-
    ground(S),acyclic_term(S),is_dict(S,task_workflow),
    closed_keys(S,[version,project,state_ref,revision,tasks,events]),S.version==1,
    identity(S.project),S.state_ref=project_state(S.project,_),identity(S.state_ref),
    integer(S.revision),S.revision>=0,
    is_list(S.tasks),length(S.tasks,N),N=<256,
    is_list(S.events),length(S.events,E),E=<4096,E=:=S.revision,
    valid_events(S.events,1),
    maplist(valid_task(S),S.tasks),findall(Id,task(S,Id,_),Ids),sort(Ids,Unique),length(Unique,N),
    ordered_dependencies(S.tasks,[]),
    forall((task(S,_,T),T.status==done),
      (dependencies_done(S,T),T.verification\==none,T.verification.status==passed)).
valid_task(S,T) :-
    is_dict(T,task),closed_keys(T,[id,title,dependencies,status,reason,spec,verification]),
    identity(T.id),bounded_text(T.title),bounded_text(T.reason),
    is_list(T.dependencies),sort(T.dependencies,Deps),length(Deps,N),length(T.dependencies,N),
    memberchk(T.status,[pending,active,blocked,done,cancelled]),
    (T.spec==none -> T.verification==none ; valid_bound_spec(S,T.spec)),
    (T.verification==none -> true
     ; memberchk(T.status,[done,blocked]),valid_report(S,T.spec,T.verification)).
valid_bound_spec(S,Frozen) :-
    spec_inspect(Frozen,ok(Inspection)),Inspection.required_ids\==[],
    Frozen.subject.project==S.project,
    forall((member(R,Frozen.requirements),R.severity==required),
      (R.evidence_policy.required_evidence==true,
       R.evidence_policy.freshness==current,
       R.evidence_policy.state_ref==S.state_ref,
       R.evidence_policy.trust_classes\==all,
       forall(member(C,R.evidence_policy.trust_classes),memberchk(C,[observed,trusted])))).
valid_report(S,F,R) :-
    is_dict(R,verification_report),
    closed_keys(R,[spec_ref,status,requirements,observations,evidence_refs,provenance]),
    R.spec_ref==F.ref,
    R.provenance==verification_provenance{mode:pure,verifier:rlm_verify,version:1},
    memberchk(R.status,[passed,rejected]),is_list(R.requirements),
    findall(Id,(member(Q,F.requirements),Id=Q.id),Ids),
    findall(Id,(member(Q,R.requirements),Id=Q.id),Ids),
    maplist(current_observation(S.state_ref),R.observations),
    findall(Id,(member(O,R.observations),Id=O.requirement_id),ObsIds),
    sort(ObsIds,Unique),length(ObsIds,N),length(Unique,N),
    maplist(valid_check(R.observations),F.requirements,R.requirements),
    findall(Ref,(member(C,R.requirements),member(Ref,C.evidence_refs)),Refs),
    sort(Refs,R.evidence_refs),
    (forall((member(C,R.requirements),C.severity==required),C.status==passed)
     -> R.status==passed ; R.status==rejected).
valid_check(Observations,Q,C) :-
    is_dict(C,verification_requirement),
    closed_keys(C,[id,assertion,severity,evidence_policy,verifier,collector,status,
                   observation,evidence_refs,provenance]),
    forall(member(K,[id,assertion,severity,evidence_policy,verifier,collector,provenance]),
      (get_dict(K,Q,V),get_dict(K,C,V))),
    (C.observation==none
     -> C.status\==passed,C.evidence_refs==[],
        \+ (member(O,Observations),O.requirement_id==Q.id)
     ; member(O,Observations),O==C.observation,O.requirement_id==Q.id,
       O.assertion==Q.assertion,O.verifier==Q.verifier,O.collector==Q.collector,
       C.evidence_refs==O.evidence_refs,
       (C.status==passed -> O.status==passed,
         evidence_policy_accepts(Q.evidence_policy,O,ok(accepted)) ; true)).
bounded_text(T) :- string(T),string_length(T,N),N=<4096.
valid_events([],_).
valid_events([event(N,E)|Es],N) :- valid_event(E),Next is N+1,valid_events(Es,Next).
valid_event(added(Id)) :- identity(Id).
valid_event(transition(Id,Status,Reason)) :- identity(Id),
    memberchk(Status,[pending,active,blocked,cancelled]),bounded_text(Reason).
valid_event(bound(Id,Ref)) :- identity(Id),identity(Ref).
valid_event(verified(Id,Status)) :- identity(Id),memberchk(Status,[passed,rejected]).
valid_event(state_changed(Old,New)) :- identity(Old),identity(New).
ordered_dependencies([], _).
ordered_dependencies([T|Ts], Seen) :- forall(member(D,T.dependencies),memberchk(D,Seen)),
    ordered_dependencies(Ts,[T.id|Seen]).
task(S,Id,T) :- member(T,S.tasks),Id=T.id.
dependencies_done(S,T) :- forall(member(D,T.dependencies),(task(S,D,U),U.status==done)).
replace_task(S,Id,U,Tasks) :- maplist(replace(Id,U),S.tasks,Tasks).
replace(Id,U,T,V) :- (T.id==Id -> V=U ; V=T).
% Ordered DAG means one forward pass invalidates every downstream completion.
invalidate_dependents(Tasks,Id,Out) :- invalidate_chain(Tasks,[Id],Out).
invalidate_chain([],_,[]).
invalidate_chain([T|Ts],Changed,[U|Us]) :-
    (member(D,T.dependencies),memberchk(D,Changed)
    -> (memberchk(T.status,[done,active])->Status=pending;Status=T.status),
       put_dict(_{status:Status,verification:none},T,U),Next=[T.id|Changed]
    ; U=T,Next=Changed),
    invalidate_chain(Ts,Next,Us).
advance(S,Tasks,Event,Next) :- R is S.revision+1,
    length(S.events,N),N<4096,append(S.events,[event(R,Event)],Events),
    put_dict(_{tasks:Tasks,revision:R,events:Events},S,Next).
identity(V) :- ground(V),acyclic_term(V),V\==none,V\==any.
closed_keys(D,Keys) :- is_dict(D),dict_pairs(D,_,Pairs),
    findall(K,member(K-_,Pairs),Actual),sort(Keys,Sorted),Actual==Sorted.
result(Goal,Value,Outcome) :-
    catch((call(Goal)->Outcome=ok(Value);Outcome=error(task_workflow_error(invalid_request))),
      E,(control_exception(E),Outcome=error(task_workflow_error(E)))).

control_exception(E) :-
    (memberchk(E,[time_limit_exceeded,inference_limit_exceeded,abort])
     -> throw(E) ; true).
