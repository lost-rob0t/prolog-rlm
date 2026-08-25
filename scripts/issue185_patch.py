#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: str, old: str, new: str) -> None:
    target = ROOT / path
    text = target.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one replacement, found {count}")
    target.write_text(text.replace(old, new, 1))


replace_once(
    "prolog/rlm_completion.pl",
    """    bound_plan_model_tokens(Planner.plan,\n                            PlanModelCalls,\n                            RemainingTokens,\n                            BoundedPlan),\n""",
    """    bound_plan_model_tokens(Planner.plan,\n                            PlanModelCalls,\n                            RemainingTokens,\n                            TokenBoundedPlan),\n    model_reasoning_effort(Options, ReasoningEffort),\n    apply_plan_reasoning(TokenBoundedPlan,\n                         ReasoningEffort,\n                         BoundedPlan),\n""",
)

replace_once(
    "prolog/rlm_completion.pl",
    """planner_request_options(Options, TokenLimit, RequestOptions) :-\n    option_value(planner_temperature, Options, 0, Temperature),\n    RequestOptions = _{max_tokens:TokenLimit, temperature:Temperature}.\n\nmodel_request_options(Options, TokenLimit, RequestOptions) :-\n    option_value(temperature, Options, 0, Temperature),\n    RequestOptions = _{max_tokens:TokenLimit, temperature:Temperature}.\n""",
    """planner_request_options(Options, TokenLimit, RequestOptions) :-\n    option_value(planner_temperature, Options, 0, Temperature),\n    Base = request_options{max_tokens:TokenLimit, temperature:Temperature},\n    planner_reasoning_effort(Options, Effort),\n    request_reasoning_options(Effort, Base, RequestOptions).\n\nmodel_request_options(Options, TokenLimit, RequestOptions) :-\n    option_value(temperature, Options, 0, Temperature),\n    Base = request_options{max_tokens:TokenLimit, temperature:Temperature},\n    model_reasoning_effort(Options, Effort),\n    request_reasoning_options(Effort, Base, RequestOptions).\n\nmodel_reasoning_effort(Options, Effort) :-\n    option_value(reasoning_effort, Options, auto, Requested),\n    normalize_reasoning_effort(Requested, Effort).\n\nplanner_reasoning_effort(Options, Effort) :-\n    option_value(planner_reasoning_effort, Options, inherit, Requested),\n    (   Requested == inherit\n    ->  model_reasoning_effort(Options, Effort)\n    ;   normalize_reasoning_effort(Requested, Effort)\n    ).\n\nnormalize_reasoning_effort(auto, auto) :- !.\nnormalize_reasoning_effort(Effort, Effort) :-\n    memberchk(Effort, [none, low, medium, high, xhigh, max]),\n    !.\nnormalize_reasoning_effort(Effort, _) :-\n    throw(completion_fault(invalid_reasoning_effort(Effort))).\n\nrequest_reasoning_options(auto, Options, Options) :- !.\nrequest_reasoning_options(Effort, Options0, Options) :-\n    put_dict(reasoning,\n             Options0,\n             reasoning_options{effort:Effort},\n             Options).\n""",
)

replace_once(
    "prolog/rlm_completion.pl",
    """bound_plan_tokens_with(PerCall, Plan0, Plan) :-\n    bound_plan_tokens(Plan0, PerCall, Plan).\n\ndict_token_limit(Options, Ceiling, Limit) :-\n""",
    """bound_plan_tokens_with(PerCall, Plan0, Plan) :-\n    bound_plan_tokens(Plan0, PerCall, Plan).\n\napply_plan_reasoning(Plan, auto, Plan) :- !.\napply_plan_reasoning(plan(Steps0), Effort, plan(Steps)) :-\n    maplist(apply_step_reasoning(Effort), Steps0, Steps).\n\napply_step_reasoning(Effort,\n                     model(Provider, Prompt, Options0, Bind),\n                     model(Provider, Prompt, Options, Bind)) :-\n    !,\n    put_dict(reasoning,\n             Options0,\n             reasoning_options{effort:Effort},\n             Options).\napply_step_reasoning(Effort, rlm(Plan0, Bind), rlm(Plan, Bind)) :-\n    !,\n    apply_plan_reasoning(Plan0, Effort, Plan).\napply_step_reasoning(Effort, parallel(Plans0, Bind), parallel(Plans, Bind)) :-\n    !,\n    maplist(apply_plan_reasoning_with(Effort), Plans0, Plans).\napply_step_reasoning(Effort, retry(Attempts, Plan0, Bind),\n                     retry(Attempts, Plan, Bind)) :-\n    !,\n    apply_plan_reasoning(Plan0, Effort, Plan).\napply_step_reasoning(_, Step, Step).\n\napply_plan_reasoning_with(Effort, Plan0, Plan) :-\n    apply_plan_reasoning(Plan0, Effort, Plan).\n\ndict_token_limit(Options, Ceiling, Limit) :-\n""",
)

replace_once(
    "prolog/rlm_cli.pl",
    """    RuntimeOptions = [provider(Provider),\n                      provider_name(ProviderName),\n                      planner_max_tokens(Options.max_tokens),\n                      budget(Budget)],\n""",
    """    RuntimeOptions = [provider(Provider),\n                      provider_name(ProviderName),\n                      planner_max_tokens(Options.max_tokens),\n                      reasoning_effort(Options.reasoning_effort),\n                      planner_reasoning_effort(Options.planner_reasoning_effort),\n                      budget(Budget)],\n""",
)

replace_once(
    "prolog/rlm_cli.pl",
    """                      planner_attempts(1),\n                      planner_max_tokens(1),\n                      context_options([max_bytes(Options.context_bytes),\n""",
    """                      planner_attempts(1),\n                      planner_max_tokens(1),\n                      reasoning_effort(Options.reasoning_effort),\n                      planner_reasoning_effort(Options.planner_reasoning_effort),\n                      context_options([max_bytes(Options.context_bytes),\n""",
)

replace_once(
    "prolog/rlm_cli.pl",
    """                context_bytes:8192,\n                max_tokens:256,\n                max_cost_usd:0.25,\n""",
    """                context_bytes:8192,\n                max_tokens:256,\n                reasoning_effort:auto,\n                planner_reasoning_effort:inherit,\n                max_cost_usd:0.25,\n""",
)

replace_once(
    "prolog/rlm_cli.pl",
    """parse_options(['--max-tokens',Value|Rest], O0, O, P0, P) :-\n    !, positive_integer_arg(Value, N), put_dict(max_tokens, O0, N, O1),\n    parse_options(Rest, O1, O, P0, P).\nparse_options(['--max-cost',Value|Rest], O0, O, P0, P) :-\n""",
    """parse_options(['--max-tokens',Value|Rest], O0, O, P0, P) :-\n    !, positive_integer_arg(Value, N), put_dict(max_tokens, O0, N, O1),\n    parse_options(Rest, O1, O, P0, P).\nparse_options(['--reasoning-effort',Value|Rest], O0, O, P0, P) :-\n    !, reasoning_effort_arg(Value, Effort),\n    put_dict(reasoning_effort, O0, Effort, O1),\n    parse_options(Rest, O1, O, P0, P).\nparse_options(['--planner-reasoning-effort',Value|Rest], O0, O, P0, P) :-\n    !, planner_reasoning_effort_arg(Value, Effort),\n    put_dict(planner_reasoning_effort, O0, Effort, O1),\n    parse_options(Rest, O1, O, P0, P).\nparse_options(['--max-cost',Value|Rest], O0, O, P0, P) :-\n""",
)

replace_once(
    "prolog/rlm_cli.pl",
    """nonnegative_number_arg(Value, _) :-\n    throw(cli_fault(invalid_nonnegative_number(Value))).\n\npositional_text([], Name, _) :- throw(cli_fault(missing_argument(Name))).\n""",
    """nonnegative_number_arg(Value, _) :-\n    throw(cli_fault(invalid_nonnegative_number(Value))).\n\nreasoning_effort_arg(Value, Effort) :-\n    atom_arg(Value, Effort),\n    require_member(Effort,\n                   [auto, none, low, medium, high, xhigh, max],\n                   reasoning_effort).\n\nplanner_reasoning_effort_arg(Value, Effort) :-\n    atom_arg(Value, Effort),\n    require_member(Effort,\n                   [inherit, auto, none, low, medium, high, xhigh, max],\n                   planner_reasoning_effort).\n\npositional_text([], Name, _) :- throw(cli_fault(missing_argument(Name))).\n""",
)

replace_once(
    "prolog/rlm_cli.pl",
    """        \"  --max-tokens N                Direct/child response limit (default 256)\",\n        \"  --max-cost USD                Completion cost ceiling (default 0.25)\",\n""",
    """        \"  --max-tokens N                Direct/child response limit (default 256)\",\n        \"  --reasoning-effort EFFORT     auto|none|low|medium|high|xhigh|max\",\n        \"  --planner-reasoning-effort EFFORT  inherit|auto|none|low|medium|high|xhigh|max\",\n        \"  --max-cost USD                Completion cost ceiling (default 0.25)\",\n""",
)

replace_once(
    "docs/providers.md",
    """The initial generation-option allow-list includes `max_tokens`,\n`max_completion_tokens`, `temperature`, `top_p`, `seed`, `stop`, `tools`,\n`tool_choice`, and `response_format`.\n""",
    """The generation-option allow-list includes `max_tokens`,\n`max_completion_tokens`, `temperature`, `top_p`, `seed`, `stop`, `tools`,\n`tool_choice`, `response_format`, and `reasoning`.\n\nThe completion runtime exposes a closed host-side reasoning control with\n`reasoning_effort(Effort)`, where `Effort` is one of `none`, `low`, `medium`,\n`high`, `xhigh`, or `max`. When omitted, no reasoning field is injected and\nexisting provider behavior is preserved. `planner_reasoning_effort(Effort)` may\noverride the root planner; otherwise the planner inherits `reasoning_effort`.\nAn explicit completion-level reasoning effort is also applied to nested model\nsteps, so a model-generated plan cannot silently widen or downgrade the host's\nselected reasoning policy.\n""",
)

replace_once(
    "docs/cli-demo-traces.md",
    """Useful bounds:\n\n```text\n--context-bytes N\n--max-tokens N\n--max-cost USD\n--time-limit SECONDS\n```\n""",
    """Useful bounds and reasoning controls:\n\n```text\n--context-bytes N\n--max-tokens N\n--reasoning-effort auto|none|low|medium|high|xhigh|max\n--planner-reasoning-effort inherit|auto|none|low|medium|high|xhigh|max\n--max-cost USD\n--time-limit SECONDS\n```\n\nFor example, an OpenRouter model can be run at maximum reasoning effort with\n`--reasoning-effort max`. The flag is host policy: the same effort is applied\nto recursive child model steps unless omitted with `auto`.\n""",
)

replace_once(
    "test/deterministic_corpus.pl",
    """corpus_entry('rlm_completion_test.pl', include(rlm_completion)).\ncorpus_entry('rlm_completion_hardening_test.pl',\n""",
    """corpus_entry('rlm_completion_test.pl', include(rlm_completion)).\ncorpus_entry('rlm_reasoning_control_test.pl', include(rlm_reasoning_control)).\ncorpus_entry('rlm_completion_hardening_test.pl',\n""",
)

reasoning_test = r''':- begin_tests(rlm_reasoning_control).

:- use_module('../prolog/rlm_completion').
:- use_module('../prolog/rlm_cli').

:- dynamic seen_request/2.

reset_seen :- retractall(seen_request(_, _)).

capture_model(Request, ok(Response)) :-
    assertz(seen_request(model, Request)),
    fake_response("MODEL_OK", Response).

capture_planner(Request, ok(Output)) :-
    assertz(seen_request(planner, Request)),
    Output = planner_output{
                 plan:plan([final(literal("PLANNER_OK"))]),
                 usage:_{prompt_tokens:1,
                         completion_tokens:1,
                         total_tokens:2,
                         cost:0.0}
             }.

fake_response(Text,
              model_response{provider:fake,
                             requested_model:fake,
                             selected_model:fake,
                             text:Text,
                             reasoning:"",
                             tool_calls:[],
                             finish_reason:stop,
                             usage:usage{present:true,
                                         prompt_tokens:1,
                                         completion_tokens:1,
                                         total_tokens:2,
                                         cost:0.0},
                             metadata:metadata{http_status:200,
                                               response_received:true}}).

test(direct_reasoning_effort_reaches_model_request,
     [setup(reset_seen)]) :-
    llm_query("hello",
              [ reasoning_effort(max),
                model_handler(rlm_reasoning_control:capture_model)
              ],
              ok(_)),
    seen_request(model, Request),
    assertion(Request.options.reasoning.effort == max).

test(omitted_reasoning_preserves_legacy_request_shape,
     [setup(reset_seen)]) :-
    llm_query("hello",
              [model_handler(rlm_reasoning_control:capture_model)],
              ok(_)),
    seen_request(model, Request),
    assertion(\+ get_dict(reasoning, Request.options, _)).

test(planner_inherits_model_reasoning_effort,
     [setup(reset_seen)]) :-
    rlm_completion("plan",
                   text("context"),
                   [ planner_handler(rlm_reasoning_control:capture_planner),
                     reasoning_effort(high)
                   ],
                   ok(_)),
    seen_request(planner, Request),
    assertion(Request.options.reasoning.effort == high).

test(planner_reasoning_override_is_independent,
     [setup(reset_seen)]) :-
    rlm_completion("plan",
                   text("context"),
                   [ planner_handler(rlm_reasoning_control:capture_planner),
                     reasoning_effort(high),
                     planner_reasoning_effort(max)
                   ],
                   ok(_)),
    seen_request(planner, Request),
    assertion(Request.options.reasoning.effort == max).

test(recursive_model_steps_receive_host_reasoning_policy) :-
    Plan0 = plan([
                rlm(plan([
                        model(openrouter,
                              literal("child"),
                              _{reasoning:_{effort:low}},
                              response),
                        final(var(response))
                    ]),
                    child),
                final(var(child))
            ]),
    rlm_completion:apply_plan_reasoning(Plan0, max, Plan),
    Plan = plan([
               rlm(plan([
                       model(openrouter, _, Options, _),
                       final(_)
                   ]),
                   _),
               final(_)
           ]),
    assertion(Options.reasoning.effort == max).

test(auto_reasoning_leaves_recursive_plan_unchanged) :-
    Plan0 = plan([model(openrouter,
                        literal("child"),
                        _{temperature:0},
                        response),
                  final(var(response))]),
    rlm_completion:apply_plan_reasoning(Plan0, auto, Plan),
    assertion(Plan == Plan0).

test(invalid_reasoning_effort_fails_closed) :-
    llm_query("hello",
              [ reasoning_effort(ultra),
                model_handler(rlm_reasoning_control:capture_model)
              ],
              error(Error)),
    assertion(Error.kind == completion_fault),
    assertion(Error.detail == invalid_reasoning_effort(ultra)).

test(cli_parses_luna_max_style_reasoning_flag) :-
    rlm_cli:parse_cli_options(['--reasoning-effort',max], Options, []),
    assertion(Options.reasoning_effort == max).

test(cli_rejects_unknown_reasoning_effort) :-
    catch(rlm_cli:parse_cli_options(['--reasoning-effort',ultra], _, _),
          Exception,
          true),
    assertion(Exception == cli_fault(invalid_option(reasoning_effort, ultra))).

:- end_tests(rlm_reasoning_control).
'''
(ROOT / "test/rlm_reasoning_control_test.pl").write_text(reasoning_test)

# One-shot implementation helper: remove itself and its workflow from the PR.
(ROOT / "scripts/issue185_patch.py").unlink()
workflow = ROOT / ".github/workflows/issue-185-reasoning-self-patch.yml"
if workflow.exists():
    workflow.unlink()
