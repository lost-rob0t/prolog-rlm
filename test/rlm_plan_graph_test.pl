:- begin_tests(rlm_plan_graph).

:- use_module('../prolog/rlm_plan_graph').
:- use_module('../prolog/rlm_async', []).

/* Fixtures ------------------------------------------------------------ */

:- use_module('support/plan_graph_test_tools').

all_caps([tool(index), tool(locate), tool(read), tool(search), tool(diff),
          tool(edit), tool(create), tool(delete), tool(run),
          tool(sync_remote), tool(validate), tool(spawn_agent)]).

simple_experts([expert(index, plan_graph_test_tools:index_handler),
                expert(read, plan_graph_test_tools:read_handler),
                expert(search, plan_graph_test_tools:search_handler)]).

run_options([experts([expert(index, plan_graph_test_tools:index_handler),
                      expert(read, plan_graph_test_tools:read_handler),
                      expert(search, plan_graph_test_tools:search_handler)])]).

fixture_index(symbol_index{kinds:[function],
                           definitions:[symbol_definition(symbol_ref{name:foo,
                                                                      kind:function,
                                                                      occurrence:definition},
                                                          source_span{file:'src/foo.py',
                                                                      start_byte:10,
                                                                      end_byte:20},
                                                          provenance{source:fixture}),
                                        symbol_definition(symbol_ref{name:bar,
                                                                     kind:function,
                                                                     occurrence:definition},
                                                          source_span{file:'src/x.py',
                                                                      start_byte:1,
                                                                      end_byte:2},
                                                          provenance{source:fixture}),
                                        symbol_definition(symbol_ref{name:dup,
                                                                     kind:function,
                                                                     occurrence:definition},
                                                          source_span{file:'src/a.py',
                                                                      start_byte:1,
                                                                      end_byte:2},
                                                          provenance{source:fixture}),
                                        symbol_definition(symbol_ref{name:dup,
                                                                     kind:function,
                                                                     occurrence:definition},
                                                          source_span{file:'src/b.py',
                                                                      start_byte:3,
                                                                      end_byte:4},
                                                          provenance{source:fixture})]}).

/* Parse tests ---------------------------------------------------------- */

normalized(JsonOrTerm, Graph) :-
    plan_graph_parse(JsonOrTerm, ok(Graph)).

test(parses_model_json) :-
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"idx\"},{\"id\":\"s2\",\"op\":\"locate\",\"args\":{\"symbol\":{\"name\":\"foo\",\"kind\":\"function\",\"occurrence\":\"definition\"}},\"bind\":\"span\"}],\"depends_on\":[{\"step\":\"s2\",\"requires\":[\"s1\"]}]}",
    plan_graph_parse(Json, ok(Graph)),
    is_dict(Graph),
    Graph.steps = [S1, S2],
    assertion(S1.id == s1),
    assertion(S1.op == index/1),
    assertion(S1.args == index(scope(all))),
    assertion(S1.bind == idx),
    assertion(S2.op == locate/1),
    assertion(S2.args == locate(symbol_ref(symbol_ref{name:foo,
                                                      kind:function,
                                                      occurrence:definition}))),
    assertion(Graph.edges == [graph_edge{step:s2, requires:[s1]}]),
    assertion(S2.requires == [s1]).

test(parses_term_form) :-
    Term = plan_graph(steps([step(s1, index, index(scope(all)), idx),
                             step(s2, read, read(path('a.py')), body)]),
                      depends_on([depends_on(s2, [s1])])),
    plan_graph_parse(Term, ok(Graph)),
    Steps = Graph.steps,
    Edges = Graph.edges,
    assertion(length(Steps, 2)),
    assertion(Edges == [graph_edge{step:s2, requires:[s1]}]),
    Steps = [_, S2],
    assertion(S2.op == read/1),
    assertion(S2.args == read(path('a.py'))).

/* Validation rejection tests ------------------------------------------- */




test(rejects_unknown_op) :-
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"frobnicate\",\"args\":{},\"bind\":\"x\"}]}",
    normalized(Json, Graph),
    all_caps(Caps),
    plan_graph_validate(Graph, Caps, default, Outcome),
    Outcome = error(Error),
    assertion(Error.phase == vocabulary),
    assertion(Error.kind == unknown_op).

test(vocabulary_validated_before_desugar) :-
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"shell\",\"args\":{\"command\":\"id\"},\"bind\":\"x\"}]}",
    normalized(Json, Graph),
    all_caps(Caps),
    plan_graph_validate(Graph, Caps, default, Outcome),
    Outcome = error(Error),
    assertion(Error.phase == vocabulary),
    assertion(Error.kind == unknown_op),
    assertion(Error.detail == op(shell/1)).

test(rejects_unknown_dependency) :-
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"a\"}],\"depends_on\":[{\"step\":\"s1\",\"requires\":[\"nope\"]}]}",
    normalized(Json, Graph),
    all_caps(Caps),
    plan_graph_validate(Graph, Caps, default, Outcome),
    Outcome = error(Error),
    assertion(Error.phase == structure),
    assertion(Error.kind == unknown_dependency).

test(rejects_cycle) :-
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"a\"},{\"id\":\"s2\",\"op\":\"read\",\"args\":{\"source\":{\"path\":\"x\"}},\"bind\":\"b\"}],\"depends_on\":[{\"step\":\"s1\",\"requires\":[\"s2\"]},{\"step\":\"s2\",\"requires\":[\"s1\"]}]}",
    normalized(Json, Graph),
    all_caps(Caps),
    plan_graph_validate(Graph, Caps, default, Outcome),
    Outcome = error(Error),
    assertion(Error.phase == structure),
    assertion(Error.kind == cycle).

test(rejects_duplicate_step_id) :-
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"a\"},{\"id\":\"s1\",\"op\":\"read\",\"args\":{\"source\":{\"path\":\"x\"}},\"bind\":\"b\"}]}",
    normalized(Json, Graph),
    all_caps(Caps),
    plan_graph_validate(Graph, Caps, default, Outcome),
    Outcome = error(Error),
    assertion(Error.kind == duplicate_step_id).

test(budget_bounds_step_count) :-
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"a\"},{\"id\":\"s2\",\"op\":\"read\",\"args\":{\"source\":{\"path\":\"x\"}},\"bind\":\"b\"},{\"id\":\"s3\",\"op\":\"search\",\"args\":{\"pattern\":\"p\",\"scope\":\"all\"},\"bind\":\"c\"}]}",
    normalized(Json, Graph),
    all_caps(Caps),
    Budget = graph_budget{max_steps:2},
    plan_graph_validate(Graph, Caps, Budget, Outcome),
    Outcome = error(Error),
    assertion(Error.phase == budget),
    assertion(Error.kind == budget_exceeded).

test(capability_denied_per_op) :-
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"a\"}]}",
    normalized(Json, Graph),
    plan_graph_validate(Graph, [tool(read)], default, CapOutcome),
    CapOutcome = error(Error),
    assertion(Error.phase == capability),
    assertion(Error.kind == capability_denied).

/* Scheduling tests ------------------------------------------------------ */

state0(graph_state{status:_{}, results:_{}, sequence:[]}).

mark(State0, Id, Status, State) :-
    Statuses = State0.status,
    put_dict(Id, Statuses, Status, NewStatuses),
    put_dict(status, State0, NewStatuses, State).

test(ready_step_admits_only_dependency_complete) :-
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"a\"},{\"id\":\"s2\",\"op\":\"read\",\"args\":{\"source\":{\"path\":\"x\"}},\"bind\":\"b\"},{\"id\":\"s3\",\"op\":\"search\",\"args\":{\"pattern\":\"p\",\"scope\":\"all\"},\"bind\":\"c\"}],\"depends_on\":[{\"step\":\"s3\",\"requires\":[\"s2\"]}]}",
    normalized(Json, Graph),
    state0(Empty),
    mark(Empty, s1, completed, St1),
    findall(Step, plan_graph_ready(Graph, St1, Step), Ready1),
    assertion(Ready1 == [s2]),
    mark(St1, s2, completed, St2),
    findall(Step, plan_graph_ready(Graph, St2, Step), Ready2),
    assertion(Ready2 == [s3]).

test(executes_in_topological_order) :-
    plan_graph_test_tools:reset_calls,
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"a\"},{\"id\":\"s2\",\"op\":\"read\",\"args\":{\"source\":{\"path\":\"x\"}},\"bind\":\"b\"},{\"id\":\"s3\",\"op\":\"search\",\"args\":{\"pattern\":\"p\",\"scope\":\"all\"},\"bind\":\"c\"},{\"id\":\"s4\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"d\"}],\"depends_on\":[{\"step\":\"s2\",\"requires\":[\"s1\"]},{\"step\":\"s3\",\"requires\":[\"s1\"]},{\"step\":\"s4\",\"requires\":[\"s2\",\"s3\"]}]}",
    all_caps(Caps),
    run_options(Options),
    plan_graph_run(Json, Caps, Options, inputs{}, RunOutcome),
    RunOutcome = ok(Result),
    assertion(Result.status == completed),
    findall(Name, plan_graph_test_tools:expert_call(Name, _), Calls),
    assertion(Calls == [index, read, search, index]).

test(blocks_dependents_on_failure) :-
    plan_graph_test_tools:reset_calls,
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"read\",\"args\":{\"source\":{\"path\":\"x\"}},\"bind\":\"a\"},{\"id\":\"s2\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"b\"},{\"id\":\"s3\",\"op\":\"search\",\"args\":{\"pattern\":\"p\",\"scope\":\"all\"},\"bind\":\"c\"}],\"depends_on\":[{\"step\":\"s2\",\"requires\":[\"s1\"]},{\"step\":\"s3\",\"requires\":[\"s2\"]}]}",
    all_caps(Caps),
    Experts = [expert(read, plan_graph_test_tools:fail_handler),
               expert(index, plan_graph_test_tools:index_handler),
               expert(search, plan_graph_test_tools:search_handler)],
    plan_graph_run(Json, Caps, [experts(Experts)], inputs{}, RunOutcome),
    RunOutcome = ok(Result),
    BlockState = Result.state,
    assertion(Result.status == failed),
    get_dict(status, BlockState, Statuses),
    get_dict(s1, Statuses, S1Status),
    get_dict(s2, Statuses, S2Status),
    get_dict(s3, Statuses, S3Status),
    assertion(S1Status == failed),
    assertion(S2Status == blocked),
    assertion(S3Status == blocked),
    findall(Name, plan_graph_test_tools:expert_call(Name, _), Calls),
    assertion(Calls == [read]).

/* Cancellation ---------------------------------------------------------- */

test(cancellation_aborts_graph_and_rethrows_token) :-
    plan_graph_test_tools:reset_calls,
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"sync_remote\",\"args\":{\"op\":\"fetch\"},\"bind\":\"a\"},{\"id\":\"s2\",\"op\":\"read\",\"args\":{\"source\":{\"path\":\"x\"}},\"bind\":\"b\"}]}",
    all_caps(Caps),
    Experts = [expert(sync_remote, plan_graph_test_tools:cancel_handler),
               expert(index, plan_graph_test_tools:index_handler),
               expert(read, plan_graph_test_tools:read_handler)],
    catch(plan_graph_run(Json, Caps, [experts(Experts)], inputs{}, _Outcome),
          error(rlm_cancelled(Token), _Context),
          true),
    (   var(Token)
    ->  Token = no_throw
    ;   true
    ),
    assertion(Token == tok123),
    findall(Name, plan_graph_test_tools:expert_call(Name, _), Calls),
    assertion(Calls == [sync_remote]).

/* Aggregate budget ------------------------------------------------------ */

test(aggregate_budget_enforced_across_steps) :-
    plan_graph_test_tools:reset_calls,
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"a\"},{\"id\":\"s2\",\"op\":\"read\",\"args\":{\"source\":{\"path\":\"x\"}},\"bind\":\"b\"}]}",
    all_caps(Caps),
    run_options(Options),
    Budget = graph_budget{max_total_output_bytes:1},
    plan_graph_run(Json, Caps, [budget(Budget)|Options], inputs{}, RunOutcome),
    RunOutcome = ok(Result),
    AbortState = Result.state,
    assertion(Result.status == aborted),
    assertion(Result.reason == budget),
    get_dict(status, AbortState, Statuses),
    get_dict(s2, Statuses, S2),
    assertion(S2 == abandoned).

/* Expert registry ------------------------------------------------------- */

test(unknown_expert_fails_preflight) :-
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"a\"}]}",
    all_caps(Caps),
    plan_graph_run(Json, Caps, [experts([])], inputs{}, error(Error)),
    assertion(Error.phase == preflight),
    assertion(Error.kind == unknown_expert).

/* validate step ---------------------------------------------------------- */

test(validate_step_uses_host_verifier) :-
    plan_graph_test_tools:reset_calls,
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"validate\",\"args\":{\"spec\":{\"fingerprint\":\"fp001\"}},\"bind\":\"v\"}]}",
    all_caps(Caps),
    Experts = [expert(validate, plan_graph_test_tools:verifier_handler),
               expert(index, plan_graph_test_tools:index_handler)],
    plan_graph_run(Json, Caps, [experts(Experts)], inputs{}, RunOutcome),
    RunOutcome = ok(Result),
    assertion(Result.status == completed),
    plan_graph_test_tools:expert_call(validate, Args),
    assertion(Args == validate(spec(fingerprint(fp001)))).

/* delegate --------------------------------------------------------------- */

test(delegate_narrows_capabilities) :-
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"delegate\",\"args\":{\"task\":\"sub\",\"caps\":[\"tool(read)\"]},\"bind\":\"c\"}]}",
    normalized(Json, Graph),
    all_caps(Caps),
    plan_graph_validate(Graph, Caps, default, DelegateOutcome),
    DelegateOutcome = ok(Validated),
    Steps = Validated.graph.steps,
    nth0(0, Steps, VStep),
    assertion(VStep.args == delegate(task(sub), caps([tool(read)]))),
    Term = plan_graph(steps([step(s1, delegate,
                                  delegate(task(sub),
                                          caps([tool(network(evil))])),
                                  c)])),
    normalized(Term, Graph2),
    plan_graph_validate(Graph2, Caps, default, Outcome2),
    Outcome2 = error(Error),
    assertion(Error.phase == capability),
    assertion(Error.kind == capability_denied).

/* Resolver --------------------------------------------------------------- */

test(resolver_unresolved) :-
    fixture_index(Index),
    Ref = symbol_ref{name:missing, kind:function},
    plan_graph_resolve_symbol(Index, Ref, error(Error)),
    assertion(Error.kind == unresolved).

test(resolver_ambiguous) :-
    fixture_index(Index),
    Ref = symbol_ref{name:dup, kind:function},
    plan_graph_resolve_symbol(Index, Ref, error(Error)),
    assertion(Error.kind == ambiguous).

test(resolver_unsupported) :-
    fixture_index(Index),
    Ref = symbol_ref{name:foo, kind:macro},
    plan_graph_resolve_symbol(Index, Ref, error(Error)),
    assertion(Error.kind == unsupported).

test(resolver_matches_subset_keys) :-
    fixture_index(Index),
    Ref = symbol_ref{name:foo, kind:function},
    plan_graph_resolve_symbol(Index, Ref, ok(Binding)),
    assertion(Binding.span == source_span{file:'src/foo.py',
                                          start_byte:10,
                                          end_byte:20}).

/* Structural validators --------------------------------------------------- */

test(symbol_ref_rejects_malformed) :-
    \+ plan_graph_symbol_ref_valid(symbol_ref{name:17, kind:function}),
    \+ plan_graph_symbol_ref_valid(symbol_ref{kind:function}),
    \+ plan_graph_symbol_ref_valid(symbol_ref{name:foo,
                                              kind:function,
                                              bogus:1}),
    \+ plan_graph_symbol_ref_valid(symbol_ref{name:foo,
                                              kind:function,
                                              occurrence:sometimes}).

test(source_span_rejects_inverted_bytes) :-
    plan_graph_source_span_valid(source_span{file:'a.py',
                                             start_byte:5,
                                             end_byte:9}),
    \+ plan_graph_source_span_valid(source_span{file:'a.py',
                                                start_byte:9,
                                                end_byte:5}),
    \+ plan_graph_source_span_valid(source_span{file:'a.py',
                                                start_byte: -1,
                                                end_byte:5}).

/* Async / sync parity ------------------------------------------------------ */

test(run_async_awaits_same_future_as_run) :-
    plan_graph_test_tools:reset_calls,
    Json = "{\"steps\":[{\"id\":\"s1\",\"op\":\"index\",\"args\":{\"scope\":\"all\"},\"bind\":\"a\"}]}",
    all_caps(Caps),
    run_options(Options),
    plan_graph_run(Json, Caps, Options, inputs{}, SyncOutcome),
    plan_graph_run_async(Json, Caps, Options, Future),
    rlm_async:rlm_future_await(Future, AsyncOutcome),
    assertion(SyncOutcome == AsyncOutcome),
    assertion(AsyncOutcome = ok(_)).

:- end_tests(rlm_plan_graph).

