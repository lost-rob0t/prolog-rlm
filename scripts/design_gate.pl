:- module(design_gate,
          [ main/0,
            record_count_args/1, file_language_args/1, symbol_exists_args/1,
            symbol_arity_args/1, build_ok_args/1, test_passes_args/1,
            test_exists_args/1, behavior_tested_args/1, tdd_evidence_args/1,
            public_api_args/1, http_endpoint_args/1,
            count_evaluator/3, language_evaluator/3, symbol_evaluator/3,
            build_evaluator/3, test_evaluator/3, tdd_evidence_evaluator/3,
            api_evaluator/3, http_evaluator/3,
            locate_handler/2, read_handler/2
          ]).

/* SPEC/VALIDATE/PLAN design gate for docs/research/spec-plan-authority.md.
 *
 * This gate validates the NORMATIVE DESIGN through real implementations,
 * replacing the presence-only #288 contract script (which was false-green).
 *
 * Layers, explicitly labeled:
 *   - IMPLEMENTED: merged-main modules (rlm_spec_lang, rlm_spec,
 *     rlm_assertion, rlm_evidence, rlm_verify, rlm_plan, rlm_tool,
 *     rlm_graph_persist) are loaded FROM THIS CHECKOUT; every SPEC grammar,
 *     expression-grammar, desugared-plan, evidence and persistency check
 *     runs through their real code. This checkout also carries branch-only
 *     features (e.g. rlm_plan's model_step_handler hook,
 *     rlm_tool's capability_shape(spec/1|plan/1)); those are validated as
 *     UNMERGED-adoption surface (design record §2.2), NOT as merged main.
 *   - UNMERGED BASE: prolog/rlm_plan_graph.pl is extracted from the
 *     rage/288-spec-plan-graph-executor git object and loaded; BASE plan
 *     graphs validate through its real code. If the branch is missing the
 *     gate fails loudly: the BASE is a required adoption input, not a copy.
 *   - NEW DESIGN TARGETS: the D6 delta grammar, plan-vs-spec compatibility,
 *     the TDD evaluator, HTTP contract schemas, edit_action / expert
 *     contracts, the snapshot schema, KB discipline and the implementation
 *     DAG are checked by gate-local trusted checkers implementing the
 *     design record. These remain the normative checkers until slices
 *     S5/S6/S7/S8 implement them in production modules.
 *
 * Deterministic; no model or network calls.  Usage:
 *   swipl -q -s scripts/design_gate.pl
 */

:- use_module(library(lists)).
:- use_module(library(process)).

:- dynamic(gate_root/1).
:- dynamic(check_failure/2).
:- dynamic(check_defined/1).

:- prolog_load_context(file, GateFile),
   file_directory_name(GateFile, GateDir),
   atomic_list_concat([GateDir, '/..'], Root0),
   absolute_file_name(Root0, Root),
   assertz(gate_root(Root)).

/* ------------------------------------------------------------------ */
/* Bootstrap                                                           */
/* ------------------------------------------------------------------ */

load_merged_modules :-
    gate_root(Root),
    atomic_list_concat([Root, '/prolog/rlm_spec_lang.pl'], SpecLang),
    atomic_list_concat([Root, '/prolog/rlm_spec.pl'], Spec),
    atomic_list_concat([Root, '/prolog/rlm_assertion.pl'], Assertion),
    atomic_list_concat([Root, '/prolog/rlm_evidence.pl'], Evidence),
    atomic_list_concat([Root, '/prolog/rlm_verify.pl'], Verify),
    atomic_list_concat([Root, '/prolog/rlm_plan.pl'], Plan),
    atomic_list_concat([Root, '/prolog/rlm_tool.pl'], Tool),
    atomic_list_concat([Root, '/prolog/rlm_graph_persist.pl'], Persist),
    forall(member(File, [SpecLang, Spec, Assertion, Evidence, Verify,
                         Plan, Tool, Persist]),
           (   exists_file(File)
           ->  use_module(File)
           ;   throw(gate_fault(missing_merged_module(File)))
           )).

/* BASE adoption input: the BASE object id is PINNED. Ref names are only
 * hints for locating that object in whatever clone the gate runs in:
 * canonical CI clones carry only refs/remotes/REMOTE/BRANCH entries for
 * branches that exist on the CI remote, so a bare local branch name
 * (git DWIM) does not resolve there. The pinned id remains the authority
 * even if a ref moves; the gate fails loudly when no candidate locates it.
 */
base_branch('rage/288-spec-plan-graph-executor').
base_pinned_commit('71a10ae238dd0fa288005bf10892dc8d865ef2f3').

base_ref_candidates([Pinned, Heads, Origin, Github]) :-
    base_branch(Branch),
    base_pinned_commit(Pinned),
    atomic_list_concat(['refs/heads/', Branch], Heads),
    atomic_list_concat(['refs/remotes/origin/', Branch], Origin),
    atomic_list_concat(['refs/remotes/github/', Branch], Github).

% First candidate (in declared order) that names a commit object present in
% this clone. Fails when no candidate resolves; callers report the list.
first_resolvable_candidate(Candidates, Candidate) :-
    member(Candidate, Candidates),
    base_candidate_commit(Candidate, _),
    !.

% git rev-parse --verify CANDIDATE^{commit} resolves the candidate to a
% commit AND looks the object up in this clone: a bare full object id is
% echoed by rev-parse even when absent, but the ^{commit} peel forces the
% object lookup (nonzero exit, empty stdout when missing). library(process)
% raises process_error/2 when the reaped child exits nonzero, so an
% unresolvable candidate is a clean failure, never an escape.
base_candidate_commit(Candidate, ObjectId) :-
    gate_root(Root),
    atomic_list_concat([Candidate, '^', '{commit}'], CommitSpec),
    catch(base_candidate_commit_(Root, CommitSpec, ObjectId), _, fail).

base_candidate_commit_(Root, CommitSpec, ObjectId) :-
    setup_call_cleanup(
        process_create(path(git),
                       ['rev-parse', '--verify', CommitSpec],
                       [stdout(pipe(Out)), stderr(null), cwd(Root)]),
        (   read_line_to_string(Out, Line),
            Line \== end_of_file,
            split_string(Line, " ", "", [First|_]),
            atom_string(ObjectId, First)
        ),
        close(Out)).

extract_unmerged_base(Path) :-
    gate_root(Root),
    atomic_list_concat([Root, '/prolog'], PrologDir),
    current_prolog_flag(pid, Pid),
    atomic_list_concat([PrologDir, '/design_gate_tmp_', Pid, '.pl'], Path),
    base_ref_candidates(Candidates),
    first_resolvable_candidate(Candidates, Candidate),
    atomic_list_concat([Candidate, ':prolog/rlm_plan_graph.pl'], ObjectSpec),
    catch((setup_call_cleanup(
               process_create(path(git),
                              ['cat-file', 'blob', ObjectSpec],
                              [stdout(pipe(Out)), stderr(null), cwd(Root)]),
               setup_call_cleanup(open(Path, write, Sink),
                                  copy_stream_data(Out, Sink),
                                  close(Sink)),
               close(Out)),
           size_file(Path, Size),
           Size > 10000),
          _, fail).

load_unmerged_base :-
    (   extract_unmerged_base(Path)
    ->  % The extracted module uses source-relative use_module/1
        % (rlm_async, rlm_plan, rlm_tool); place it inside prolog/ so those
        % resolve, load (importing its public surface), then remove the
        % transient copy.
        setup_call_cleanup(true,
                           use_module(Path),
                           catch(delete_file(Path), _, true))
    ;   base_ref_candidates(Candidates),
        format(user_error,
               "design-gate: rage/288 BASE module unavailable; adoption input missing~ndesign-gate: BASE candidates tried (pinned id is the authority): ~q~n",
               [Candidates]),
        halt(1)
    ).

/* ------------------------------------------------------------------ */
/* Gate harness                                                        */
/* ------------------------------------------------------------------ */

check(Id, Goal) :-
    assertz(check_defined(Id)),
    (   catch(Goal, Exception,
              (   report_exception(Id, Exception),
                  fail
              ))
    ->  format("  ok   ~w~n", [Id])
    ;   assertz(check_failure(Id, failed)),
        format("  FAIL ~w~n", [Id])
    ).

report_exception(Id, gate_fault(Detail)) :- !,
    format("  FAIL ~w (gate fault: ~w)~n", [Id, Detail]).
report_exception(Id, Exception) :-
    format("  FAIL ~w (exception: ~w)~n", [Id, Exception]).

% Self-contained check helpers: each creates fresh local variables per
% invocation so clause-level variable sharing between check goals is
% impossible (the failure mode that made earlier revisions of this gate
% compare each check against the previous check's binding).

spec_compiles(Source, Registry) :-
    compile_spec(Source, Registry, ok(_)).

spec_rejects(Source, Registry) :-
    compile_spec(Source, Registry, error(_)).

plan_graph_accepts(Source, Caps) :-
    plan_graph_parse(Source, ok(Parsed)),
    plan_graph_validate(Parsed, Caps, default, Outcome),
    Outcome = ok(_).

plan_graph_rejects(Source, Caps) :-
    plan_graph_parse(Source, ok(Parsed)),
    plan_graph_validate(Parsed, Caps, default, Outcome),
    Outcome = error(_).

d6_accepts(Source, Graph) :-
    d6_validate_graph(Source, Graph).

d6_rejects(Source) :-
    (   catch(d6_validate_graph(Source, _), gate_fault(_), fail)
    ->  fail
    ;   true
    ).

main :-
    format("design-gate: loading merged modules (IMPLEMENTED layer)~n"),
    load_merged_modules,

    format("design-gate: extracting + loading rage/288 BASE module (UNMERGED layer)~n"),
    load_unmerged_base,
    format("design-gate: running checks~n"),

    run_all_checks,
    (   check_failure(_, _)
    ->  findall(Id-Why, check_failure(Id, Why), Failures),
        length(Failures, N),
        format("design-gate: ~w CHECK(S) FAILED~n", [N]),
        forall(member(Id-Why, Failures),
               format("  failed: ~w (~w)~n", [Id, Why])),
        probe_mode_or_halt(1)
    ;   format("design-gate: ALL CHECKS PASSED~n"),
        probe_mode_or_halt(0)
    ).

% DESIGN_GATE_PROBE=1 keeps the process alive after main so the gate module
% can be imported for focused debugging; the canonical script run halts.
probe_mode_or_halt(Code) :-
    (   getenv('DESIGN_GATE_PROBE', _)
    ->  true
    ;   halt(Code)
    ).

:- initialization(main, main).

http_contract_checker(OkReq, status_700) :-
    \+ http_endpoint_args(_{service:s, request:OkReq,
                            responses:[_{scenario:valid_request, status:700}]}).
http_contract_checker(OkReq, class_6xx) :-
    \+ http_endpoint_args(_{service:s, request:OkReq,
                            responses:[_{scenario:valid_request,
                                        status:class('6xx')}]}).
http_contract_checker(OkReq, nonderivable_conflict) :-
    put_dict(idempotency, OkReq, none, NoIdempotencyReq),
    \+ http_endpoint_args(_{service:s, request:NoIdempotencyReq,
                            responses:[_{scenario:conflict, status:409}]}).
http_contract_checker(OkReq, body_without_schema) :-
    \+ catch(http_endpoint_args(_{service:s, request:OkReq,
                                  responses:[_{scenario:valid_request,
                                              status:201,
                                              body:_{type:json}}]}),
             _, fail).

http_contract_checks :-
    design_registry(Registry),
    http_endpoint_args_ok(OkReq),
    % Positive contract with an EMBEDDED path template: {id} occurs inside
    % "/users/{id}" (m4).
    check(http_path_param_ok,
          (   http_path_endpoint_args_ok(PathArgs),
              spec_compiles(spec([subject(service(user_api)),
                                  require(get_user,
                                          assertion(http_endpoint,
                                                    PathArgs))]),
                            Registry)
          )),
    check(http_reject_status_700, http_contract_checker(OkReq, status_700)),
    check(http_reject_class_6xx, http_contract_checker(OkReq, class_6xx)),
    check(http_reject_nonderivable_conflict,
          http_contract_checker(OkReq, nonderivable_conflict)),
    check(http_reject_body_without_schema,
          http_contract_checker(OkReq, body_without_schema)).

run_all_checks :-
    forall(design_gate_group(Group),
           (   format("GROUP ~w~n", [Group]),
               catch(call(Group), Exception,
                     (   assertz(check_failure(Group, exception)),
                         term_string(Exception, S),
                         format("  FAIL ~w (group exception: ~w)~n", [Group, S])
                     ))
           )).

design_gate_group(base_adoption_checks).
design_gate_group(spec_grammar_checks).
design_gate_group(plan_base_checks).
design_gate_group(plan_native_checks).
design_gate_group(d6_delta_checks).
design_gate_group(dataflow_checks).
design_gate_group(capability_safety_checks).
design_gate_group(replan_safety_checks).
design_gate_group(tdd_evidence_checks).
design_gate_group(http_contract_checks).
design_gate_group(edit_action_checks).
design_gate_group(durability_checks).
design_gate_group(state_readability_checks).
design_gate_group(kb_dag_checks).

/* ------------------------------------------------------------------ */
/* Design assertion registry (trusted host providers)                  */
/* ------------------------------------------------------------------ */

design_registry([
    assertion_provider(record_count, 1, design_gate:record_count_args,
                       design_gate:count_evaluator, none,
                       _{verifier:_{id:record_count, version:1},
                         collector:_{id:none, version:0},
                         evidence_policy:default,
                         latency:pure,
                         description:"dataset row count"}),
    assertion_provider(file_language, 1, design_gate:file_language_args,
                       design_gate:language_evaluator, none,
                       _{verifier:_{id:file_language, version:1},
                         collector:_{id:none, version:0},
                         evidence_policy:default,
                         latency:pure,
                         description:"file language requirement"}),
    assertion_provider(symbol_exists, 1, design_gate:symbol_exists_args,
                       design_gate:symbol_evaluator, none,
                       _{verifier:_{id:symbol_exists, version:1},
                         collector:_{id:none, version:0},
                         evidence_policy:default,
                         latency:pure,
                         description:"named symbol existence"}),
    assertion_provider(symbol_arity, 1, design_gate:symbol_arity_args,
                       design_gate:symbol_evaluator, none,
                       _{verifier:_{id:symbol_arity, version:1},
                         collector:_{id:none, version:0},
                         evidence_policy:default,
                         latency:pure,
                         description:"symbol arity requirement"}),
    assertion_provider(build_ok, 1, design_gate:build_ok_args,
                       design_gate:build_evaluator, none,
                       _{verifier:_{id:build_ok, version:1},
                         collector:_{id:none, version:0},
                         evidence_policy:default,
                         latency:blocking,
                         description:"build requirement"}),
    assertion_provider(test_passes, 1, design_gate:test_passes_args,
                       design_gate:test_evaluator, none,
                       _{verifier:_{id:test_passes, version:1},
                         collector:_{id:none, version:0},
                         evidence_policy:default,
                         latency:blocking,
                         description:"test suite requirement"}),
    assertion_provider(test_exists, 1, design_gate:test_exists_args,
                       design_gate:test_evaluator, none,
                       _{verifier:_{id:test_exists, version:1},
                         collector:_{id:none, version:0},
                         evidence_policy:default,
                         latency:pure,
                         description:"test existence requirement"}),
    assertion_provider(behavior_tested, 1, design_gate:behavior_tested_args,
                       design_gate:test_evaluator, none,
                       _{verifier:_{id:behavior_tested, version:1},
                         collector:_{id:none, version:0},
                         evidence_policy:default,
                         latency:pure,
                         description:"behavior coverage requirement"}),
    assertion_provider(tdd_evidence, 1, design_gate:tdd_evidence_args,
                       design_gate:tdd_evidence_evaluator, none,
                       _{verifier:_{id:tdd_evidence, version:1},
                         collector:_{id:none, version:0},
                         evidence_policy:default,
                         latency:blocking,
                         description:"RED/GREEN evidence pair"}),
    assertion_provider(public_api_compatible, 1, design_gate:public_api_args,
                       design_gate:api_evaluator, none,
                       _{verifier:_{id:public_api_compatible, version:1},
                         collector:_{id:none, version:0},
                         evidence_policy:default,
                         latency:pure,
                         description:"public API compatibility"}),
    assertion_provider(http_endpoint, 1, design_gate:http_endpoint_args,
                       design_gate:http_evaluator, none,
                       _{verifier:_{id:http_endpoint, version:1},
                         collector:_{id:none, version:0},
                         evidence_policy:default,
                         latency:blocking,
                         description:"typed HTTP endpoint contract"})
]).

% Trusted host configuration: required OBSERVATION capabilities per
% assertion kind (a provider-pack side table; SPEC compilation never adds
% these to the environment capability set).
observer_required_capabilities(http_endpoint, [network(observation)]).
observer_required_capabilities(build_ok, [process(observation),
                                          filesystem(observation)]).
observer_required_capabilities(test_passes, [process(observation),
                                             filesystem(observation)]).
observer_required_capabilities(test_exists, [filesystem(observation)]).
observer_required_capabilities(behavior_tested, [filesystem(observation)]).
observer_required_capabilities(tdd_evidence, [process(observation),
                                              filesystem(observation)]).
observer_required_capabilities(file_language, [filesystem(observation)]).
observer_required_capabilities(symbol_exists, [filesystem(observation)]).
observer_required_capabilities(symbol_arity, [filesystem(observation)]).
observer_required_capabilities(record_count, [filesystem(observation)]).
observer_required_capabilities(public_api_compatible,
                               [filesystem(observation)]).

% Trusted host configuration (S8): which assertion kinds require a plan
% establishing step. Model data cannot change this mapping.
requirement_establishment(tdd_evidence, plan_established).
requirement_establishment(_, none).

/* ------------------------------------------------------------------ */
/* BASE adoption: pinned ref resolution (canonical CI resolvability)    */
/* ------------------------------------------------------------------ */

base_adoption_checks :-
    check(base_ref_resolvable, base_ref_resolves_to_pinned_id).

base_ref_resolves_to_pinned_id :-
    base_pinned_commit(Pinned),
    base_ref_candidates(Candidates),
    first_resolvable_candidate(Candidates, Candidate),
    base_candidate_commit(Candidate, ObjectId),
    ObjectId == Pinned.

/* ------------------------------------------------------------------ */
/* SPEC grammar checks (through merged rlm_spec_lang/rlm_spec)         */
/* ------------------------------------------------------------------ */

compile_spec(Source, Registry, Outcome) :-
    spec_source_compile(Source, Registry, [], Outcome).

spec_grammar_checks :-
    design_registry(Registry),

    % Dataset example from docs/spec-mode.md parses through the real parser.
    check(spec_compile_dataset_ok,
          spec_compiles(spec([subject(dataset(people)),
                              require(enough_people,
                                      assertion(record_count,
                                                _{dataset:people, minimum:3}))]),
                        Registry)),

    % Domain example: language + symbol + build + test requirements.
    check(spec_compile_domain_ok,
          spec_compiles(spec(
              [ subject(update(symbol(foo))),
                require(foo_module_language,
                        assertion(file_language,
                                  _{path:'src/foo.pl', language:prolog})),
                require(foo_exists,
                        assertion(symbol_exists,
                                  _{symbol:_{name:foo, kind:function,
                                             arity:2},
                                    occurrence:definition})),
                require(foo_arity,
                        assertion(symbol_arity,
                                  _{symbol:_{name:foo, kind:function},
                                    arity:2})),
                require(build_green,
                        assertion(build_ok,
                                  _{target:all,
                                    toolchain:_{kind:swi,
                                                version_constraint:_{}},
                                    exit_status:0})),
                require(suite_green, assertion(test_passes, _{scope:all})),
                invariant(preserve_public_api),
                invariant(forbidden_effect(delete(file('src/foo.pl')))),
                provenance(_{author:"design-gate"})
              ]),
              Registry)),

    % TDD example: acceptance is the RED/GREEN pair, not final state.
    check(spec_compile_tdd_ok,
          spec_compiles(spec([subject(update(symbol(foo))),
                             require(foo_behavior_x,
                                     assertion(tdd_evidence,
                                               _{requirement:foo_behavior_x,
                                                 test:_{suite:unit,
                                                        id:foo_x_test},
                                                 pre_revision:head,
                                                 post_revision:working}))]),
                        Registry)),

    % HTTP example: one endpoint, 201/400/401/409 behaviors.
    http_endpoint_args_ok(HttpArgs),
    check(spec_compile_http_ok,
          spec_compiles(spec([subject(service(user_api)),
                              require(create_user,
                                      assertion(http_endpoint, HttpArgs))]),
                        Registry)),

    % BLOCKER counterexamples from the failed PR #290 design are rejected
    % by the real merged parser.
    check(spec_reject_spec2,
          spec_rejects(spec(updateFoo,
                            [subject(update(symbol(foo))),
                             require(x,
                                     assertion(symbol_exists,
                                               _{symbol:_{name:foo,
                                                          kind:function}}))]),
                       Registry)),

    check(spec_reject_unknown_form,
          spec_rejects(spec([subject(s),
                             require(x,
                                     assertion(symbol_exists,
                                               _{symbol:_{name:foo,
                                                          kind:function}})),
                             artifact(t, test_report)]),
                       Registry)),

    check(spec_reject_wrong_arity,
          spec_rejects(spec([subject(s), require(x)]),
                       Registry)),

    check(spec_reject_duplicate_ids,
          spec_rejects(spec([subject(s),
                             require(x,
                                     assertion(symbol_exists,
                                               _{symbol:_{name:foo,
                                                          kind:function}})),
                             require(x,
                                     assertion(symbol_exists,
                                               _{symbol:_{name:bar,
                                                          kind:function}}))]),
                       Registry)),

    check(spec_reject_executable_data,
          spec_rejects(spec([subject(s),
                             require(x,
                                     assertion(symbol_exists,
                                               _{symbol:_{name:foo,
                                                          kind:function},
                                                          when:call(system(rm))}))]),
                       Registry)),

    check(spec_reject_unknown_kind,
          spec_rejects(spec([subject(s),
                             require(x, assertion(frobnicate, _{}))]),
                       Registry)).

http_endpoint_args_ok(_{service:user_api,
                        request:_{method:post,
                                  path:"/users",
                                  content_type:"application/json",
                                  accept:["application/json"],
                                  auth:_{scheme:bearer},
                                  idempotency:required,
                                  body:_{type:json,
                                         schema:_{type:object,
                                                  properties:_{name:_{type:string},
                                                               email:_{type:string}},
                                                  required:[name, email]}},
                                  inputs:[input_decl{name:user_payload,
                                                     type:json,
                                                     required:true}]},
                        responses:[
                            _{scenario:valid_request, status:201,
                              headers:[header_contract{name:location,
                                                       value:"/users/{id}"}],
                              body:_{type:json,
                                     schema:_{type:object,
                                              properties:_{id:_{type:integer}},
                                              required:[id]}}},
                            _{scenario:invalid_body, status:400,
                              body:_{type:json,
                                     schema:_{type:object,
                                              properties:_{error:_{type:string}}}}},
                            _{scenario:unauthenticated, status:401},
                            _{scenario:conflict, status:409}
                        ]}).

% GET endpoint with an embedded {id} template in the path and a
% missing_resource response (derivable: path_params non-empty).
http_path_endpoint_args_ok(_{service:user_api,
                             request:_{method:get,
                                      path:"/users/{id}",
                                      path_params:_{id:integer},
                                      accept:["application/json"],
                                      auth:_{scheme:bearer}},
                             responses:[
                                 _{scenario:valid_request, status:200,
                                   body:_{type:json,
                                          schema:_{type:object,
                                                   properties:_{id:_{type:integer},
                                                                name:_{type:string}},
                                                   required:[id, name]}}},
                                 _{scenario:missing_resource, status:404}
                             ]}).

/* ------------------------------------------------------------------ */
/* PLAN BASE checks (through the adopted rage/288 module)              */
/* ------------------------------------------------------------------ */

base_all_caps([tool(index), tool(locate), tool(read), tool(search),
               tool(diff), tool(edit), tool(create), tool(delete),
               tool(run), tool(sync_remote), tool(validate),
               tool(spawn_agent)]).

plan_base_checks :-
    check(plan_base_ok,
          (   base_graph_plan_graph(Source),
              plan_graph_accepts(Source,
                                 [tool(index), tool(locate), tool(read)])
          )),

    check(plan_reject_unknown_op,
          plan_graph_rejects(plan_graph(
                                 steps([step(a, index,
                                             index(scope(all)), idx),
                                        step(b, frobnicate,
                                             frobnicate(x), r)]),
                                 depends_on([depends_on(b, [a])])),
                             [tool(index)])),

    % "delete with four args" from the adversarial review must fail.
    check(plan_reject_bad_arity,
          plan_graph_rejects(_{steps:[_{id:d1, op:delete,
                                       args:_{path:'a.py', extra:1,
                                             more:2, again:3},
                                       bind:b}]},
                             [tool(delete)])),

    check(plan_reject_bad_ref,
          plan_graph_rejects(_{steps:[_{id:l1, op:locate,
                                       args:_{symbol:_{name:foo}},
                                       bind:loc}]},
                             [tool(locate)])),

    check(capability_denied_sync_remote,
          plan_graph_rejects(plan_graph(
                                 steps([step(s, sync_remote,
                                             sync_remote(op(push)),
                                             ok1)])),
                             [tool(index)])),

    check(delegate_widening_denied,
          plan_graph_rejects(plan_graph(
                                 steps([step(d, delegate,
                                             delegate(task(sub),
                                                      caps([tool(edit)])),
                                             res)])),
                             [tool(spawn_agent), tool(index)])),

    check(unknown_capability_rejected,
          plan_graph_rejects(_{steps:[_{id:d1, op:delegate,
                                       args:_{task:sub,
                                             caps:["model(gpt)"]},
                                       bind:res}]},
                             [tool(spawn_agent)])).

base_graph_plan_graph(plan_graph(
    steps([step(s1, index, index(scope(all)), idx),
           step(s2, locate,
                locate(symbol_ref(symbol_ref{name:foo, kind:function,
                                             occurrence:definition})),
                loc),
           step(s3, read, read(path('src/foo.py')), body)]),
    depends_on([depends_on(s2, [s1]),
                depends_on(s3, [s2])]))).

/* ------------------------------------------------------------------ */
/* D6-11 plan-native deterministic mutations                            */
/*                                                                      */
/* D6-11: the closed set sync_remote/1, run/1, index/1, delete/1        */
/* executes at the plan layer through the canonical boundary (schema -> */
/* capability -> authority -> durable effect admission -> dispatch ->   */
/* observe), exactly like a tool/3 step; excluded from expert mapping   */
/* and from the future expert registry; edit/2 and create/2 remain      */
/* write-expert-owned per §8.3.                                         */
/* ------------------------------------------------------------------ */

% Gate-local trusted record of the D6-11 closed set. Membership is pinned
% against plan_graph_op/1 from the loaded BASE module, so the native set
% can never escape the closed project-op vocabulary.
plan_native_op(sync_remote/1).
plan_native_op(run/1).
plan_native_op(index/1).
plan_native_op(delete/1).

% BASE-accepted arg shapes (BASE arg_valid/2; D6-4 argv is a delta).
plan_native_base_args(sync_remote, sync_remote(op(push))).
plan_native_base_args(run, run(command(sync))).
plan_native_base_args(index, index(scope(all))).
plan_native_base_args(delete, delete(path('a.py'))).

% D6-4-shaped args for the gate-local D6 desugar checker.
plan_native_d6_args(sync_remote, sync_remote(op(push))).
plan_native_d6_args(run, run(command(argv([sync])))).
plan_native_d6_args(index, index(scope(all))).
plan_native_d6_args(delete, delete(path('a.py'))).

plan_native_single_step_graph(Op, Args, plan_graph(
    steps([step(native_step, Op, Args, native_bind)]),
    depends_on([]))).

plan_native_checks :-
    % D6-11 closed set: inside the BASE vocabulary, never covering the
    % write-expert-owned model-payload mutations (§8.3).
    check(plan_native_set_closed_in_base_vocabulary,
          (   forall(plan_native_op(NativeOp), plan_graph_op(NativeOp)),
              \+ plan_native_op(edit/2),
              \+ plan_native_op(create/2),
              plan_graph_op(edit/2),
              plan_graph_op(create/2)
          )),

    % Ungranted capability fails closed at the plan layer for every
    % plan-native op: validation error before any dispatch.
    check(plan_native_capability_denied_fail_closed,
          forall(plan_native_op(Op/_),
                 (   plan_native_base_args(Op, Args),
                     plan_native_single_step_graph(Op, Args, Source),
                     plan_graph_rejects(Source, [tool(other)])
                 ))),

    % The exact per-op capability admits the native step: the required
    % capability term is exactly tool(Op) — the canonical plan-layer
    % capability, not an expert-contract capability.
    check(plan_native_capability_exact_admission,
          forall(plan_native_op(Op/_),
                 (   plan_native_base_args(Op, Args),
                     plan_native_single_step_graph(Op, Args, Source),
                     plan_graph_accepts(Source, [tool(Op)])
                 ))),

    % Each native op desugars mechanically to the canonical tool/3 step
    % plan([tool(Op, literal(Args), Bind), final(var(Bind))]) — the
    % desugared form the plan layer executes (D6-11 "exactly like a
    % tool/3 step").
    check(plan_native_desugar_is_canonical_tool_step,
          forall(plan_native_op(Op/_),
                 (   plan_native_d6_args(Op, Args),
                     plan_native_single_step_graph(Op, Args, Source),
                     d6_accepts(Source, Graph),
                     d6_desugar(native_step, Op, Graph, _{}, Plan),
                     Plan == plan([tool(Op, literal(Args), native_bind),
                                   final(var(native_bind))])
                 ))).

/* ------------------------------------------------------------------ */
/* D6 delta checks (gate-local normative checkers; S5 implements them) */
/* ------------------------------------------------------------------ */

dataflow_graph_plan_graph(plan_graph(
    steps([step(find_foo, locate,
                locate(symbol_ref(symbol_ref{name:foo, kind:function,
                                             arity:2,
                                             occurrence:definition})),
                foo_loc),
           step(read_foo, read,
                read(source(span(expr(field(input(foo_loc), span))))),
                foo_src),
           step(patch_foo, edit,
                edit(target(ref(symbol_ref(symbol_ref{name:foo,
                                                      kind:function,
                                                      arity:2}))),
                     content(expr(input(foo_src)))),
                foo_edit),
           step(check_spec, validate,
                validate(spec(fingerprint('spec-sha256-design-gate'))),
                verified)]),
    depends_on([depends_on(read_foo,   [find_foo]),
                depends_on(patch_foo,  [read_foo]),
                depends_on(check_spec, [patch_foo])]),
    obligations([obligation(step:patch_foo, satisfies:foo_behavior_x)]))).

dataflow_env_inputs(gate_inputs{'user_payload':_{'name':"n", 'email':"e"}}).

d6_delta_checks :-
    check(d6_dataflow_graph_valid,
          d6_obligations_of(dataflow_graph_plan_graph,
                            [obl{step:patch_foo,
                                 satisfies:foo_behavior_x}])),

    % An input reference outside the dependency closure is dangling.
    check(d6_dangling_rejected,
          d6_rejects(plan_graph(
              steps([step(find_foo, locate,
                          locate(symbol_ref(symbol_ref{name:foo,
                                                       kind:function,
                                                       occurrence:definition})),
                      foo_loc),
                     step(read_foo, read,
                          read(source(span(expr(input(foo_loc))))),
                          foo_src)])))),

    % Only the closed merged-expression grammar is admitted.
    check(d6_reject_unknown_expr,
          d6_rejects(plan_graph(
              steps([step(r, read,
                          read(source(span(expr(call(system(rm)))))),
                          body)])))),

    % Commands are argv lists, never shell strings.
    check(d6_reject_shell_string,
          d6_rejects(plan_graph(
              steps([step(r, run, run(command('rm -rf /')), done)])))),

    % Obligations must reference declared steps.
    check(d6_reject_bad_obligation,
          d6_rejects(plan_graph(
              steps([step(e, edit,
                          edit(target(span(source_span{file:'f.pl',
                                                       start_byte:0,
                                                       end_byte:3})),
                               content(literal(new))),
                          done)]),
              depends_on([]),
              obligations([obligation(step:ghost, satisfies:x)])))),

    % D6-10: symbol_ref.kind is enforced as the closed 13-atom set at
    % reconciliation (the BASE decoder accepts any non-empty atom kind —
    % declared divergence, so this pin guards the D6 layer).
    check(symbol_kind_closed, symbol_kind_closed_enforced),

    % D6-9: diff sides gain revision(revision_ref) at the D6 layer (BASE
    % side_valid/1 has no revision clause — declared divergence owned by
    % S3 resolution): valid revision sides validate, invalid ones are
    % rejected, and the unchanged BASE validator still rejects them.
    check(diff_revision_side, diff_revision_side_delta).

symbol_kind_closed_enforced :-
    d6_accepts(plan_graph(
        steps([step(l, locate,
                    locate(symbol_ref(symbol_ref{name:foo, kind:function,
                                                 occurrence:definition})),
                    loc)])),
        _),
    d6_rejects(plan_graph(
        steps([step(l, locate,
                    locate(symbol_ref(symbol_ref{name:foo, kind:frobnicate,
                                                 occurrence:definition})),
                    loc)]))).

diff_revision_side_delta :-
    d6_accepts(plan_graph(
        steps([step(d, diff,
                    diff(revision(head), revision(working)), df1)])),
        _),
    d6_accepts(plan_graph(
        steps([step(d, diff,
                    diff(revision(committed('abc123')),
                         revision(branch('feature/x'))), df2)])),
        _),
    d6_accepts(plan_graph(
        steps([step(d, diff,
                    diff(revision(remote('origin', 'main')), revision(head)),
                    df3)])),
        _),
    d6_rejects(plan_graph(
        steps([step(d, diff,
                    diff(revision(bogus), revision(head)), df4)]))),
    \+ plan_graph_accepts(plan_graph(
        steps([step(d, diff,
                    diff(revision(head), revision(working)), df5)])),
        [tool(diff)]).

d6_obligations_of(Source, Obligations) :-
    call(Source, Input),
    d6_validate_graph(Input, Graph),
    get_dict(obligations, Graph, Actual),
    Actual == Obligations.

/* ------------------------------------------------------------------ */
/* Typed dataflow proof: step A output consumed by step B              */
/* ------------------------------------------------------------------ */

dataflow_checks :-
    check(d6_dataflow_round_trip,
          dataflow_round_trip),
    check(spec_input_env_dataflow,
          spec_input_env_dataflow_run).

% Self-contained so every variable is fresh per invocation (clause-level
% sharing of the earlier inline form made this check compare bindings from
% the previous invocation).
dataflow_round_trip :-
    dataflow_graph_plan_graph(Input),
    dataflow_env_inputs(EnvInputs),
    d6_validate_graph(Input, EnvInputs, Graph),
    d6_resolve_step_args(find_foo, Graph, empty_inputs{}, LocateArgs),
    % 1. Execute the locate step through the MERGED rlm_plan ABI.
    d6_desugar(find_foo, locate, Graph, _{}, PlanLocate),
    plan_validate(PlanLocate, [tool(locate)], default, ok(VLocate)),
    plan_execute(VLocate,
                 [tools([tool(locate, design_gate:locate_handler)])],
                 empty_inputs{}, ok(LocateResult)),
    get_dict(vars, LocateResult, Vars),
    get_dict(foo_loc, Vars, FooBinding),
    get_dict(span, FooBinding, LocSpan),
    LocSpan == source_span{file:'src/foo.pl', start_byte:10, end_byte:20},
    % 2. Resolve the read step's expr leaves against the EXACT bound output
    %    of the locate step.
    put_dict(foo_loc, empty_inputs{}, FooBinding, Binding1),
    d6_resolve_step_args(read_foo, Graph, Binding1, ReadArgs),
    ReadArgs == read(source(span(LocSpan))),
    % Resolved values are re-validated against the strict post-admission
    % shape, not merely compared for equality.
    d6_args_shape_resolved(locate, LocateArgs),
    d6_args_shape_resolved(read, ReadArgs),
    % 3. Desugar + execute the read step; the handler only succeeds when it
    %    receives exactly the locate span.
    d6_desugar_with_args(read, ReadArgs, foo_src, PlanRead),
    plan_validate(PlanRead, [tool(read)], default, ok(VRead)),
    plan_execute(VRead,
                 [tools([tool(read, design_gate:read_handler)])],
                 empty_inputs{}, ok(ReadResult)),
    get_dict(vars, ReadResult, Vars2),
    get_dict(foo_src, Vars2, "function foo(a, b) { ... }"),
    % 4. The resolved edit binds the generated content for a downstream
    %    write expert (durable-binding shape).
    put_dict(foo_src, Binding1, "function foo(a, b) { ... }", Binding2),
    d6_resolve_step_args(patch_foo, Graph, Binding2, EditArgs),
    EditArgs = edit(target(ref(symbol_ref(EditRef))),
                    content(EditContent)),
    get_dict(name, EditRef, foo),
    EditContent == "function foo(a, b) { ... }",
    d6_args_shape_resolved(edit, EditArgs).

locate_handler(locate(symbol_ref(Ref)),
               symbol_binding{span:Span,
                              provenance:gate_index{source:design_gate}}) :-
    get_dict(name, Ref, foo),
    Span = source_span{file:'src/foo.pl', start_byte:10, end_byte:20}.

read_handler(read(source(span(Span))), "function foo(a, b) { ... }") :-
    Span == source_span{file:'src/foo.pl', start_byte:10, end_byte:20}.

% §3.3/§11.5: the canonical way a plan step consumes a SPEC-declared
% input_decl — expr(input(<spec_input>)) resolved from environment inputs.
spec_input_graph(plan_graph(
    steps([step(store_payload, create,
                create(path('out/payload.txt'),
                       content(expr(input(user_payload)))),
                payload)]))).

% Positive round trip: the graph validates when user_payload is present in
% the environment inputs and the resolved create content IS the bound
% environment value. Negative: with the environment missing the input the
% same graph dangles at validation (no step-reference rescue exists), and
% the compat layer faults missing_spec_input regardless of the step
% reference — the inverted escape hatch is removed (§11 item 7).
spec_input_env_dataflow_run :-
    dataflow_env_inputs(EnvInputs),
    spec_input_graph(Input),
    d6_validate_graph(Input, EnvInputs, Graph),
    d6_resolve_step_args(store_payload, Graph, EnvInputs, Resolved),
    Resolved = create(path('out/payload.txt'), content(Payload)),
    get_dict(name, Payload, "n"),
    \+ d6_validate_graph(Input, empty_inputs{}, _),
    frozen_design_spec(Frozen),
    d6_parse_graph(Input, Decoded),
    d6_compat_checks(Decoded, Frozen,
                     plan_environment{capabilities:[], inputs:gate_inputs{}},
                     Faults),
    member(missing_spec_input(user_payload), Faults),
    member(dangling_input(store_payload, user_payload), Faults).

/* ------------------------------------------------------------------ */
/* Capability safety: SPEC grants nothing                              */
/* ------------------------------------------------------------------ */

capability_safety_checks :-
    design_registry(Registry),
    http_endpoint_args_ok(HttpArgs),
    check(capability_unchanged,
          (   compile_spec(spec([subject(service(user_api)),
                                 require(create_user,
                                         assertion(http_endpoint, HttpArgs))]),
                           Registry,
                           ok(Frozen)),
               % The compiled outcome is the actual surface compilation
               % produces: no term inside it is capability-shaped per the
               % closed merged capability model, so compiling a spec that
               % requires network work cannot grant or reference a grant.
               \+ ( frozen_subterm(Frozen, Term),
                    rlm_tool:capability_shape(Term) ),
               % The required observation capability is trusted host
               % side-table data checked at observation time; compilation
               % does not add it to (or remove it from) the environment set.
               observer_required_capabilities(http_endpoint,
                                              [network(observation)]),
               base_all_caps(EnvCaps),
               \+ memberchk(network(observation), EnvCaps)
           )),

    % The closed merged metadata schema carries no capability field: a
    % registry provider whose metadata attempts one is rejected by the real
    % rlm_assertion normalization. The clean twin proves the rejection is
    % attributable to the capability field alone.
    check(metadata_capability_rejected,
          (   metadata_registry([capability-[tool(create)]], CapRegistry),
              assertion_registry_validate(CapRegistry, error(CapError)),
              get_dict(detail, CapError, CapDetail),
              gate_term_contains(CapDetail, capability),
              metadata_registry([], CleanRegistry),
              assertion_registry_validate(CleanRegistry, ok(_))
          )),

    % Real refusal path: the trusted capability-gated observer derives its
    % requirement from the provider-pack side table and the environment
    % capability set carried in the observation sources, and refuses by
    % returning a conservative indeterminate payload. Driven through the
    % real spec_observe_execute/5 collect ABI and the real spec_verify/4
    % reconciliation: the observation is indeterminate(policy_denied),
    % never passed, and the report is rejected. The granted twin proves the
    % refusal branch is computed, not pre-set.
    check(host_observation_refusal, host_observation_refusal_run),

    % The provider-pack side table is complete: every registry kind
    % declares its required observation capabilities, every required
    % capability is a valid merged capability shape, and every one is
    % observation-scoped (observation capability is never write authority).
    check(observer_side_table_complete, observer_side_table_complete_run).

frozen_http_spec(Frozen) :-
    design_registry(Registry),
    frozen_http_spec_registry(Registry, Frozen).

frozen_http_spec_registry(Registry, Frozen) :-
    http_endpoint_args_ok(HttpArgs),
    compile_spec(spec([subject(service(user_api)),
                       require(create_user,
                               assertion(http_endpoint, HttpArgs))]),
                 Registry,
                 ok(Frozen)).

host_observation_refusal_run :-
    observe_registry(ObserveRegistry),
    frozen_http_spec_registry(ObserveRegistry, Frozen),
    spec_observe_execute(Frozen,
                         observation_sources{environment_capabilities:
                                             [network(observation)]},
                         ObserveRegistry,
                         [],
                         ok(Granted)),
    member(GrantedObs, Granted),
    get_dict(status, GrantedObs, passed),
    spec_verify(Frozen, Granted, ObserveRegistry, ok(GrantedReport)),
    get_dict(status, GrantedReport, passed),
    spec_observe_execute(Frozen,
                         observation_sources{environment_capabilities:[]},
                         ObserveRegistry,
                         [],
                         ok(Denied)),
    member(DeniedObs, Denied),
    get_dict(status, DeniedObs, indeterminate(policy_denied)),
    get_dict(trust_class, DeniedObs, unresolved),
    get_dict(source_class, DeniedObs, observer_control),
    spec_verify(Frozen, Denied, ObserveRegistry, ok(DeniedReport)),
    get_dict(status, DeniedReport, rejected).

% Trusted gate observer (collector ABI): required observation capabilities
% come from the side table, the environment capability set from the
% observation sources. Refusal is computed here — never pre-set in a payload.
http_capability_observer(Requirement, Sources, _, Raw) :-
    get_dict(assertion, Requirement, RequirementAssertion),
    get_dict(kind, RequirementAssertion, Kind),
    observer_required_capabilities(Kind, Required),
    get_dict(environment_capabilities, Sources, EnvCaps),
    (   forall(member(Cap, Required), memberchk(Cap, EnvCaps))
    ->  Raw = _{status:passed,
                value:http_observation{scenario:valid_request, status:200},
                evidence_refs:[evidence:http_probe],
                source_class:external_observation,
                trust_class:observed,
                state_ref:revision(working)}
    ;   findall(Missing,
                (   member(Missing, Required),
                    \+ memberchk(Missing, EnvCaps)
                ),
                MissingCaps),
        Raw = _{status:indeterminate(policy_denied),
                value:none,
                evidence_refs:[],
                source_class:observer_control,
                trust_class:unresolved,
                provenance:_{reason:capability_absent(Kind),
                             missing:MissingCaps}}
    ).

% Observe-side registry: trusted collector/observer pair for the
% capability-gated HTTP observer (merged ABI requires collector and
% observer to be jointly none or jointly present).
observe_registry([assertion_provider(http_endpoint, 1,
                                     design_gate:http_endpoint_args,
                                     design_gate:http_evaluator,
                                     design_gate:http_capability_observer,
                                     _{verifier:_{id:http_endpoint, version:1},
                                       collector:_{id:http_endpoint, version:1},
                                       evidence_policy:default,
                                       latency:pure,
                                       description:"capability-gated HTTP observer"})]).

% Registry-builder for metadata probes; Extra pairs are merged into the
% provider metadata so a probe can attempt a capability field.
metadata_registry(Extra, [assertion_provider(record_count, 1,
                                              design_gate:record_count_args,
                                              design_gate:count_evaluator,
                                              none,
                                              Metadata)]) :-
    append([verifier-_{id:cap_probe, version:1},
            collector-_{id:none, version:0},
            evidence_policy-default,
            latency-pure,
            description:"capability probe"], Extra, Pairs),
    dict_create(Metadata, metadata_probe, Pairs).

gate_term_contains(Term, Needle) :-
    subsumes_term(Needle, Term), !.
gate_term_contains(Term, Needle) :-
    is_dict(Term), !,
    dict_pairs(Term, _, Pairs),
    member(_-V, Pairs),
    gate_term_contains(V, Needle).
gate_term_contains(Term, Needle) :-
    is_list(Term), !,
    member(Element, Term),
    gate_term_contains(Element, Needle).
gate_term_contains(Term, Needle) :-
    compound(Term), !,
    Term =.. [_|Args],
    member(Arg, Args),
    gate_term_contains(Arg, Needle).

frozen_subterm(Term, Term).
frozen_subterm(Term, Sub) :-
    is_dict(Term), !,
    dict_pairs(Term, _, Pairs),
    member(_-V, Pairs),
    frozen_subterm(V, Sub).
frozen_subterm(Term, Sub) :-
    is_list(Term), !,
    member(Element, Term),
    frozen_subterm(Element, Sub).
frozen_subterm(Term, Sub) :-
    compound(Term), !,
    Term =.. [_|Args],
    member(Arg, Args),
    frozen_subterm(Arg, Sub).

observer_side_table_complete_run :-
    design_registry(Registry),
    forall(member(Provider, Registry),
           (   Provider = assertion_provider(Kind, _, _, _, _, _),
               observer_required_capabilities(Kind, Required),
               Required \== [],
               forall(member(Cap, Required),
                      (   rlm_tool:capability_shape(Cap),
                          Cap =.. [Scope, Name],
                          Name == observation,
                          memberchk(Scope, [network, filesystem, process])
                      ))
           )).

/* ------------------------------------------------------------------ */
/* PLAN → SPEC compatibility + replan safety (gate-local checkers; S8) */
/* ------------------------------------------------------------------ */

frozen_design_spec(Frozen) :-
    design_registry(Registry),
    http_endpoint_args_ok(HttpArgs),
    compile_spec(spec([subject(update(symbol(foo))),
                       require(foo_behavior_x,
                               assertion(tdd_evidence,
                                         _{requirement:foo_behavior_x,
                                           test:_{suite:unit, id:foo_x_test},
                                           pre_revision:head,
                                           post_revision:working})),
                       require(build_green,
                               assertion(build_ok,
                                         _{target:all,
                                           toolchain:_{kind:swi,
                                                       version_constraint:_{}},
                                           exit_status:0})),
                       require(create_user,
                               assertion(http_endpoint, HttpArgs)),
                       invariant(preserve_public_api),
                       invariant(forbidden_effect(delete(file('src/foo.pl'))))
                     ]),
                 Registry,
                 ok(Frozen)).

frozen_tdd_spec(Frozen) :-
    design_registry(Registry),
    compile_spec(spec([subject(update(symbol(foo))),
                       require(foo_behavior_x,
                               assertion(tdd_evidence,
                                         _{requirement:foo_behavior_x,
                                           test:_{suite:unit, id:foo_x_test},
                                           pre_revision:head,
                                           post_revision:working}))]),
                 Registry,
                 ok(Frozen)).

replan_safety_checks :-
    frozen_design_spec(Frozen),
    get_dict(ref, Frozen, FrozenRef),
    get_dict(fingerprint, FrozenRef, Fingerprint),
    dataflow_graph_plan_graph(Input0),
    set_validate_fingerprint(Input0, Fingerprint, Input),
    dataflow_env_inputs(EnvInputs),

    % The obligation-preserving graph is compatible with the frozen spec.
    check(replan_preserve_ok,
          (   d6_validate_graph(Input, Graph),
              plan_validate_against_spec_gate(Graph, Frozen,
                                              plan_environment{
                                                  capabilities:[],
                                                  inputs:EnvInputs},
                                              ok(_))
          )),

    % A patch that removes the sole obligation-establishing step is rejected
    % even though the validate step remains: validate verifies, it does not
    % establish.
    check(replan_drop_rejected,
          (   d6_validate_graph(Input, Graph),
              d6_apply_patch_full_chain(Graph,
                                        plan_patch{op:remove,
                                                   step:step(patch_foo,
                                                             edit, _, _),
                                                   edges:[],
                                                   obligations:[],
                                                   reason:"simplify",
                                                   provenance:model_claim},
                                        Frozen,
                                        plan_environment{capabilities:[],
                                                         inputs:EnvInputs},
                                        error(Dropped)),
              get_dict(detail, Dropped, DroppedFaults),
              member(dropped_obligation(foo_behavior_x), DroppedFaults)
          )),

    % Permanent negative check for the review's mutation graph: a no-op run
    % step wired to the validate step cannot satisfy a tdd_evidence
    % obligation, and a disconnected establishing step cannot either
    % (§9/§11.2: establishing ops for code-change evidence are edit|create
    % AND the step must be causally required by a validate step of the
    % bound spec).
    check(obligation_causal_link, obligation_causal_link_rejected),

    % §11.1: patch application re-runs the full chain (parse + graph
    % validation + compat, including dangling-input re-check) on the
    % patched graph — a patch that leaves the graph structurally invalid
    % is rejected at the validation phase, not waved through by the
    % compat-only re-check.
    check(patch_full_chain, patch_full_chain_rejected),

    % A validate step referencing a foreign spec fingerprint is rejected.
    check(spec_compat_foreign_ref,
          (   dataflow_graph_plan_graph(ForeignInput0),
              set_validate_fingerprint(ForeignInput0,
                                       'spec-sha256-foreign-spec',
                                       ForeignInput),
              d6_validate_graph(ForeignInput, ForeignGraph),
              plan_validate_against_spec_gate(ForeignGraph, Frozen,
                                              plan_environment{
                                                  capabilities:[],
                                                  inputs:EnvInputs},
                                              error(Errors)),
              get_dict(detail, Errors, ForeignFaults),
              member(foreign_spec_reference(check_spec), ForeignFaults)
          )),

    % A required SPEC input declaration missing from plan inputs is rejected.
    check(spec_compat_missing_input,
          (   d6_validate_graph(Input, Graph2),
              plan_validate_against_spec_gate(Graph2, Frozen,
                                              plan_environment{
                                                  capabilities:[],
                                                  inputs:gate_inputs{}},
                                              error(Errors2)),
              get_dict(detail, Errors2, MissingFaults),
              member(missing_spec_input('user_payload'), MissingFaults)
          )),

    % A delete step against a forbidden effect is rejected.
    check(forbidden_effect_rejected,
          (   d6_validate_graph(plan_graph(
                  steps([step(zap, delete, delete(path('src/foo.pl')), gone)])),
                  Graph3),
              plan_validate_against_spec_gate(Graph3, Frozen,
                                              plan_environment{
                                                  capabilities:[],
                                                  inputs:EnvInputs},
                                              error(Errors3)),
              get_dict(detail, Errors3, ForbiddenFaults),
              member(forbidden_effect_in_plan(zap, delete(file('src/foo.pl'))),
                     ForbiddenFaults)
          )).

set_validate_fingerprint(Input, Fingerprint, Out) :-
    d6_parse_graph(Input, Decoded),
    get_dict(steps, Decoded, Steps0),
    maplist(rebind_validate_fingerprint(Fingerprint), Steps0, Steps2),
    get_dict(deps, Decoded, Deps),
    get_dict(obligations, Decoded, Obligations),
    d6_graph_to_input(d6_graph{steps:Steps2,
                               deps:Deps,
                               obligations:Obligations},
                      Out).

d6_graph_to_input(D, plan_graph(steps(RawSteps), depends_on(RawDeps),
                                obligations(RawObls))) :-
    get_dict(steps, D, Steps),
    maplist(d6_encode_step, Steps, RawSteps),
    get_dict(deps, D, Deps),
    maplist(d6_encode_dep, Deps, RawDeps),
    get_dict(obligations, D, Obligations),
    maplist(d6_encode_obl, Obligations, RawObls).

d6_encode_step(S, step(Id, Op, Args, Bind)) :-
    get_dict(id, S, Id),
    get_dict(op, S, Op),
    get_dict(args, S, Args),
    get_dict(bind, S, Bind).

d6_encode_dep(D, depends_on(S, Rs)) :-
    get_dict(step, D, S),
    get_dict(requires, D, Rs).

d6_encode_obl(O, obligation(step:S, satisfies:R)) :-
    get_dict(step, O, S),
    get_dict(satisfies, O, R).

rebind_validate_fingerprint(F,
                            d6_step{id:Id, op:validate, args:_, bind:B},
                            d6_step{id:Id, op:validate,
                                    args:validate(spec(fingerprint(F))),
                                    bind:B}) :- !.
rebind_validate_fingerprint(_, Step, Step).

% The review's mutation graph: a no-op run step claims the tdd_evidence
% obligation and the validate step depends on it. Permanent negative check.
mutation_graph_input(Fingerprint, plan_graph(
    steps([step(fake_work, run, run(command(argv([true]))), noop),
           step(check_spec, validate,
                validate(spec(fingerprint(Fingerprint))), verified)]),
    depends_on([depends_on(check_spec, [fake_work])]),
    obligations([obligation(step:fake_work, satisfies:foo_behavior_x)]))).

% Second mutation: a genuinely code-writing step that satisfies the
% obligation but is NOT causally required by any validate step of the bound
% spec. The obligation linkage must not count it.
disconnected_graph_input(Fingerprint, plan_graph(
    steps([step(patch_foo, edit,
                edit(target(ref(symbol_ref(symbol_ref{name:foo,
                                                      kind:function,
                                                      arity:2}))),
                     content(literal(new))),
                done),
           step(check_spec, validate,
                validate(spec(fingerprint(Fingerprint))), verified)]),
    depends_on([]),
    obligations([obligation(step:patch_foo, satisfies:foo_behavior_x)]))).

obligation_causal_link_rejected :-
    frozen_tdd_spec(Frozen),
    get_dict(ref, Frozen, FrozenRef),
    get_dict(fingerprint, FrozenRef, Fingerprint),
    plan_environment{capabilities:[], inputs:gate_inputs{}} = NoEnv,
    mutation_graph_input(Fingerprint, MutationInput),
    d6_validate_graph(MutationInput, MutationGraph),
    plan_validate_against_spec_gate(MutationGraph, Frozen, NoEnv,
                                    error(MutationErrors)),
    get_dict(detail, MutationErrors, MutationFaults),
    member(dropped_obligation(foo_behavior_x), MutationFaults),
    disconnected_graph_input(Fingerprint, DisconnectedInput),
    d6_validate_graph(DisconnectedInput, DisconnectedGraph),
    plan_validate_against_spec_gate(DisconnectedGraph, Frozen, NoEnv,
                                    error(DisconnectedErrors)),
    get_dict(detail, DisconnectedErrors, DisconnectedFaults),
    member(dropped_obligation(foo_behavior_x), DisconnectedFaults).

patch_full_chain_rejected :-
    frozen_tdd_spec(Frozen),
    get_dict(ref, Frozen, FrozenRef),
    get_dict(fingerprint, FrozenRef, Fingerprint),
    dataflow_graph_plan_graph(Input0),
    set_validate_fingerprint(Input0, Fingerprint, Input),
    dataflow_env_inputs(EnvInputs),
    d6_validate_graph(Input, Graph),
    d6_apply_patch_full_chain(Graph,
                              plan_patch{op:remove,
                                         step:step(find_foo, locate, _, _),
                                         edges:[],
                                         obligations:[],
                                         reason:"drop locate",
                                         provenance:model_claim},
                              Frozen,
                              plan_environment{capabilities:[],
                                               inputs:EnvInputs},
                              error(ValidationError)),
    get_dict(phase, ValidationError, plan_validation),
    get_dict(kind, ValidationError, patched_graph_invalid).

/* ------------------------------------------------------------------ */
/* TDD evidence evaluation (§9) through the real evidence pipeline     */
/* ------------------------------------------------------------------ */

tdd_evidence_checks :-
    check(tdd_red_green, tdd_red_green_passes),
    check(tdd_not_red_rejected, tdd_not_red_is_indeterminate),
    % Both reconcile through the REAL merged verify pipeline: registry
    % identity binding, evidence policy, coherence.
    check(tdd_verify_pipeline_red_green, tdd_verify_red_green),
    check(tdd_verify_pipeline_not_red, tdd_verify_not_red).

tdd_red_green_passes :-
    tdd_assertion_term(Assertion),
    tdd_observation(_{red_status:failed, green_status:passed},
                    Assertion, Observation),
    tdd_evidence_evaluator(Assertion, Observation, passed).

tdd_not_red_is_indeterminate :-
    tdd_assertion_term(Assertion),
    tdd_observation(_{red_status:passed, green_status:passed},
                    Assertion, Observation),
    tdd_evidence_evaluator(Assertion, Observation,
                           indeterminate(evidence_not_red)).

tdd_verify_red_green :-
    frozen_tdd_spec(Frozen),
    design_registry(Registry),
    get_dict(requirements, Frozen, Requirements),
    member(Req, Requirements),
    get_dict(id, Req, foo_behavior_x),
    get_dict(assertion, Req, TddAssertion),
    get_dict(verifier, Req, TddVerifier),
    get_dict(collector, Req, TddCollector),
    tdd_observation(_{red_status:failed, green_status:passed},
                    TddAssertion, TddVerifier, TddCollector, ObsPass),
    spec_verify(Frozen, [ObsPass], Registry, ok(ReportPass)),
    get_dict(status, ReportPass, passed).

tdd_verify_not_red :-
    frozen_tdd_spec(Frozen),
    design_registry(Registry),
    get_dict(requirements, Frozen, Requirements),
    member(Req, Requirements),
    get_dict(id, Req, foo_behavior_x),
    get_dict(assertion, Req, TddAssertion),
    get_dict(verifier, Req, TddVerifier),
    get_dict(collector, Req, TddCollector),
    tdd_observation(_{red_status:passed, green_status:passed},
                    TddAssertion, TddVerifier, TddCollector, ObsNotRed),
    spec_verify(Frozen, [ObsNotRed], Registry, ok(ReportNotRed)),
    get_dict(status, ReportNotRed, rejected).

tdd_assertion_term(rlm_assertion{kind:tdd_evidence,
                                 schema_version:1,
                                 args:tdd_args{requirement:foo_behavior_x,
                                               test:test_key{suite:unit,
                                                             id:foo_x_test},
                                               pre_revision:head,
                                               post_revision:working}}).

tdd_observation(Flags, Assertion, Observation) :-
    tdd_observation(Flags, Assertion,
                    verifier{id:tdd_evidence, version:1},
                    collector{id:tdd_evidence, version:1},
                    Observation).

tdd_observation(Flags, Assertion, Verifier, Collector, Observation) :-
    tdd_observation_payload(Flags, Assertion, Verifier, Collector, Payload),
    observation_normalize(Payload, ok(Observation)).

tdd_observation_payload(Flags, Assertion, Verifier, Collector,
                        _{requirement_id:foo_behavior_x,
                          assertion:Assertion,
                          status:passed,
                          value:_{red:_{status:RedStatus},
                                  green:_{status:GreenStatus},
                                  test:_{suite:unit, id:foo_x_test}},
                          evidence_refs:[evidence:red_run_1,
                                         evidence:green_run_1],
                          source_class:external_observation,
                          trust_class:observed,
                          verifier:Verifier,
                          collector:Collector,
                          snapshot:none,
                          freshness:current,
                          coherence:none,
                          state_ref:revision(working)}) :-
    get_dict(red_status, Flags, RedStatus),
    get_dict(green_status, Flags, GreenStatus).

/* ------------------------------------------------------------------ */
/* edit_action + expert contract schemas (§8)                          */
/* ------------------------------------------------------------------ */

edit_action_checks :-
    check(edit_action_ok, edit_action_accepts_valid),
    check(edit_action_rejects_unknown_operation, edit_action_rejects_rewrite),
    check(edit_action_rejects_missing_content, edit_action_rejects_no_content),
    check(expert_contract_ok, expert_contract_accepted),
    check(expert_contract_widening_denied, expert_contract_widening_rejected),
    check(expert_contract_shape, expert_contract_shape_rejections).

edit_action_accepts_valid :-
    edit_action_ok(_{target:ref(symbol_ref(symbol_ref{name:foo,
                                                      kind:function,
                                                      arity:2})),
                     operation:replace,
                     content:"function foo(a, b) { ... }",
                     basis:head,
                     satisfies:[foo_behavior_x]}).

edit_action_rejects_rewrite :-
    \+ edit_action_ok(_{target:span(source_span{file:'f.pl',
                                                start_byte:0,
                                                end_byte:3}),
                        operation:rewrite,
                        content:"x",
                        basis:none,
                        satisfies:[]}).

edit_action_rejects_no_content :-
    \+ edit_action_ok(_{target:span(source_span{file:'f.pl',
                                                start_byte:0,
                                                end_byte:3}),
                        operation:replace,
                        content:none,
                        basis:head,
                        satisfies:[]}).

expert_contract_accepted :-
    expert_contract_base(Base),
    expert_contract_ok(Base,
                       plan_environment{capabilities:[tool(edit),
                                                      model(main)],
                                        inputs:empty_env{}}).

% Schema-valid contract (§8.1); mutated per negative case in
% expert_contract_shape_rejections.
expert_contract_base(_{op:edit/2,
                       capabilities:[tool(edit), model(main)],
                       inner_capabilities:[model(main)],
                       input_schema:edit_action,
                       output_schema:write_result,
                       effects:[external_effect],
                       authority_tier:allow_once,
                       model_policy:_{'provider':main,
                                      'max_iterations':8},
                       budget_policy:shared_step_budget,
                       completion:[applied_and_observed],
                       failure:[blocked, failed]}).

expert_contract_env(plan_environment{capabilities:[tool(edit), model(main)],
                                     inputs:empty_env{}}).

expert_contract_shape_rejections :-
    expert_contract_base(Base),
    expert_contract_env(Env),
    % inner_capabilities is a required schema field (D6-8).
    del_dict(inner_capabilities, Base, _, NoInner),
    \+ expert_contract_ok(NoInner, Env),
    % inner_capabilities must stay within environment grants.
    put_dict(inner_capabilities, Base,
             [model(main), tool(sync_remote)], WideInner),
    \+ expert_contract_ok(WideInner, Env),
    % model_policy{provider, max_iterations} is shape-checked, not any-dict.
    get_dict(model_policy, Base, MP0),
    put_dict(max_iterations, MP0, 0, MPBadMax),
    put_dict(model_policy, Base, MPBadMax, ContractBadMax),
    \+ expert_contract_ok(ContractBadMax, Env),
    del_dict(provider, MP0, _, MPNoProvider),
    put_dict(model_policy, Base, MPNoProvider, ContractNoProvider),
    \+ expert_contract_ok(ContractNoProvider, Env),
    % budget_policy is a closed atom.
    put_dict(budget_policy, Base, unlimited, ContractBadBudget),
    \+ expert_contract_ok(ContractBadBudget, Env),
    % completion/failure condition values are closed atoms.
    put_dict(completion, Base, [somehow_done], ContractBadCompletion),
    \+ expert_contract_ok(ContractBadCompletion, Env),
    put_dict(failure, Base, [gave_up], ContractBadFailure),
    \+ expert_contract_ok(ContractBadFailure, Env).

expert_contract_widening_rejected :-
    expert_contract_base(Base),
    % Both the op's own required capabilities and the expert's inner
    % capabilities must stay within environment grants.
    \+ expert_contract_ok(Base,
                          plan_environment{capabilities:[tool(edit)],
                                           inputs:empty_env{}}),
    put_dict(inner_capabilities, Base, [model(main)], InnerOnly),
    \+ expert_contract_ok(InnerOnly,
                          plan_environment{capabilities:[tool(edit)],
                                           inputs:empty_env{}}).

/* ------------------------------------------------------------------ */
/* Durability: durable bindings through the merged persistency layer   */
/* ------------------------------------------------------------------ */

durability_checks :-
    check(resume_snapshot_ok,
          (   tmp_file(design_gate_kb, TmpDb0),
              atom_concat(TmpDb0, '.db', TmpDb),
              setup_call_cleanup(
                  graph_persist_open(TmpDb),
                  (   design_snapshot(Snapshot),
                      plan_kb_snapshot_schema_ok(Snapshot),
                      graph_persist_put_checkpoint(run_design_gate,
                                                   'plan_graph_design_gate',
                                                   Snapshot),
                      graph_persist_get_checkpoint(run_design_gate,
                                                   'plan_graph_design_gate',
                                                   Restored),
                      get_dict(bindings, Restored, RestoredBindings),
                      get_dict('foo_edit', RestoredBindings, EditAction),
                      get_dict(content, EditAction,
                               "function foo(a, b) { ... }"),
                      get_dict(position, Restored, patch_foo)
                  ),
                  graph_persist_close),
              catch(delete_file(TmpDb), _, true)
          )),
    % §12.2 forward projection data model (d12): the plan-KB snapshot
    % carries the covered event-sequence range [event_lo, event_hi]; the
    % model-visible boundary summary carries the covered message-id range
    % as derived data over a trusted_runtime range; prior ranges stay
    % addressable because the summary is a projection of [1, Hi], never a
    % history rewrite.
    check(forward_projection_snapshot, forward_projection_data_model).

design_snapshot(plan_kb_snapshot{
    spec_ref:spec_ref{series:design,
                      version:1,
                      fingerprint:'spec-sha256-design-gate'},
    graph:plan_graph(steps([]), depends_on([]), obligations([])),
    statuses:status_map{'patch_foo':pending},
    results:results_map{},
    bindings:bindings{
        'foo_edit':edit_action{
            target:ref(symbol_ref{name:foo, kind:function, arity:2}),
            operation:replace,
            content:"function foo(a, b) { ... }",
            basis:head,
            satisfies:[foo_behavior_x]}},
    expert_checkpoints:[],
    budget_remaining:runtime_budget{steps:64,
                                    model_calls:8,
                                    tool_calls:16,
                                    context_ops:32,
                                    output_bytes:65536},
    position:patch_foo,
    repair_count:0,
    failure_refs:[],
    evidence_refs:[],
    effect_attempt_refs:[],
    covers:[1, 10]}).

plan_kb_snapshot_schema_ok(Snapshot) :-
    is_dict(Snapshot),
    dict_keys(Snapshot, Keys),
    forall(member(Key, Keys),
           memberchk(Key, [spec_ref, graph, statuses, results, bindings,
                           expert_checkpoints, budget_remaining, position,
                           repair_count, failure_refs, evidence_refs,
                           effect_attempt_refs, covers])),
    forall(member(Required, [spec_ref, graph, statuses, results, bindings,
                             budget_remaining, position, repair_count,
                             covers]),
           get_dict(Required, Snapshot, _)),
    get_dict(spec_ref, Snapshot, SpecRef),
    is_dict(SpecRef),
    get_dict(fingerprint, SpecRef, Fingerprint),
    atom_concat('spec-sha256-', _, Fingerprint),
    get_dict(covers, Snapshot, Covers),
    covers_range_ok(Covers).

dict_keys(Dict, Keys) :-
    dict_pairs(Dict, _, Pairs),
    maplist(arg(1), Pairs, Keys).

forward_projection_data_model :-
    design_snapshot_forward(Snapshot),
    plan_kb_snapshot_schema_ok(Snapshot),
    get_dict(covers, Snapshot, SnapshotCovers),
    covers_range_ok(SnapshotCovers),
    boundary_summary_ok(boundary_summary{kind:boundary_summary,
                                         covers:SnapshotCovers,
                                         trust_class:derived,
                                         source_class:trusted_runtime}),
    get_dict(covers, Snapshot, [_, Hi]),
    covers_range_ok([1, Hi]).

covers_range_ok([Lo, Hi]) :-
    integer(Lo), integer(Hi),
    Lo >= 1,
    Lo =< Hi.

boundary_summary_ok(Summary) :-
    is_dict(Summary),
    dict_keys(Summary, Keys),
    forall(member(K, Keys),
           memberchk(K, [kind, covers, trust_class, source_class])),
    get_dict(kind, Summary, boundary_summary),
    get_dict(covers, Summary, Covers),
    covers_range_ok(Covers),
    get_dict(trust_class, Summary, derived),
    get_dict(source_class, Summary, trusted_runtime).

% §12.2 snapshot variant: same closed snapshot schema with the covered
% event-sequence range advanced (forward projection, never compaction).
design_snapshot_forward(Snapshot) :-
    design_snapshot(Snapshot0),
    put_dict(covers, Snapshot0, [1, 10], Snapshot).

/* ------------------------------------------------------------------ */
/* Multi-run readability (§7.3): no mode one-shots                      */
/* ------------------------------------------------------------------ */

state_readability_checks :-
    check(multi_run_reprojection, multi_run_reprojection_table).

% §7.1: interface names normalize to runtime atoms through ONE boundary
% (the adopted rlm_spec_strategy normalize_mode admits exactly these).
design_strategy_mode(direct, direct).
design_strategy_mode(symbolic, typed_plan).
design_strategy_mode(recursive_symbolic, typed_plan).

% §7.3 mode table (design data): per-exchange project-state re-projection
% obligation per runtime mode/route, owned by the declared slice that
% implements it.
mode_reprojection(direct, per_turn_recompile, s10).
mode_reprojection(typed_plan, retrieve_before_proposal, s05).
mode_reprojection(typed_plan, bounded_current_projection, s11).

multi_run_reprojection_table :-
    design_strategy_mode(direct, direct),
    design_strategy_mode(symbolic, typed_plan),
    design_strategy_mode(recursive_symbolic, typed_plan),
    % The normalization boundary admits no other interface names.
    \+ (   design_strategy_mode(Interface, _),
           \+ memberchk(Interface, [direct, symbolic, recursive_symbolic])
       ),
    % Every §7.3 obligation is present and owned by a declared slice:
    % direct re-compiles provider-visible context per provider turn; expert
    % loops retrieve changed state before each proposal; subplans receive
    % bounded projections of the parent's CURRENT view.
    mode_reprojection(direct, per_turn_recompile, s10),
    mode_reprojection(typed_plan, retrieve_before_proposal, s05),
    mode_reprojection(typed_plan, bounded_current_projection, s11),
    declared_slice_set(Slices),
    forall(mode_reprojection(_, _, Slice), memberchk(Slice, Slices)).

/* ------------------------------------------------------------------ */
/* Research KB discipline + implementation DAG                         */
/* ------------------------------------------------------------------ */

kb_dag_checks :-
    check(kb_discipline_ok,
          (   gate_root(Root),
              atomic_list_concat([Root,
                                  '/research/spec-plan-refinement-kb.pl'],
                                 KbFile),
              use_module(KbFile),
              kb_check
          )),
    check(dag_ok,
          (   declared_slice_set(Slices),
              % Slice-to-slice edges stay inside the slice set; any edge
              % pointing outside must target a completed design task.
              forall(( kb_depends(S, Dep),
                       sub_atom(S, 0, 1, _, s) ),
                     (   memberchk(S, Slices),
                         (   memberchk(Dep, Slices)
                         ;   kb_task_done(Dep)
                         )
                     )),
              \+ kb_slice_cycle,
              findall(D, kb_depends(s00, D), [d04])
          )),
    % Every persisted kb_evidence ref must resolve: gate:<Id> refs name
    % check ids this gate defines; design:spec-plan-authority#<anchor> refs
    % name anchors parsed from the design record's own headings. Runs last
    % so every referenced check id has been registered.
    check(kb_evidence_refs_resolve, kb_evidence_refs_resolve_run).

kb_evidence_refs_resolve_run :-
    doc_anchor_slugs(Slugs),
    forall(spec_plan_refinement_kb:kb_evidence(_Task, EvidenceRef),
           evidence_ref_resolves(EvidenceRef, Slugs)).

evidence_ref_resolves(EvidenceRef, _Slugs) :-
    atom_concat('gate:', CheckId, EvidenceRef),
    !,
    check_defined(CheckId).
evidence_ref_resolves(EvidenceRef, Slugs) :-
    atom_concat('design:spec-plan-authority#', Anchor, EvidenceRef),
    !,
    memberchk(Anchor, Slugs).
evidence_ref_resolves(EvidenceRef, _) :-
    atom_concat('source:', SourceRef, EvidenceRef),
    !,
    source_ref_resolves(SourceRef).

% source:<path> | source:<path>:<symbol> name checkout files (and a
% defined predicate inside them); source:rage288:<path> names the pinned
% BASE object, which is loaded as the rlm_plan_graph module.
source_ref_resolves(SourceRef) :-
    atom_concat('rage288:', _, SourceRef),
    !,
    current_module(rlm_plan_graph).
source_ref_resolves(SourceRef) :-
    (   atomic_list_concat([FilePart, Symbol], ':', SourceRef)
    ->  true
    ;   FilePart = SourceRef,
        Symbol = none
    ),
    gate_root(Root),
    atomic_list_concat([Root, '/', FilePart], FilePath),
    exists_file(FilePath),
    source_symbol_resolves(FilePart, Symbol).

source_symbol_resolves(_, none) :- !.
source_symbol_resolves(FilePart, Symbol) :-
    atomic_list_concat(PathSegments, '/', FilePart),
    last(PathSegments, BaseFile),
    atom_concat(Module, '.pl', BaseFile),
    current_predicate(Module:Symbol/_).

% GitHub-style anchor slugs parsed from the design record's headings.
doc_anchor_slugs(Slugs) :-
    gate_root(Root),
    atomic_list_concat([Root, '/docs/research/spec-plan-authority.md'],
                       DocFile),
    setup_call_cleanup(
        open(DocFile, read, In),
        (   read_heading_lines_(In, Headings),
            maplist(github_anchor, Headings, Slugs0),
            sort(Slugs0, Slugs)
        ),
        close(In)).

read_heading_lines_(In, Headings) :-
    read_line_to_string(In, Line),
    (   Line == end_of_file
    ->  Headings = []
    ;   (   sub_atom(Line, 0, _, _, '#')
        ->  Headings = [Line|Rest]
        ;   Headings = Rest
        ),
        read_heading_lines_(In, Rest)
    ).

% Markdown "## 2.1 Title — Sub" → GitHub anchor "21-title--sub":
% lowercase ASCII letters/digits, underscore and hyphen kept, spaces become
% hyphens, every other code point dropped (so punctuation, arrows and
% em-dashes vanish, leaving the surrounding space hyphens in place).
github_anchor(Line, Anchor) :-
    atom_codes(Line, Codes0),
    skip_hashes_(Codes0, Codes1),
    % Drop the single markdown heading space (explicit code list: " " is a
    % SWI string, not a code list).
    (   Codes1 = [32|Codes2] -> true ; Codes2 = Codes1 ),
    slugify_(Codes2, SlugCodes),
    atom_codes(Anchor, SlugCodes).

skip_hashes_([0'#|T], R) :- !, skip_hashes_(T, R).
skip_hashes_(R, R).

slug_keep_(C) :- between(0'0, 0'9, C).
slug_keep_(C) :- between(0'a, 0'z, C).
slug_keep_(C) :- between(0'A, 0'Z, C).
slug_keep_(0'_).
slug_keep_(0'-).

slugify_([], []).
slugify_([C|T], [0'-|R]) :-
    (   C == 0'  ; C == 0'\t
    ),
    !,
    slugify_(T, R).
slugify_([C|T], [C2|R]) :-
    slug_keep_(C),
    !,
    (   between(0'A, 0'Z, C)
    ->  C2 is C + 32
    ;   C2 = C
    ),
    slugify_(T, R).
slugify_([_|T], R) :-
    slugify_(T, R).

declared_slice_set([s00, s01, s02, s03, s04, s05, s06, s07, s08, s09, s10,
                    s11]).

kb_slice_cycle :-
    kb_depends(Start, _),
    slice_dfs(Start, [Start], _).

slice_dfs(Node, Path, [Next|Path]) :-
    kb_depends(Node, Next),
    memberchk(Next, Path),
    !.
slice_dfs(Node, Path, Cycle) :-
    kb_depends(Node, Next),
    \+ memberchk(Next, Path),
    slice_dfs(Next, [Next|Path], Cycle).

/* ------------------------------------------------------------------ */
/* D6 delta grammar (gate-local normative checkers)                    */
/* ------------------------------------------------------------------ */

d6_parse_graph(plan_graph(steps(Steps), depends_on(DependsOn),
                          obligations(Obligations)),
               Decoded) :-
    !,
    require_list(Steps, steps),
    maplist(d6_decode_step, Steps, DecodedSteps),
    (   is_list(DependsOn)
    ->  maplist(d6_decode_dep, DependsOn, DecodedDeps)
    ;   DecodedDeps = []
    ),
    (   is_list(Obligations)
    ->  maplist(d6_decode_obligation, Obligations, DecodedObligations)
    ;   DecodedObligations = []
    ),
    Decoded = d6_graph{steps:DecodedSteps, deps:DecodedDeps,
                       obligations:DecodedObligations}.
d6_parse_graph(plan_graph(steps(Steps), depends_on(DependsOn)), Decoded) :-
    !,
    d6_parse_graph(plan_graph(steps(Steps), depends_on(DependsOn),
                              obligations([])),
                   Decoded).
d6_parse_graph(plan_graph(steps(Steps)), Decoded) :-
    !,
    d6_parse_graph(plan_graph(steps(Steps), depends_on([]),
                              obligations([])),
                   Decoded).
d6_parse_graph(Input, _) :-
    throw(gate_fault(d6_invalid_graph(Input))).

d6_decode_step(step(Id, Op, Args, Bind),
               d6_step{id:Id, op:Op, args:Args, bind:Bind}) :-
    atom(Id), atom(Op), atom(Bind), d6_ground(Args), !.
d6_decode_step(Step, _) :-
    throw(gate_fault(d6_invalid_step(Step))).

d6_decode_dep(depends_on(StepId, Requires), dep{step:StepId, requires:Requires}) :-
    atom(StepId), is_list(Requires),
    forall(member(R, Requires), atom(R)), !.
d6_decode_dep(Dep, _) :-
    throw(gate_fault(d6_invalid_dep(Dep))).

d6_decode_obligation(obligation(step:StepId, satisfies:ReqId),
                     obl{step:StepId, satisfies:ReqId}) :-
    atom(StepId), atom(ReqId), !.
d6_decode_obligation(O, _) :-
    throw(gate_fault(d6_invalid_obligation(O))).

d6_validate_graph(Input, Graph) :-
    d6_validate_graph(Input, empty_inputs{}, Graph).

% Environment-aware validation (D6-1): the execution input dict is part of
% the graph's binding context, so expr input(Name) leaves resolve from
% Environment.inputs FIRST, then from dependency-closure step binds.
d6_validate_graph(Input, EnvInputs, Graph) :-
    d6_parse_graph(Input, Decoded),
    get_dict(steps, Decoded, Steps),
    get_dict(deps, Decoded, Deps),
    d6_check_vocabulary(Steps),
    d6_check_ids(Steps),
    d6_check_arg_shapes(Steps),
    d6_check_closure(Steps, Deps, EnvInputs),
    d6_check_obligations(Decoded),
    Graph = Decoded.

d6_check_vocabulary(Steps) :-
    forall(member(d6_step{id:_, op:Op, args:Args, bind:_}, Steps),
           (   functor(Args, Op, _),
               plan_graph_op(Op/Arity),
               Arity > 0,
               functor(Args, _, Arity)
           )).

d6_check_ids(Steps) :-
    maplist(d6_step_id, Steps, Ids),
    sort(Ids, Sorted), length(Ids, N), length(Sorted, N),
    maplist(d6_step_bind, Steps, Binds),
    sort(Binds, SortedB), length(Binds, N), length(SortedB, N),
    forall(member(d6_step{id:Id, op:_, args:_, bind:B}, Steps),
           Id \== B).

d6_step_id(Step, Id) :- get_dict(id, Step, Id).
d6_step_bind(Step, B) :- get_dict(bind, Step, B).

d6_check_arg_shapes(Steps) :-
    forall(member(Step, Steps),
           (   get_dict(op, Step, Op),
               get_dict(args, Step, Args),
               d6_args_shape(Op, Args)
           )).

% Static shapes: leaves may be expr(E) (grammar-checked) or typed values.
d6_args_shape(sync_remote, sync_remote(op(A))) :- atom(A).
d6_args_shape(index, index(scope(S))) :- d6_scope(S).
d6_args_shape(search, search(pattern(P), scope(S))) :-
    atom(P), d6_scope(S).
d6_args_shape(locate, locate(symbol_ref(Ref))) :-
    symbol_ref_dict(Ref).
d6_args_shape(read, read(source(S))) :- d6_source_selector(S).
d6_args_shape(diff, diff(L, R)) :- d6_diff_side(L), d6_diff_side(R).
d6_args_shape(edit, edit(target(T), content(C))) :-
    d6_edit_target(T), d6_content(C).
d6_args_shape(create, create(path(A), content(C))) :-
    path_atom(A), d6_content(C).
d6_args_shape(delete, delete(path(A))) :- path_atom(A).
d6_args_shape(run, run(command(argv(L)))) :-
    is_list(L), L \== [], forall(member(X, L), atom(X)).
d6_args_shape(validate, validate(spec(fingerprint(F)))) :- atom(F).
d6_args_shape(delegate, delegate(task(A), caps(C))) :-
    atom(A), is_list(C).

% Resolved shapes (post-admission): expr leaves are gone; strict types.
d6_args_shape_resolved(sync_remote, sync_remote(op(A))) :- atom(A).
d6_args_shape_resolved(index, index(scope(S))) :- d6_scope(S).
d6_args_shape_resolved(search, search(pattern(P), scope(S))) :-
    atom(P), d6_scope(S).
d6_args_shape_resolved(locate, locate(symbol_ref(Ref))) :-
    symbol_ref_dict(Ref).
d6_args_shape_resolved(read, read(source(S))) :- d6_source_selector(S).
d6_args_shape_resolved(diff, diff(L, R)) :- d6_diff_side(L), d6_diff_side(R).
d6_args_shape_resolved(edit, edit(target(T), content(C))) :-
    d6_edit_target(T),
    d6_text_value(C).
d6_args_shape_resolved(create, create(path(A), content(C))) :-
    path_atom(A), d6_text_value(C).
d6_args_shape_resolved(delete, delete(path(A))) :- path_atom(A).
d6_args_shape_resolved(run, run(command(argv(L)))) :-
    is_list(L), L \== [], forall(member(X, L), atom(X)).
d6_args_shape_resolved(validate, validate(spec(fingerprint(F)))) :- atom(F).
d6_args_shape_resolved(delegate, delegate(task(A), caps(C))) :-
    atom(A), is_list(C).

d6_scope(all).
d6_scope(path(A)) :- path_atom(A).

% Any typed leaf position may be expr(E) statically. Post-resolution strict
% shapes are enforced by d6_args_shape_resolved/2; the dataflow round trip
% applies it to every resolved step it executes, so admission-time
% substitution is followed by strict re-validation.
d6_leaf(expr(E), _) :- !, d6_graph_expr(E).
d6_leaf(V, Check) :- call(Check, V).

span_value(source_span{file:F, start_byte:S, end_byte:E}) :-
    path_atom(F), integer(S), S >= 0, integer(E), E >= 0, S =< E.

d6_source_selector(path(A)) :- path_atom(A).
d6_source_selector(span(Leaf)) :- d6_leaf(Leaf, design_gate:span_value).
d6_source_selector(ref(symbol_ref(Leaf))) :-
    d6_leaf(Leaf, design_gate:symbol_ref_dict).

d6_diff_side(path(A)) :- path_atom(A).
d6_diff_side(ref(symbol_ref(Leaf))) :-
    d6_leaf(Leaf, design_gate:symbol_ref_dict).
d6_diff_side(span(Leaf)) :- d6_leaf(Leaf, design_gate:span_value).
d6_diff_side(revision(head)).
d6_diff_side(revision(working)).
d6_diff_side(revision(committed(A))) :- atom(A).
d6_diff_side(revision(branch(A))) :- atom(A).
d6_diff_side(revision(remote(A, B))) :- atom(A), atom(B).

d6_edit_target(ref(symbol_ref(Leaf))) :-
    d6_leaf(Leaf, design_gate:symbol_ref_dict).
d6_edit_target(span(Leaf)) :- d6_leaf(Leaf, design_gate:span_value).

d6_content(literal(Text)) :- d6_text_value(Text).
d6_content(expr(E)) :- d6_graph_expr(E).

% Text values are atoms or SWI strings (never ''), matching the doc's
% "text or a valid edit_action dict" content contract (D6-2). A resolved
% edit content may also be a validated edit_action dict.
d6_text_value(Text) :-
    (   atom(Text) ; string(Text)
    ),
    Text \== ''.
d6_text_value(C) :-
    is_dict(C),
    edit_action_ok(C).

% Closed graph-level expression grammar (merged rlm_plan expressions minus
% var/1, which belongs to the desugared layer).
d6_graph_expr(input(Name)) :- atom(Name).
d6_graph_expr(field(Base, Key)) :- d6_graph_expr(Base), atom(Key).
d6_graph_expr(literal(V)) :- d6_ground(V).
d6_graph_expr(list(Vs)) :- is_list(Vs), maplist(d6_graph_expr, Vs).
d6_graph_expr(object(Pairs)) :-
    is_list(Pairs),
    forall(member(K-V, Pairs), (atom(K), d6_graph_expr(V))).

path_atom(A) :- atom(A), A \== '', \+ sub_atom(A, _, _, _, '..').

symbol_ref_dict(Ref) :-
    is_dict(Ref),
    dict_keys(Ref, Keys),
    forall(member(K, Keys), memberchk(K, [name, kind, arity, owner,
                                          occurrence])),
    get_dict(name, Ref, Name), atom(Name), Name \== '',
    get_dict(kind, Ref, Kind),
    memberchk(Kind, [function, method, constructor, predicate, rule, macro,
                     operator, class, field, property, type, module,
                     annotation]),
    (   get_dict(arity, Ref, Arity) -> integer(Arity), Arity >= 0 ; true ),
    (   get_dict(occurrence, Ref, Occ) ->
        memberchk(Occ, [definition, reference, any])
    ;   true
    ).

d6_check_closure(Steps, Deps, EnvInputs) :-
    maplist(d6_dep_pair, Deps, DepPairs),
    forall(member(Step, Steps),
           (   get_dict(id, Step, Id),
               get_dict(bind, Step, B),
               get_dict(args, Step, Args),
               d6_expr_inputs(Args, Refs),
               forall(member(Ref, Refs),
                      d6_resolvable(Id, B, Ref, Steps, DepPairs, EnvInputs))
           )).

% D6-1 resolution order: environment inputs first, then a step bind
% reachable through the dependency closure (self-reference is dangling).
d6_resolvable(Id, B, Ref, Steps, DepPairs, EnvInputs) :-
    (   is_dict(EnvInputs),
        get_dict(Ref, EnvInputs, _)
    ->  true
    ;   Ref \== B,
        member(Step, Steps),
        get_dict(bind, Step, Ref),
        reachable_bind(Id, Ref, Steps, DepPairs, [Id])
    ).

reachable_bind(Id, Ref, Steps, DepPairs, Seen) :-
    member(Id-Rs, DepPairs),
    member(R, Rs),
    (   member(Step, Steps),
        get_dict(id, Step, R),
        get_dict(bind, Step, Ref)
    ->  true
    ;   \+ memberchk(R, Seen),
        reachable_bind(R, Ref, Steps, DepPairs, [R|Seen])
    ).

d6_dep_pair(Dep, S-Rs) :-
    get_dict(step, Dep, S),
    get_dict(requires, Dep, Rs).

d6_check_obligations(Graph) :-
    get_dict(obligations, Graph, Obligations),
    get_dict(steps, Graph, Steps),
    forall(member(Obl, Obligations),
           (   get_dict(step, Obl, S),
               member(Step, Steps),
               get_dict(id, Step, S)
           )).

d6_expr_inputs(Args, Refs) :-
    d6_expr_inputs_(Args, Refs0),
    sort(Refs0, Refs).

d6_expr_inputs_(expr(E), Refs) :- !,
    d6_expr_inputs_e(E, Refs).
d6_expr_inputs_(Term, Refs) :-
    is_dict(Term),
    !,
    dict_pairs(Term, _, Pairs),
    maplist(d6_dict_value_inputs, Pairs, Nested),
    append(Nested, Refs).
d6_expr_inputs_(Term, Refs) :-
    compound(Term),
    !,
    Term =.. [_|Args],
    maplist(d6_expr_inputs_, Args, Nested),
    append(Nested, Refs).
d6_expr_inputs_(_, []).

d6_dict_value_inputs(_-V, Refs) :- d6_expr_inputs_(V, Refs).

d6_expr_inputs_e(input(Name), [Name]) :- !.
d6_expr_inputs_e(field(Base, _), Refs) :- !,
    d6_expr_inputs_e(Base, Refs).
d6_expr_inputs_e(literal(_), []).
d6_expr_inputs_e(list(Vs), Refs) :-
    maplist(d6_expr_inputs_e, Vs, Nested),
    append(Nested, Refs).
d6_expr_inputs_e(object(Pairs), Refs) :-
    maplist(d6_pair_inputs, Pairs, Nested),
    append(Nested, Refs).

d6_pair_inputs(_-E, Refs) :- d6_expr_inputs_e(E, Refs).

d6_apply_patch(Graph, Patch, Patched) :-
    get_dict(op, Patch, remove),
    get_dict(step, Patch, step(StepId, _, _, _)),
    get_dict(steps, Graph, Steps0),
    exclude(d6_step_id_is(StepId), Steps0, Steps),
    get_dict(deps, Graph, DepsRaw),
    maplist(d6_drop_dep(StepId), DepsRaw, Deps0),
    include(d6_dep_nonempty, Deps0, Deps),
    get_dict(obligations, Graph, Obligations0),
    exclude(d6_obl_step(StepId), Obligations0, Obligations),
    Patched = d6_graph{steps:Steps, deps:Deps, obligations:Obligations}.

d6_step_id_is(StepId, Step) :- get_dict(id, Step, StepId).
d6_drop_dep(StepId, Dep, Dep0) :-
    get_dict(step, Dep, S),
    get_dict(requires, Dep, Rs),
    exclude(==(StepId), Rs, Rs0),
    dict_pairs(Dep0, dep, [step-S, requires-Rs0]).
d6_dep_nonempty(Dep) :-
    get_dict(requires, Dep, Rs),
    Rs \== [].
d6_obl_step(StepId, Obl) :- get_dict(step, Obl, StepId).

% §11.1: applying a patch re-runs the FULL chain on the patched graph —
% parse + plan-graph validation (env-aware, so dangling-input re-checking
% is included) + spec compat — never the compat layer alone.
d6_apply_patch_full_chain(Graph, Patch, Frozen, Env, Outcome) :-
    d6_apply_patch(Graph, Patch, Patched),
    d6_graph_to_input(Patched, PatchedInput),
    get_dict(inputs, Env, EnvInputs),
    (   catch(d6_validate_graph(PatchedInput, EnvInputs, PatchedGraph),
              _, fail)
    ->  plan_validate_against_spec_gate(PatchedGraph, Frozen, Env, Outcome)
    ;   Outcome = error(plan_graph_error{phase:plan_validation,
                                         kind:patched_graph_invalid,
                                         detail:none})
    ).

d6_desugar(StepId, Op, Graph, Binding, Plan) :-
    get_dict(steps, Graph, Steps),
    member(Step, Steps),
    get_dict(id, Step, StepId),
    get_dict(op, Step, Op),
    get_dict(bind, Step, Bind),
    d6_resolve_step_args(StepId, Graph, Binding, Resolved),
    d6_tool_name(Op, ToolName),
    Plan = plan([tool(ToolName, literal(Resolved), Bind),
                 final(var(Bind))]).

d6_desugar_with_args(Op, Resolved, Bind, Plan) :-
    d6_tool_name(Op, ToolName),
    Plan = plan([tool(ToolName, literal(Resolved), Bind),
                 final(var(Bind))]).

d6_resolve_step_args(StepId, Graph, Binding, Resolved) :-
    get_dict(steps, Graph, Steps),
    member(d6_step{id:StepId, op:_, args:Args, bind:_}, Steps),
    d6_resolve_args(Args, Binding, Resolved).

d6_resolve_args(Args, Binding, Resolved) :-
    d6_resolve_term(Args, Binding, Resolved).

d6_resolve_term(expr(E), Binding, Value) :- !,
    d6_resolve_expr(E, Binding, Value).
d6_resolve_term(Term, Binding, Resolved) :-
    is_dict(Term),
    !,
    dict_pairs(Term, Tag, Pairs),
    (   var(Tag)
    ->  Resolved = Term
    ;   maplist(d6_resolve_pair(Binding), Pairs, ResolvedPairs),
        dict_pairs(Resolved, Tag, ResolvedPairs)
    ).
d6_resolve_term(Term, Binding, Resolved) :-
    compound(Term),
    !,
    Term =.. [F|Args0],
    maplist(d6_resolve_arg(Binding), Args0, Args),
    Resolved =.. [F|Args].
d6_resolve_term(V, _, V).

d6_resolve_arg(Binding, Arg, Resolved) :-
    d6_resolve_term(Arg, Binding, Resolved).

d6_resolve_pair(Binding, K-V0, K-V) :-
    d6_resolve_term(V0, Binding, V).

d6_resolve_expr(input(Name), Binding, Value) :-
    (   is_dict(Binding),
        get_dict(Name, Binding, Value)
    ->  true
    ;   throw(gate_fault(d6_unresolved_input(Name)))
    ).
d6_resolve_expr(field(Base, Key), Binding, Value) :-
    d6_resolve_expr(Base, Binding, BaseValue),
    (   is_dict(BaseValue)
    ->  get_dict(Key, BaseValue, Value)
    ;   throw(gate_fault(d6_field_on_non_dict(Key, BaseValue)))
    ).
d6_resolve_expr(literal(V), _, V).
d6_resolve_expr(list(Vs), Binding, Values) :-
    maplist(d6_resolve_expr_(Binding), Vs, Values).
d6_resolve_expr(object(Pairs), Binding, Values) :-
    maplist(d6_resolve_pair_expr(Binding), Pairs, Values).

d6_resolve_expr_(Binding, E, V) :- d6_resolve_expr(E, Binding, V).
d6_resolve_pair_expr(Binding, K-E, K-V) :- d6_resolve_expr(E, Binding, V).

d6_tool_name(delegate, spawn_agent) :- !.
d6_tool_name(Op, Op).

/* ------------------------------------------------------------------ */
/* plan_validate_against_spec_gate/4 (§11 normative checker; S8)        */
/* ------------------------------------------------------------------ */

plan_validate_against_spec_gate(Graph, Frozen, Env, ok(Report)) :-
    d6_compat_checks(Graph, Frozen, Env, []),
    !,
    get_dict(ref, Frozen, FrozenRef),
    Report = spec_compat_report{spec_ref:FrozenRef}.
plan_validate_against_spec_gate(Graph, Frozen, Env, error(Errors)) :-
    d6_compat_checks(Graph, Frozen, Env, Faults),
    Faults \== [],
    !,
    Errors = plan_graph_error{phase:spec_compat, kind:spec_compat,
                              detail:Faults}.

d6_compat_checks(Graph, Frozen, Env, Faults) :-
    d6_compat_foreign_refs(Graph, Frozen, Faults0),
    d6_compat_obligations(Graph, Frozen, Faults1),
    d6_compat_forbidden(Graph, Frozen, Faults2),
    d6_compat_dangling(Graph, Env, Faults3),
    d6_compat_spec_inputs(Frozen, Env, Faults4),
    append([Faults0, Faults1, Faults2, Faults3, Faults4], Faults).

d6_compat_foreign_refs(Graph, Frozen, Faults) :-
    get_dict(steps, Graph, Steps),
    get_dict(ref, Frozen, FrozenRef),
    get_dict(fingerprint, FrozenRef, ExpectedFingerprint),
    findall(foreign_spec_reference(StepId),
            (   member(Step, Steps),
                get_dict(id, Step, StepId),
                get_dict(op, Step, validate),
                get_dict(args, Step, validate(spec(fingerprint(F)))),
                F \== ExpectedFingerprint
            ),
            Faults).

d6_compat_obligations(Graph, Frozen, Faults) :-
    get_dict(requirements, Frozen, Requirements),
    get_dict(obligations, Graph, Obligations),
    get_dict(steps, Graph, Steps),
    get_dict(deps, Graph, Deps),
    maplist(d6_dep_pair, Deps, DepPairs),
    get_dict(ref, Frozen, FrozenRef),
    get_dict(fingerprint, FrozenRef, ExpectedFingerprint),
    findall(dropped_obligation(ReqId),
            (   member(Req, Requirements),
                get_dict(severity, Req, required),
                get_dict(id, Req, ReqId),
                get_dict(assertion, Req, ReqAssertion),
                get_dict(kind, ReqAssertion, ReqKind),
                requirement_establishment(ReqKind, plan_established),
                \+ (   member(Obl, Obligations),
                       get_dict(step, Obl, S),
                       get_dict(satisfies, Obl, ReqId),
                       member(Step, Steps),
                       get_dict(id, Step, S),
                       get_dict(op, Step, Op),
                       establishing_op(ReqKind, Op),
                       validate_causally_reaches(S, Steps, DepPairs,
                                                 ExpectedFingerprint)
                   )
            ),
            Faults).

% §9/§11.2: which plan ops can establish a requirement of the given
% assertion kind. tdd_evidence's evidence contract is a code change, so
% only project-writing steps qualify — a run step proves nothing about a
% RED/GREEN pair.
establishing_op(tdd_evidence, edit).
establishing_op(tdd_evidence, create).

% An establishing step satisfies an obligation only when its work is
% causally connected to the verification it feeds: the step must be
% transitively required by a validate/1 step bound to the frozen spec.
validate_causally_reaches(StepId, Steps, DepPairs, Fingerprint) :-
    member(Step, Steps),
    get_dict(id, Step, ValidateId),
    get_dict(op, Step, validate),
    get_dict(args, Step, validate(spec(fingerprint(Fingerprint)))),
    requires_transitively(ValidateId, StepId, DepPairs, [ValidateId]).

requires_transitively(From, Target, DepPairs, Seen) :-
    member(From-Rs, DepPairs),
    member(R, Rs),
    (   R == Target
    ->  true
    ;   \+ memberchk(R, Seen),
        requires_transitively(R, Target, DepPairs, [R|Seen])
    ).

d6_compat_forbidden(Graph, Frozen, Faults) :-
    get_dict(steps, Graph, Steps),
    get_dict(invariants, Frozen, Invariants),
    findall(forbidden_effect_in_plan(StepId, Effect),
            (   member(Step, Steps),
                get_dict(id, Step, StepId),
                get_dict(op, Step, Op),
                get_dict(args, Step, Args),
                member(forbidden_effect(Effect), Invariants),
                d6_step_effects(Op, Args, Effects),
                memberchk(Effect, Effects)
            ),
            Faults).

d6_step_effects(delete, delete(path(P)), [delete(file(P))]).
d6_step_effects(edit, _, [write(project)]).
d6_step_effects(create, create(path(P), _), [write(file(P))]).
d6_step_effects(run, _, [process(run)]).
d6_step_effects(sync_remote, _, [network(git)]).
d6_step_effects(_, _, []).

d6_compat_dangling(Graph, Env, Faults) :-
    get_dict(deps, Graph, Deps),
    get_dict(steps, Graph, Steps),
    get_dict(inputs, Env, EnvInputs),
    maplist(d6_dep_pair, Deps, DepPairs),
    findall(dangling_input(StepId, Name),
            (   member(Step, Steps),
                get_dict(id, Step, StepId),
                get_dict(bind, Step, B),
                get_dict(args, Step, Args),
                d6_expr_inputs(Args, Refs),
                member(Name, Refs),
                \+ d6_resolvable(StepId, B, Name, Steps, DepPairs, EnvInputs)
            ),
            Faults).

% §11 item 7: a required SPEC input declaration must be present in
% Environment.inputs. Period. Whether any step happens to reference the
% name is irrelevant — the reference-based escape hatch is removed.
d6_compat_spec_inputs(Frozen, Env, Faults) :-
    spec_declared_inputs(Frozen, Decls),
    get_dict(inputs, Env, EnvInputs),
    findall(missing_spec_input(Name),
            (   member(Decl, Decls),
                get_dict(name, Decl, Name),
                get_dict(required, Decl, true),
                \+ get_dict(Name, EnvInputs, _)
            ),
            Faults).

spec_declared_inputs(Frozen, Decls) :-
    get_dict(requirements, Frozen, Requirements),
    findall(Decl,
            (   member(Req, Requirements),
                get_dict(assertion, Req, ReqAssertion),
                req_args(ReqAssertion, Args),
                walk_input_decl(Args, Decl)
            ),
            Decls).

req_args(Assertion, Args) :-
    is_dict(Assertion),
    get_dict(args, Assertion, Args).

walk_input_decl(X, Decl) :-
    is_dict(X),
    !,
    (   get_dict(inputs, X, Is)
    ->  member(Decl, Is),
        is_input_decl(Decl)
    ;   dict_pairs(X, _, Pairs),
        member(_-V, Pairs),
        walk_input_decl(V, Decl)
    ).
walk_input_decl(X, Decl) :-
    compound(X),
    !,
    X =.. [_|Args],
    member(A, Args),
    walk_input_decl(A, Decl).

is_input_decl(Decl) :-
    is_dict(Decl),
    dict_keys(Decl, DeclKeys),
    forall(member(K, DeclKeys), memberchk(K, [name, type, required])),
    get_dict(name, Decl, N),
    atom(N), N \== '',
    get_dict(type, Decl, T),
    atom(T),
    get_dict(required, Decl, true).

/* ------------------------------------------------------------------ */
/* edit_action + expert_contract schema checkers (§8)                  */
/* ------------------------------------------------------------------ */

edit_action_ok(Action) :-
    is_dict(Action),
    dict_keys(Action, Keys),
    forall(member(K, Keys), memberchk(K, [target, operation, content,
                                          basis, satisfies])),
    get_dict(target, Action, Target),
    (   Target = ref(symbol_ref(Ref)) -> symbol_ref_dict(Ref)
    ;   Target = span(S) ->
        S = source_span{file:F, start_byte:S0, end_byte:E},
        path_atom(F), integer(S0), integer(E), S0 >= 0, E >= 0, S0 =< E
    ),
    get_dict(operation, Action, Operation),
    memberchk(Operation, [replace, insert_before, insert_after,
                          delete_block]),
    get_dict(content, Action, Content),
    (   Operation == delete_block
    ->  true
    ;   (   atom(Content) ; string(Content) ),
        Content \== '', Content \== none
    ),
    get_dict(basis, Action, Basis),
    (   Basis == none -> true ; d6_diff_side(revision(Basis)) ),
    get_dict(satisfies, Action, Satisfies),
    is_list(Satisfies),
    forall(member(S, Satisfies), atom(S)).

expert_contract_ok(Contract, Env) :-
    is_dict(Contract),
    dict_keys(Contract, Keys),
    forall(member(K, Keys),
           memberchk(K, [op, capabilities, inner_capabilities,
                         input_schema, output_schema, effects,
                         authority_tier, model_policy, budget_policy,
                         completion, failure])),
    get_dict(op, Contract, Op),
    (   atom(Op) -> true ; Op = Name/Arity, atom(Name), integer(Arity) ),
    get_dict(capabilities, Contract, Caps),
    expert_capability_list(Caps),
    % D6-8: inner capabilities are the expert's own inner-loop grants
    % (e.g. model(P) for write experts); they are distinct from the op's
    % own required capability set and validated against the environment at
    % preflight like every other requirement.
    get_dict(inner_capabilities, Contract, InnerCaps),
    expert_capability_list(InnerCaps),
    get_dict(capabilities, Env, EnvCapabilities),
    forall(member(C, Caps), memberchk(C, EnvCapabilities)),
    forall(member(C, InnerCaps), memberchk(C, EnvCapabilities)),
    get_dict(effects, Contract, Effects),
    Effects \== [],
    forall(member(E, Effects),
           memberchk(E, [observation, external_effect, orchestration])),
    get_dict(authority_tier, Contract, Tier),
    memberchk(Tier, [approve_diff, allow_once, allow_session, dangerous]),
    get_dict(model_policy, Contract, MP),
    model_policy_ok(MP),
    get_dict(budget_policy, Contract, BudgetPolicy),
    memberchk(BudgetPolicy, [shared_step_budget]),
    get_dict(completion, Contract, Completion),
    is_list(Completion), Completion \== [],
    forall(member(C, Completion), memberchk(C, [applied_and_observed])),
    get_dict(failure, Contract, Failure),
    is_list(Failure), Failure \== [],
    forall(member(F, Failure), memberchk(F, [blocked, failed])).

expert_capability_list(Caps) :-
    is_list(Caps),
    Caps \== [],
    forall(member(C, Caps), rlm_tool:capability_shape(C)).

model_policy_ok(none) :- !.
model_policy_ok(Policy) :-
    is_dict(Policy),
    dict_keys(Policy, Keys),
    forall(member(K, Keys), memberchk(K, [provider, max_iterations])),
    get_dict(provider, Policy, Provider),
    atom(Provider), Provider \== '',
    get_dict(max_iterations, Policy, MaxIterations),
    integer(MaxIterations),
    MaxIterations > 0.

/* ------------------------------------------------------------------ */
/* Design validators (trusted host assertion argument schemas)          */
/* ------------------------------------------------------------------ */

exact_keys(Dict, Allowed) :-
    is_dict(Dict),
    dict_pairs(Dict, _, Pairs),
    forall(member(K-_, Pairs), memberchk(K, Allowed)),
    forall(member(Req, Allowed), get_dict(Req, Dict, _)).

optional_keys(Dict, Required, Allowed) :-
    is_dict(Dict),
    dict_pairs(Dict, _, Pairs),
    forall(member(K-_, Pairs), memberchk(K, Allowed)),
    forall(member(Req, Required), get_dict(Req, Dict, _)).

record_count_args(Args) :-
    exact_keys(Args, [dataset, minimum]),
    get_dict(minimum, Args, Minimum),
    integer(Minimum),
    Minimum >= 0.

file_language_args(Args) :-
    exact_keys(Args, [path, language]),
    get_dict(path, Args, Path),
    path_atom(Path),
    get_dict(language, Args, Language),
    atom(Language), Language \== ''.

symbol_exists_args(Args) :-
    optional_keys(Args, [symbol], [symbol, occurrence]),
    get_dict(symbol, Args, Symbol),
    symbol_ref_dict(Symbol),
    (   get_dict(occurrence, Args, Occ) ->
        memberchk(Occ, [definition, reference, any])
    ;   true
    ).

symbol_arity_args(Args) :-
    exact_keys(Args, [symbol, arity]),
    get_dict(symbol, Args, Symbol),
    symbol_ref_dict(Symbol),
    get_dict(arity, Args, Arity),
    integer(Arity),
    Arity >= 0.

build_ok_args(Args) :-
    optional_keys(Args, [target, toolchain],
                  [target, toolchain, configuration, artifact, warnings,
                   exit_status]),
    get_dict(target, Args, Target),
    (   Target == all ; atom(Target) ),
    get_dict(toolchain, Args, Toolchain),
    toolchain_ref(Toolchain),
    (   get_dict(configuration, Args, C) -> atom(C) ; true ),
    (   get_dict(artifact, Args, A) -> artifact_contract(A) ; true ),
    (   get_dict(warnings, Args, W) ->
        (   W == any ; W == none
        ;   W = below(N), integer(N), N >= 0
        )
    ;   true
    ),
    (   get_dict(exit_status, Args, E) -> integer(E) ; true ).

toolchain_ref(T) :-
    is_dict(T),
    dict_pairs(T, _, Pairs),
    forall(member(K-_, Pairs), memberchk(K, [kind, version_constraint])),
    get_dict(kind, T, Kind), atom(Kind), Kind \== '',
    (   get_dict(version_constraint, T, VC) -> version_constraint_ok(VC)
    ;   true
    ).

version_constraint_ok(VC) :-
    is_dict(VC),
    dict_pairs(VC, _, Pairs),
    forall(member(K-V, Pairs),
           (   memberchk(K, [min, max, exact]),
               semver_ok(V)
           )).

semver_ok(S) :-
    (   atom(S) ; string(S) ),
    atom_string(S, Str),
    split_string(Str, ".", "", [Maj, Min, Patch]),
    maplist(numeric_string, [Maj, Min, Patch]).

numeric_string(S) :-
    S \== "",
    string_codes(S, Codes),
    Codes \== [],
    forall(member(C, Codes), char_type(C, digit)).

artifact_contract(A) :-
    is_dict(A),
    dict_pairs(A, _, Pairs),
    forall(member(K-_, Pairs), memberchk(K, [id, kind, path])),
    get_dict(id, A, Id), atom(Id), Id \== '',
    get_dict(kind, A, Kind),
    memberchk(Kind, [executable, library, archive, image, report,
                     document]),
    (   get_dict(path, A, P) -> path_atom(P) ; true ).

test_passes_args(Args) :-
    exact_keys(Args, [scope]),
    get_dict(scope, Args, Scope),
    (   Scope == all
    ;   Scope = suite(S), atom(S), S \== ''
    ;   Scope = test(T), test_ref(T)
    ).

test_exists_args(Args) :-
    exact_keys(Args, [test, kind]),
    get_dict(test, Args, Test),
    test_ref(Test),
    get_dict(kind, Args, Kind),
    memberchk(Kind, [unit, integration, property, regression]).

behavior_tested_args(Args) :-
    exact_keys(Args, [symbol, test]),
    get_dict(symbol, Args, Symbol),
    symbol_ref_dict(Symbol),
    get_dict(test, Args, Test),
    test_ref(Test).

test_ref(T) :-
    (   is_dict(T)
    ->  dict_pairs(T, _, Pairs),
        forall(member(K-_, Pairs), memberchk(K, [suite, id])),
        get_dict(suite, T, S), atom(S), S \== '',
        get_dict(id, T, I), atom(I), I \== ''
    ;   T = path(P), path_atom(P)
    ).

tdd_evidence_args(Args) :-
    exact_keys(Args, [requirement, test, pre_revision, post_revision]),
    get_dict(requirement, Args, Requirement),
    atom(Requirement), Requirement \== '',
    get_dict(test, Args, Test),
    test_ref(Test),
    get_dict(pre_revision, Args, Pre),
    revision_ref(Pre),
    get_dict(post_revision, Args, Post),
    revision_ref(Post).

revision_ref(head).
revision_ref(working).
revision_ref(committed(A)) :- atom(A), A \== ''.
revision_ref(branch(A)) :- atom(A), A \== ''.
revision_ref(remote(A, B)) :- atom(A), atom(B).

public_api_args(Args) :-
    optional_keys(Args, [baseline, policy], [baseline, policy, scope]),
    get_dict(baseline, Args, Baseline),
    revision_ref(Baseline),
    get_dict(policy, Args, Policy),
    memberchk(Policy, [allow_additions, no_additions]),
    (   get_dict(scope, Args, S) -> is_list(S) ; true ).

http_endpoint_args(Args) :-
    exact_keys(Args, [service, request, responses]),
    get_dict(service, Args, Service),
    atom(Service), Service \== '',
    get_dict(request, Args, Request),
    http_request_ok(Request),
    get_dict(responses, Args, Responses),
    is_list(Responses),
    Responses \== [],
    maplist(http_response_ok(Request), Responses),
    scenarios_unique(Responses).

scenarios_unique(Responses) :-
    maplist(arg_scenario, Responses, Scenarios),
    sort(Scenarios, UniqueScenarios),
    length(Scenarios, N),
    length(UniqueScenarios, N),
    length(Responses, N).

arg_scenario(R, S) :- get_dict(scenario, R, S).

http_method_ok(get). http_method_ok(post). http_method_ok(put).
http_method_ok(patch). http_method_ok(delete). http_method_ok(head).
http_method_ok(options).

param_type_ok(integer). param_type_ok(string). param_type_ok(uuid).
param_type_ok(boolean). param_type_ok(json).

http_request_ok(Req) :-
    optional_keys(Req, [method, path],
                  [method, path, path_params, query, headers, content_type,
                   accept, body, auth, inputs, fixtures, idempotency]),
    get_dict(method, Req, Method),
    http_method_ok(Method),
    get_dict(path, Req, ReqPath),
    (   atom(ReqPath) ; string(ReqPath) ),
    (   get_dict(path_params, Req, PP) ->
        (   is_dict(PP), PP \== {}
        ->  dict_pairs(PP, _, PPPairs),
            forall(member(K-T, PPPairs),
                   (   path_template_name(K, ReqPath),
                       param_type_ok(T)
                   ))
        ;   throw(design_validator_fault(path_params_must_match_templates))
        )
    ;   true
    ),
    (   get_dict(query, Req, Q) ->
        is_list(Q),
        forall(member(QP, Q),
               (   is_dict(QP),
                   dict_pairs(QP, _, QPairs),
                   forall(member(K-_, QPairs),
                          memberchk(K, [name, type, required])),
                   get_dict(name, QP, N), atom(N),
                   get_dict(type, QP, T), param_type_ok(T),
                   get_dict(required, QP, R), memberchk(R, [true, false])
               ))
    ;   true
    ),
    (   get_dict(headers, Req, Hs) ->
        is_list(Hs), maplist(header_ok, Hs)
    ;   true
    ),
    (   get_dict(content_type, Req, CT) -> media_type(CT) ; true ),
    (   get_dict(accept, Req, As) -> is_list(As), maplist(media_type, As)
    ;   true
    ),
    (   get_dict(body, Req, B) -> body_contract(B) ; true ),
    (   get_dict(auth, Req, A) ->
        (   A == none -> true
        ;   is_dict(A),
            dict_pairs(A, _, APairs),
            forall(member(K-_, APairs), memberchk(K, [scheme, scope])),
            get_dict(scheme, A, Scheme),
            memberchk(Scheme, [bearer, basic, api_key, none]),
            (   get_dict(scope, A, Sc) -> atom(Sc) ; true )
        )
    ;   true
    ),
    (   get_dict(inputs, Req, Is) ->
        is_list(Is),
        forall(member(D, Is),
               (   is_dict(D),
                   dict_pairs(D, _, DPairs),
                   forall(member(K-_, DPairs),
                          memberchk(K, [name, type, required])),
                   get_dict(name, D, N), atom(N),
                   get_dict(type, D, T), param_type_ok(T),
                   get_dict(required, D, R), memberchk(R, [true, false])
               ))
    ;   true
    ),
    (   get_dict(fixtures, Req, F) -> is_dict(F) ; true ),
    (   get_dict(idempotency, Req, I) -> memberchk(I, [none, required])
    ;   true
    ),
    request_binding_ok(Req).

% Succeeds when {Name} occurs as a path template inside Path — embedded
% ("/users/{id}") or a whole-path template ("/{id}") — with a non-empty
% alphanumeric name. A declared path_param without a matching {Name}
% occurrence fails.
path_template_name(Name, Path) :-
    (   atom(Path) -> atom_codes(Path, Codes) ; string_codes(Path, Codes) ),
    template_occurrence(Codes, NameCodes),
    NameCodes \== [],
    atom_codes(Name, NameCodes),
    forall(member(C, NameCodes), char_type(C, alnum)).

% Open is a suffix of Codes starting at some '{'; the template closes at
% the next '}' with NameCodes in between. (Code-char lists: SWI strings
% are not lists.)
template_occurrence(Codes, NameCodes) :-
    append(_Pre, Open, Codes),
    append([0'{|NameCodes], [0'}], Open).

request_binding_ok(Req) :-
    (   get_dict(body, Req, B), is_dict(B),
        get_dict(ref, B, input(N))
    ->  declared_input(Req, N)
    ;   true
    ).

declared_input(Req, N) :-
    get_dict(inputs, Req, Decls),
    member(input_decl{name:N, type:_, required:_}, Decls).

body_contract(B) :-
    is_dict(B),
    dict_pairs(B, _, Pairs),
    forall(member(K-_, Pairs), memberchk(K, [type, schema, schema_ref,
                                             ref])),
    get_dict(type, B, T),
    memberchk(T, [json, form, text]),
    (   memberchk(T, [json, form])
    ->  (   get_dict(schema, B, S) -> schema_ok(S)
        ;   get_dict(schema_ref, B, R) -> atom(R), R \== ''
        ;   throw(design_validator_fault(body_schema_required(T)))
        )
    ;   true
    ),
    (   get_dict(ref, B, input(N)) -> atom(N) ; true ).

schema_ok(S) :-
    is_dict(S),
    dict_pairs(S, _, Pairs),
    forall(member(K-_, Pairs),
           memberchk(K, [type, properties, required, items, enum,
                         minimum, maximum, min_length, max_length])),
    get_dict(type, S, T),
    memberchk(T, [object, array, string, integer, number, boolean, null]),
    (   get_dict(properties, S, Ps) ->
        is_dict(Ps),
        dict_pairs(Ps, _, PPairs),
        forall(member(_-Sub, PPairs), schema_ok(Sub))
    ;   true
    ),
    (   get_dict(required, S, R) ->
        is_list(R), forall(member(X, R), atom(X))
    ;   true
    ),
    (   get_dict(items, S, I) -> schema_ok(I) ; true ),
    (   get_dict(enum, S, E) -> is_list(E), E \== [] ; true ),
    (   get_dict(minimum, S, V) -> number(V) ; true ),
    (   get_dict(maximum, S, V) -> number(V) ; true ),
    (   get_dict(min_length, S, V) -> integer(V), V >= 0 ; true ),
    (   get_dict(max_length, S, V) -> integer(V), V >= 0 ; true ).

header_ok(H) :-
    is_dict(H),
    dict_pairs(H, _, Pairs),
    forall(member(K-_, Pairs), memberchk(K, [name, value, forbidden])),
    get_dict(name, H, N),
    atom(N), N \== '',
    atom_codes(N, Codes),
    Codes \== [],
    forall(member(C, Codes), char_type(C, lower)),
    (   get_dict(forbidden, H, true) -> \+ get_dict(value, H, _)
    ;   \+ get_dict(forbidden, H, _)
    ).

media_type(M) :- atom(M), M \== ''.
media_type(M) :- string(M), M \== "".

http_response_ok(Req, R) :-
    optional_keys(R, [scenario, status],
                  [scenario, status, headers, body, location, cache,
                   pagination]),
    get_dict(scenario, R, Scenario),
    memberchk(Scenario, [valid_request, invalid_body, unauthenticated,
                         forbidden, missing_resource, conflict,
                         rate_limited, server_error]),
    get_dict(status, R, Status),
    (   integer(Status), Status >= 100, Status =< 599
    ;   Status = class(C), memberchk(C, ['1xx', '2xx', '3xx', '4xx', '5xx'])
    ),
    (   get_dict(headers, R, Hs) -> is_list(Hs), maplist(header_ok, Hs)
    ;   true
    ),
    (   get_dict(body, R, B) ->
        (   B == none -> true ; body_contract(B) )
    ;   true
    ),
    (   get_dict(location, R, L) -> ( atom(L) ; string(L) ) ; true ),
    (   get_dict(cache, R, C) ->
        (   memberchk(C, [no_store, no_cache])
        ;   C = max_age(N), integer(N), N >= 0
        )
    ;   true
    ),
    (   get_dict(pagination, R, P) ->
        is_dict(P),
        dict_pairs(P, _, PPairs),
        forall(member(K-_, PPairs), memberchk(K, [kind, fields])),
        get_dict(kind, P, K),
        memberchk(K, [cursor, page_number]),
        get_dict(fields, P, Fs), is_list(Fs)
    ;   true
    ),
    scenario_derivable(Scenario, Req, R).

scenario_derivable(invalid_body, Req, _) :- !,
    request_has_body_schema(Req).
scenario_derivable(unauthenticated, Req, _) :- !,
    request_auth(Req, Scheme),
    Scheme \== none.
scenario_derivable(forbidden, Req, _) :- !,
    request_auth(Req, Scheme),
    Scheme \== none,
    get_dict(auth, Req, A),
    get_dict(scope, A, Scope),
    atom(Scope), Scope \== ''.
scenario_derivable(conflict, Req, _) :- !,
    get_dict(idempotency, Req, required).
scenario_derivable(missing_resource, Req, _) :- !,
    get_dict(path_params, Req, PP),
    is_dict(PP), PP \== {}.
scenario_derivable(_, _, _).

request_has_body_schema(Req) :-
    get_dict(body, Req, B),
    is_dict(B),
    (   get_dict(schema, B, S) -> is_dict(S)
    ;   get_dict(schema_ref, B, _) -> true
    ;   fail
    ).

request_auth(Req, Scheme) :-
    get_dict(auth, Req, A),
    is_dict(A),
    get_dict(scheme, A, Scheme).

/* ------------------------------------------------------------------ */
/* Design evaluators (pure)                                            */
/* ------------------------------------------------------------------ */

count_evaluator(Assertion, Obs, passed) :-
    is_dict(Assertion),
    get_dict(kind, Assertion, record_count),
    get_dict(args, Assertion, CountArgs),
    get_dict(minimum, CountArgs, Min),
    is_dict(Obs),
    get_dict(value, Obs, ObsValue),
    is_dict(ObsValue),
    !,
    get_dict(count, ObsValue, Count),
    integer(Count), Count >= Min.
count_evaluator(_, _, failed).

language_evaluator(_, _, passed).
symbol_evaluator(_, _, passed).
build_evaluator(_, _, passed).
test_evaluator(_, _, passed).
api_evaluator(_, _, passed).
http_evaluator(_, _, passed).

% tdd_evidence (§9): passed iff RED failed AND GREEN passed with the same
% test identity; a pre-change pass is evidence_not_red, never a silent pass.
tdd_evidence_evaluator(Assertion, Obs, passed) :-
    is_dict(Assertion),
    get_dict(kind, Assertion, tdd_evidence),
    get_dict(args, Assertion, TddArgs),
    get_dict(test, TddArgs, Test),
    is_dict(Obs),
    get_dict(value, Obs, ObsValue),
    is_dict(ObsValue),
    get_dict(red, ObsValue, Red),
    get_dict(green, ObsValue, Green),
    is_dict(Red),
    is_dict(Green),
    get_dict(status, Red, failed),
    get_dict(status, Green, passed),
    get_dict(test, ObsValue, ObsTest),
    tdd_test_id(Test, Id),
    tdd_test_id(ObsTest, Id),
    !.
tdd_evidence_evaluator(Assertion, Obs,
                       indeterminate(evidence_not_red)) :-
    is_dict(Assertion),
    get_dict(kind, Assertion, tdd_evidence),
    is_dict(Obs),
    get_dict(value, Obs, ObsValue),
    is_dict(ObsValue),
    get_dict(red, ObsValue, Red),
    is_dict(Red),
    get_dict(status, Red, passed),
    !.
tdd_evidence_evaluator(Assertion, Obs, failed) :-
    is_dict(Assertion),
    get_dict(kind, Assertion, tdd_evidence),
    is_dict(Obs),
    get_dict(value, Obs, ObsValue),
    is_dict(ObsValue),
    get_dict(green, ObsValue, Green),
    is_dict(Green),
    get_dict(status, Green, failed),
    !.
tdd_evidence_evaluator(Assertion, _,
                       indeterminate(incomplete_tdd_evidence)) :-
    is_dict(Assertion),
    get_dict(kind, Assertion, tdd_evidence).

tdd_test_id(T, suite:S:I) :-
    is_dict(T),
    get_dict(suite, T, S),
    get_dict(id, T, I),
    !.
tdd_test_id(path(P), path:P).

require_list(V, _) :- is_list(V), !.
require_list(V, Name) :-
    throw(gate_fault(d6_invalid_list(Name, V))).

% Groundness that tolerates anonymous dict tags (SWI dict tags written `_`
% are fresh variables, so plain ground/1 rejects valid closed data).
d6_ground(V) :- var(V), !, fail.
d6_ground(V) :- is_dict(V), !,
    dict_pairs(V, _, Pairs),
    forall(member(_-X, Pairs), d6_ground(X)).
d6_ground(V) :- atomic(V), !.
d6_ground([H|T]) :- !, d6_ground(H), d6_ground(T).
d6_ground(V) :- compound(V), !,
    V =.. [_|A],
    maplist(d6_ground, A).
