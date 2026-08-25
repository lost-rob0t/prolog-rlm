from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


def append_once(path, marker, text):
    p = Path(path)
    current = p.read_text()
    if marker in current:
        return
    p.write_text(current.rstrip() + "\n\n" + text.rstrip() + "\n")


# ---------------------------------------------------------------------------
# Completion runtime: carry closed host reasoning policy into planner/direct
# requests and enforce it across model steps in nested symbolic plans.
# ---------------------------------------------------------------------------

replace_once(
    "prolog/rlm_completion.pl",
    """    bound_plan_model_tokens(Planner.plan,\n                            PlanModelCalls,\n                            RemainingTokens,\n                            BoundedPlan),\n""",
    """    bound_plan_model_tokens(Planner.plan,\n                            PlanModelCalls,\n                            RemainingTokens,\n                            TokenBoundedPlan),\n    enforce_plan_reasoning_options(Options,\n                                   TokenBoundedPlan,\n                                   BoundedPlan),\n""",
)

replace_once(
    "prolog/rlm_completion.pl",
    """planner_request_options(Options, TokenLimit, RequestOptions) :-\n    option_value(planner_temperature, Options, 0, Temperature),\n    RequestOptions = _{max_tokens:TokenLimit, temperature:Temperature}.\n\nmodel_request_options(Options, TokenLimit, RequestOptions) :-\n    option_value(temperature, Options, 0, Temperature),\n    RequestOptions = _{max_tokens:TokenLimit, temperature:Temperature}.\n""",
    """planner_request_options(Options, TokenLimit, RequestOptions) :-\n    option_value(planner_temperature, Options, 0, Temperature),\n    Base = _{max_tokens:TokenLimit, temperature:Temperature},\n    planner_reasoning_effort(Options, Effort),\n    request_options_reasoning(Effort, Base, RequestOptions).\n\nmodel_request_options(Options, TokenLimit, RequestOptions) :-\n    option_value(temperature, Options, 0, Temperature),\n    Base = _{max_tokens:TokenLimit, temperature:Temperature},\n    completion_reasoning_effort(Options, Effort),\n    request_options_reasoning(Effort, Base, RequestOptions).\n\ncompletion_reasoning_effort(Options, Effort) :-\n    option_value(reasoning_effort, Options, unspecified, Raw),\n    normalize_optional_reasoning_effort(Raw, Effort).\n\nplanner_reasoning_effort(Options, Effort) :-\n    option_value(planner_reasoning_effort, Options, inherit, Raw),\n    (   Raw == inherit\n    ->  completion_reasoning_effort(Options, Effort)\n    ;   normalize_reasoning_effort(Raw, Effort)\n    ).\n\nnormalize_optional_reasoning_effort(unspecified, unspecified) :-\n    !.\nnormalize_optional_reasoning_effort(Raw, Effort) :-\n    normalize_reasoning_effort(Raw, Effort).\n\nnormalize_reasoning_effort(Raw, Effort) :-\n    reasoning_effort_atom(Raw, Candidate),\n    (   memberchk(Candidate, [none,minimal,low,medium,high,xhigh,max])\n    ->  Effort = Candidate\n    ;   throw(completion_fault(invalid_reasoning_effort(Raw)))\n    ).\n\nreasoning_effort_atom(Value, Effort) :-\n    atom(Value),\n    !,\n    downcase_atom(Value, Effort).\nreasoning_effort_atom(Value, Effort) :-\n    string(Value),\n    !,\n    string_lower(Value, Lower),\n    atom_string(Effort, Lower).\nreasoning_effort_atom(Value, _) :-\n    throw(completion_fault(invalid_reasoning_effort(Value))).\n\nrequest_options_reasoning(unspecified, Options, Options) :-\n    !.\nrequest_options_reasoning(Effort, Options0, Options) :-\n    put_dict(reasoning, Options0, _{effort:Effort}, Options).\n\nenforce_plan_reasoning_options(Options, Plan0, Plan) :-\n    completion_reasoning_effort(Options, Effort),\n    enforce_plan_reasoning_effort(Effort, Plan0, Plan).\n\nenforce_plan_reasoning_effort(unspecified, Plan, Plan) :-\n    !.\nenforce_plan_reasoning_effort(Effort, plan(Steps0), plan(Steps)) :-\n    maplist(enforce_step_reasoning_effort(Effort), Steps0, Steps).\n\nenforce_step_reasoning_effort(Effort,\n                              model(Provider, Prompt, RequestOptions0, Bind),\n                              model(Provider, Prompt, RequestOptions, Bind)) :-\n    !,\n    put_dict(reasoning,\n             RequestOptions0,\n             _{effort:Effort},\n             RequestOptions).\nenforce_step_reasoning_effort(Effort, rlm(Plan0, Bind), rlm(Plan, Bind)) :-\n    !,\n    enforce_plan_reasoning_effort(Effort, Plan0, Plan).\nenforce_step_reasoning_effort(Effort,\n                              parallel(Plans0, Bind),\n                              parallel(Plans, Bind)) :-\n    !,\n    maplist(enforce_plan_reasoning_effort(Effort), Plans0, Plans).\nenforce_step_reasoning_effort(Effort,\n                              retry(Attempts, Plan0, Bind),\n                              retry(Attempts, Plan, Bind)) :-\n    !,\n    enforce_plan_reasoning_effort(Effort, Plan0, Plan).\nenforce_step_reasoning_effort(_, Step, Step).\n""",
)

# ---------------------------------------------------------------------------
# Test support: capture exact provider-bound request dictionaries.
# ---------------------------------------------------------------------------

replace_once(
    "test/support/completion_test_support.pl",
    """            invalid_planner/2,\n            fake_model/2,\n            slow_model/2,\n""",
    """            invalid_planner/2,\n            capture_planner/2,\n            capture_model/2,\n            last_planner_request/1,\n            last_model_request/1,\n            fake_model/2,\n            slow_model/2,\n""",
)

replace_once(
    "test/support/completion_test_support.pl",
    """:- dynamic planner_call_count/1.\n:- dynamic model_call_count/1.\n""",
    """:- dynamic planner_call_count/1.\n:- dynamic model_call_count/1.\n:- dynamic last_planner_request/1.\n:- dynamic last_model_request/1.\n""",
)

replace_once(
    "test/support/completion_test_support.pl",
    """reset_calls :-\n    retractall(planner_call_count(_)),\n    retractall(model_call_count(_)),\n    assertz(planner_call_count(0)),\n    assertz(model_call_count(0)).\n""",
    """reset_calls :-\n    retractall(planner_call_count(_)),\n    retractall(model_call_count(_)),\n    retractall(last_planner_request(_)),\n    retractall(last_model_request(_)),\n    assertz(planner_call_count(0)),\n    assertz(model_call_count(0)).\n""",
)

replace_once(
    "test/support/completion_test_support.pl",
    """invalid_planner(_, ok(Response)) :-\n    bump_planner,\n    fake_response(\"not a typed plan\", Response).\n\nfake_model(_, ok(Response)) :-\n""",
    """invalid_planner(_, ok(Response)) :-\n    bump_planner,\n    fake_response(\"not a typed plan\", Response).\n\ncapture_planner(Request, ok(Output)) :-\n    bump_planner,\n    retractall(last_planner_request(_)),\n    assertz(last_planner_request(Request)),\n    Plan = plan([final(literal(\"captured-planner\"))]),\n    planner_output(Plan, Output).\n\ncapture_model(Request, ok(Response)) :-\n    bump_model,\n    retractall(last_model_request(_)),\n    assertz(last_model_request(Request)),\n    fake_response(\"CAPTURED_MODEL_OK\", Response).\n\nfake_model(_, ok(Response)) :-\n""",
)

# ---------------------------------------------------------------------------
# Completion tests: exact request proof + nested-plan host override.
# ---------------------------------------------------------------------------

replace_once(
    "test/rlm_completion_test.pl",
    ":- end_tests(rlm_completion).\n",
    """test(reasoning_effort_reaches_direct_model_request,\n     [setup(completion_test_support:reset_calls)]) :-\n    llm_query(\"reason\",\n              [ reasoning_effort(max),\n                model_handler(completion_test_support:capture_model)\n              ],\n              Outcome),\n    expect_ok(Outcome, _),\n    completion_test_support:last_model_request(Request),\n    assertion(Request.options.reasoning.effort == max).\n\ntest(reasoning_effort_reaches_root_planner_request,\n     [setup(completion_test_support:reset_calls)]) :-\n    base_options(completion_test_support:capture_planner, Base),\n    append(Base, [reasoning_effort(max)], Options),\n    rlm_completion(\"planner reasoning\", text(\"ctx\"), Options, Outcome),\n    expect_ok(Outcome, _),\n    completion_test_support:last_planner_request(Request),\n    assertion(Request.options.reasoning.effort == max).\n\ntest(planner_reasoning_effort_overrides_global_effort,\n     [setup(completion_test_support:reset_calls)]) :-\n    base_options(completion_test_support:capture_planner, Base),\n    append(Base,\n           [ reasoning_effort(max),\n             planner_reasoning_effort(low)\n           ],\n           Options),\n    rlm_completion(\"planner override\", text(\"ctx\"), Options, Outcome),\n    expect_ok(Outcome, _),\n    completion_test_support:last_planner_request(Request),\n    assertion(Request.options.reasoning.effort == low).\n\ntest(no_reasoning_option_preserves_direct_request_shape,\n     [setup(completion_test_support:reset_calls)]) :-\n    llm_query(\"plain\",\n              [model_handler(completion_test_support:capture_model)],\n              Outcome),\n    expect_ok(Outcome, _),\n    completion_test_support:last_model_request(Request),\n    assertion(\\+ get_dict(reasoning, Request.options, _)).\n\ntest(invalid_reasoning_effort_is_structured_rejection,\n     [setup(completion_test_support:reset_calls)]) :-\n    llm_query(\"bad effort\",\n              [ reasoning_effort(turbo),\n                model_handler(completion_test_support:capture_model)\n              ],\n              Outcome),\n    expect_error(Outcome, Error),\n    assertion(Error.kind == completion_fault),\n    assertion(Error.detail == invalid_reasoning_effort(turbo)),\n    completion_test_support:model_calls(Calls),\n    assertion(Calls =:= 0).\n\ntest(host_reasoning_effort_overrides_nested_plan_model_options) :-\n    Plan0 = plan([\n               rlm(plan([\n                       model(openrouter,\n                             literal(\"child\"),\n                             _{max_tokens:32, reasoning:_{effort:low}},\n                             child_response),\n                       final(var(child_response))\n                   ]),\n                   child),\n               final(var(child))\n           ]),\n    rlm_completion:enforce_plan_reasoning_options([reasoning_effort(max)],\n                                                  Plan0,\n                                                  Plan),\n    Plan = plan([\n               rlm(plan([\n                       model(openrouter,\n                             literal(\"child\"),\n                             ModelOptions,\n                             child_response),\n                       final(var(child_response))\n                   ]),\n                   child),\n               final(var(child))\n           ]),\n    assertion(ModelOptions.reasoning.effort == max).\n\ntest(absent_host_reasoning_does_not_rewrite_nested_plan_options) :-\n    Plan0 = plan([model(openrouter,\n                        literal(\"child\"),\n                        _{max_tokens:32, reasoning:_{effort:low}},\n                        child_response),\n                  final(var(child_response))]),\n    rlm_completion:enforce_plan_reasoning_options([], Plan0, Plan),\n    assertion(Plan == Plan0).\n\n:- end_tests(rlm_completion).\n""",
)

# ---------------------------------------------------------------------------
# CLI: expose closed reasoning enums and propagate them to runtime options.
# ---------------------------------------------------------------------------

replace_once(
    "prolog/rlm_cli.pl",
    """    RuntimeOptions = [provider(Provider),\n                      provider_name(ProviderName),\n                      planner_max_tokens(Options.max_tokens),\n                      budget(Budget)],\n    llm_query(Prompt, RuntimeOptions, Outcome),\n""",
    """    RuntimeBase = [provider(Provider),\n                   provider_name(ProviderName),\n                   planner_max_tokens(Options.max_tokens),\n                   budget(Budget)],\n    runtime_reasoning_options(Options, ReasoningOptions),\n    append(RuntimeBase, ReasoningOptions, RuntimeOptions),\n    llm_query(Prompt, RuntimeOptions, Outcome),\n""",
)

replace_once(
    "prolog/rlm_cli.pl",
    """    RuntimeOptions = [provider(Provider),\n                      provider_name(ProviderName),\n                      capabilities([rlm,\n                                    context(slice),\n                                    model(ProviderName)]),\n                      child_capabilities([model(ProviderName)]),\n                      planner_handler(rlm_cli:fixed_cli_planner(Plan)),\n                      planner_attempts(1),\n                      planner_max_tokens(1),\n                      context_options([max_bytes(Options.context_bytes),\n                                       time_limit(2.0)]),\n                      budget(Budget)],\n    rlm_completion(Query,\n""",
    """    RuntimeBase = [provider(Provider),\n                   provider_name(ProviderName),\n                   capabilities([rlm,\n                                 context(slice),\n                                 model(ProviderName)]),\n                   child_capabilities([model(ProviderName)]),\n                   planner_handler(rlm_cli:fixed_cli_planner(Plan)),\n                   planner_attempts(1),\n                   planner_max_tokens(1),\n                   context_options([max_bytes(Options.context_bytes),\n                                    time_limit(2.0)]),\n                   budget(Budget)],\n    runtime_reasoning_options(Options, ReasoningOptions),\n    append(RuntimeBase, ReasoningOptions, RuntimeOptions),\n    rlm_completion(Query,\n""",
)

replace_once(
    "prolog/rlm_cli.pl",
    """/* Provider configuration ---------------------------------------------- */\n\nprovider_from_options(Options, openrouter, Provider, Model) :-\n""",
    """/* Provider configuration ---------------------------------------------- */\n\nruntime_reasoning_options(Options, RuntimeOptions) :-\n    findall(Option,\n            runtime_reasoning_option(Options, Option),\n            RuntimeOptions).\n\nruntime_reasoning_option(Options, reasoning_effort(Effort)) :-\n    Options.reasoning_effort \\== unspecified,\n    Effort = Options.reasoning_effort.\nruntime_reasoning_option(Options, planner_reasoning_effort(Effort)) :-\n    Options.planner_reasoning_effort \\== inherit,\n    Effort = Options.planner_reasoning_effort.\n\nprovider_from_options(Options, openrouter, Provider, Model) :-\n""",
)

replace_once(
    "prolog/rlm_cli.pl",
    """                model:auto,\n                endpoint:none,\n""",
    """                model:auto,\n                reasoning_effort:unspecified,\n                planner_reasoning_effort:inherit,\n                endpoint:none,\n""",
)

replace_once(
    "prolog/rlm_cli.pl",
    """parse_options(['--model',Value|Rest], O0, O, P0, P) :-\n    !, atom_arg(Value, Model), put_dict(model, O0, Model, O1),\n    parse_options(Rest, O1, O, P0, P).\nparse_options(['--endpoint',Value|Rest], O0, O, P0, P) :-\n""",
    """parse_options(['--model',Value|Rest], O0, O, P0, P) :-\n    !, atom_arg(Value, Model), put_dict(model, O0, Model, O1),\n    parse_options(Rest, O1, O, P0, P).\nparse_options(['--reasoning-effort',Value|Rest], O0, O, P0, P) :-\n    !,\n    atom_arg(Value, Effort),\n    require_member(Effort, [none,minimal,low,medium,high,xhigh,max], reasoning_effort),\n    put_dict(reasoning_effort, O0, Effort, O1),\n    parse_options(Rest, O1, O, P0, P).\nparse_options(['--planner-reasoning-effort',Value|Rest], O0, O, P0, P) :-\n    !,\n    atom_arg(Value, Effort),\n    require_member(Effort, [none,minimal,low,medium,high,xhigh,max], planner_reasoning_effort),\n    put_dict(planner_reasoning_effort, O0, Effort, O1),\n    parse_options(Rest, O1, O, P0, P).\nparse_options(['--endpoint',Value|Rest], O0, O, P0, P) :-\n""",
)

replace_once(
    "prolog/rlm_cli.pl",
    """        \"  --model MODEL                 OpenRouter model; defaults to OPENROUTER_TEST_MODEL or openrouter/free\",\n        \"  --endpoint URL                Use an OpenAI-compatible endpoint instead of OpenRouter\",\n""",
    """        \"  --model MODEL                 OpenRouter model; defaults to OPENROUTER_TEST_MODEL or openrouter/free\",\n        \"  --reasoning-effort EFFORT      none|minimal|low|medium|high|xhigh|max\",\n        \"  --planner-reasoning-effort EFFORT  Override planner effort; otherwise inherits reasoning effort\",\n        \"  --endpoint URL                Use an OpenAI-compatible endpoint instead of OpenRouter\",\n""",
)

replace_once(
    "test/rlm_cli_test.pl",
    ":- end_tests(rlm_cli).\n",
    """test(reasoning_effort_options_parse_and_propagate) :-\n    rlm_cli:parse_cli_options(['--reasoning-effort',max,\n                               '--planner-reasoning-effort',low],\n                              Options,\n                              []),\n    assertion(Options.reasoning_effort == max),\n    assertion(Options.planner_reasoning_effort == low),\n    rlm_cli:runtime_reasoning_options(Options, RuntimeOptions),\n    assertion(memberchk(reasoning_effort(max), RuntimeOptions)),\n    assertion(memberchk(planner_reasoning_effort(low), RuntimeOptions)).\n\ntest(default_reasoning_options_do_not_add_runtime_controls) :-\n    rlm_cli:default_cli_options(Options),\n    rlm_cli:runtime_reasoning_options(Options, RuntimeOptions),\n    assertion(RuntimeOptions == []).\n\ntest(invalid_cli_reasoning_effort_is_rejected) :-\n    cli_run([demo,'--reasoning-effort',turbo], error(Error)),\n    assertion(Error.kind == invalid_cli_request),\n    assertion(Error.detail == invalid_option(reasoning_effort, turbo)).\n\ntest(help_documents_reasoning_controls) :-\n    cli_usage(Usage),\n    assertion(sub_string(Usage, _, _, _, \"--reasoning-effort\")),\n    assertion(sub_string(Usage, _, _, _, \"--planner-reasoning-effort\")).\n\n:- end_tests(rlm_cli).\n""",
)

append_once(
    "docs/completion-runtime.md",
    "## Reasoning controls",
    """## Reasoning controls\n\nCompletion callers may set `reasoning_effort(Effort)` using the closed effort\nenum `none|minimal|low|medium|high|xhigh|max`. When present, the runtime sends\n`reasoning:{effort:Effort}` on direct model requests and enforces the same host\nselection on every model step in the validated symbolic plan, including nested\n`rlm`, `parallel`, and `retry` plans. Model-produced request options cannot\ndowngrade or widen an explicit host-selected reasoning effort.\n\nThe root planner inherits `reasoning_effort/1` by default. A trusted caller may\nset `planner_reasoning_effort(Effort)` to control the planner independently. If\nno reasoning option is supplied, no reasoning field is added and legacy request\nshape/behavior is preserved.\n\nThe CLI exposes the same contract as `--reasoning-effort` and\n`--planner-reasoning-effort`.\n""",
)

print("issue 185 patch applied")
