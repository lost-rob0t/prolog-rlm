:- module(rlm_plan,
          [ plan_parse/2,
            plan_normalize/2,
            plan_validate/4,
            plan_execute/4,
            plan_run/5,
            default_plan_budget/1
          ]).

/** <module> Typed symbolic plan runtime

Model output is normalized into a small closed AST. Validation covers the
entire plan before execution. Model data is never passed to unrestricted
`call/1`; only trusted host closures from the runtime tool registry are
callable.
*/

:- use_module(library(http/json)).
:- use_module(library(time)).
:- use_module(library(lists)).
:- use_module(rlm_chain).
:- use_module(rlm_context).

default_plan_budget(plan_budget{max_steps:64,
                                max_depth:4,
                                max_parallel:8,
                                max_model_calls:8,
                                max_tool_calls:16,
                                max_context_ops:32,
                                max_output_bytes:65536,
                                time_limit:10.0}).

/* -------------------------------------------------------------------------
 * Parsing and normalization
 * ---------------------------------------------------------------------- */

plan_parse(Input, Outcome) :-
    catch(plan_parse_(Input, Outcome),
          Exception,
          normalize_exception(parse, Exception, Outcome)).

plan_parse_(plan(Steps), Outcome) :-
    !,
    plan_normalize(plan(Steps), Outcome).
plan_parse_(Input, Outcome) :-
    is_dict(Input),
    !,
    plan_normalize(Input, Outcome).
plan_parse_(Input, Outcome) :-
    text_string(Input, Text),
    !,
    json_object_text(Text, JsonText),
    atom_string(Atom, JsonText),
    catch(atom_json_dict(Atom, Dict, []),
          Exception,
          throw(plan_fault(invalid_json(Exception)))),
    plan_normalize(Dict, Outcome).
plan_parse_(Input,
            error(plan_error{phase:parse,
                             kind:unsupported_input,
                             value_shape:Shape,
                             message:"plan input must be a plan term, JSON object, or JSON text"})) :-
    value_shape(Input, Shape).

json_object_text(Text0, Json) :-
    normalize_space(string(Trimmed), Text0),
    extract_json_object(Trimmed, Json).

extract_json_object(Text, Json) :-
    sub_string(Text, Start, _, _, "{"),
    string_length(Text, Length),
    reverse_between(0, Length, End),
    sub_string(Text, End, 1, _, "}"),
    End >= Start,
    !,
    JsonLength is End-Start+1,
    sub_string(Text, Start, JsonLength, _, Json).
extract_json_object(_, _) :-
    throw(plan_fault(no_json_object)).

reverse_between(Low, High, Value) :-
    between(Low, High, Offset),
    Value is High-Offset.

plan_normalize(Input, Outcome) :-
    catch(( normalize_plan(Input, Plan),
            Outcome = ok(Plan)
          ),
          Exception,
          normalize_exception(normalize, Exception, Outcome)).

normalize_plan(plan(Steps0), plan(Steps)) :-
    !,
    must_list(Steps0, steps),
    maplist(normalize_step, Steps0, Steps).
normalize_plan(Dict, plan(Steps)) :-
    is_dict(Dict),
    !,
    require_dict_key(Dict, steps, Steps0),
    must_list(Steps0, steps),
    maplist(normalize_step, Steps0, Steps).
normalize_plan(Value, _) :-
    throw(plan_fault(invalid_plan(Value))).

normalize_step(context(Handle, Action, Bind),
               context(Handle, Action, Bind)) :- !.
normalize_step(model(Provider, Prompt, Options, Bind),
               model(Provider, Prompt, Options, Bind)) :- !.
normalize_step(rlm(Plan0, Bind), rlm(Plan, Bind)) :-
    !,
    normalize_plan(Plan0, Plan).
normalize_step(tool(Name, Args, Bind), tool(Name, Args, Bind)) :- !.
normalize_step(spawn_agent(Spec, Capabilities, Bind),
               tool(spawn_agent,
                    literal(agent_spawn_request{spec:Spec,
                                                capabilities:Capabilities}),
                    Bind)) :- !.
normalize_step(parallel(Plans0, Bind), parallel(Plans, Bind)) :-
    !,
    must_list(Plans0, parallel_plans),
    maplist(normalize_plan, Plans0, Plans).
normalize_step(retry(Attempts, Plan0, Bind), retry(Attempts, Plan, Bind)) :-
    !,
    normalize_plan(Plan0, Plan).
normalize_step(checkpoint(Label), checkpoint(Label)) :- !.
normalize_step(final(Value), final(Value)) :- !.
normalize_step(Dict, Step) :-
    is_dict(Dict),
    !,
    require_text_atom(Dict, op, Op),
    normalize_dict_step(Op, Dict, Step).
normalize_step(Value, _) :-
    throw(plan_fault(invalid_step(Value))).

normalize_dict_step(context, Dict, context(Handle, Action, Bind)) :-
    !,
    require_dict_key(Dict, handle, Handle0),
    normalize_expr(Handle0, Handle),
    require_dict_key(Dict, action, Action0),
    normalize_context_action(Action0, Action),
    require_text_atom(Dict, bind, Bind).
normalize_dict_step(model, Dict, model(Provider, Prompt, Options, Bind)) :-
    !,
    require_text_atom(Dict, provider, Provider),
    require_dict_key(Dict, prompt, Prompt0),
    normalize_expr(Prompt0, Prompt),
    dict_default(options, Dict, _{}, Options),
    must_dict(Options, model_options),
    require_text_atom(Dict, bind, Bind).
normalize_dict_step(rlm, Dict, rlm(Plan, Bind)) :-
    !,
    require_dict_key(Dict, plan, Plan0),
    normalize_plan(Plan0, Plan),
    require_text_atom(Dict, bind, Bind).
normalize_dict_step(tool, Dict, tool(Name, Args, Bind)) :-
    !,
    require_text_atom(Dict, name, Name),
    require_dict_key(Dict, args, Args0),
    normalize_expr(Args0, Args),
    require_text_atom(Dict, bind, Bind).
normalize_dict_step(spawn_agent, Dict,
                    tool(spawn_agent,
                         literal(agent_spawn_request{spec:Spec,
                                                     capabilities:Capabilities}),
                         Bind)) :-
    !,
    require_dict_key(Dict, spec, Spec),
    require_dict_key(Dict, capabilities, Capabilities),
    must_list(Capabilities, child_capabilities),
    require_text_atom(Dict, bind, Bind).
normalize_dict_step(parallel, Dict, parallel(Plans, Bind)) :-
    !,
    require_dict_key(Dict, plans, Plans0),
    must_list(Plans0, parallel_plans),
    maplist(normalize_plan, Plans0, Plans),
    require_text_atom(Dict, bind, Bind).
normalize_dict_step(retry, Dict, retry(Attempts, Plan, Bind)) :-
    !,
    require_integer(Dict, attempts, Attempts),
    require_dict_key(Dict, plan, Plan0),
    normalize_plan(Plan0, Plan),
    require_text_atom(Dict, bind, Bind).
normalize_dict_step(checkpoint, Dict, checkpoint(Label)) :-
    !,
    require_dict_key(Dict, label, Label0),
    (   text_atom(Label0, Label)
    ->  true
    ;   throw(plan_fault(invalid_checkpoint_label(Label0)))
    ).
normalize_dict_step(final, Dict, final(Value)) :-
    !,
    require_dict_key(Dict, value, Value0),
    normalize_expr(Value0, Value).
normalize_dict_step(Op, _, _) :-
    throw(plan_fault(unknown_operator(Op))).

normalize_context_action(Action, Action) :-
    compound(Action),
    functor(Action, Name, _),
    memberchk(Name, [peek, slice, search, partition, map, reduce]),
    !.
normalize_context_action(Dict, Action) :-
    is_dict(Dict),
    !,
    require_text_atom(Dict, type, Type),
    normalize_context_action_dict(Type, Dict, Action).
normalize_context_action(Value, _) :-
    throw(plan_fault(invalid_context_action(Value))).

normalize_context_action_dict(search, Dict, search(Pattern)) :-
    !,
    require_dict_key(Dict, pattern, Pattern0),
    (   text_string(Pattern0, Pattern)
    ->  true
    ;   throw(plan_fault(invalid_search_pattern(Pattern0)))
    ).
normalize_context_action_dict(slice, Dict, slice(Start, Length)) :-
    !,
    require_integer(Dict, start, Start),
    require_integer(Dict, length, Length).
normalize_context_action_dict(peek, Dict, peek(Selector)) :-
    !,
    require_dict_key(Dict, selector, Selector0),
    normalize_selector(Selector0, Selector).
normalize_context_action_dict(partition, Dict, partition(Strategy)) :-
    !,
    require_dict_key(Dict, strategy, Strategy0),
    normalize_partition_strategy(Strategy0, Strategy).
normalize_context_action_dict(map, Dict, map(Transform)) :-
    !,
    require_text_atom(Dict, transform, Transform).
normalize_context_action_dict(reduce, Dict, reduce(Reducer)) :-
    !,
    require_text_atom(Dict, reducer, Reducer).
normalize_context_action_dict(Type, _, _) :-
    throw(plan_fault(unknown_context_action(Type))).

normalize_selector(Value, metadata) :-
    text_atom(Value, metadata),
    !.
normalize_selector(Dict, Selector) :-
    is_dict(Dict),
    !,
    require_text_atom(Dict, type, Type),
    normalize_selector_dict(Type, Dict, Selector).
normalize_selector(Value, _) :-
    throw(plan_fault(invalid_selector(Value))).

normalize_selector_dict(head, Dict, head(Count)) :-
    !,
    require_integer(Dict, count, Count).
normalize_selector_dict(tail, Dict, tail(Count)) :-
    !,
    require_integer(Dict, count, Count).
normalize_selector_dict(item, Dict, item(Index)) :-
    !,
    require_integer(Dict, index, Index).
normalize_selector_dict(Type, _, _) :-
    throw(plan_fault(unknown_selector(Type))).

normalize_partition_strategy(Dict, Strategy) :-
    is_dict(Dict),
    !,
    require_text_atom(Dict, type, Type),
    require_integer(Dict, size, Size),
    (   Type == fixed -> Strategy = fixed(Size)
    ;   Type == lines -> Strategy = lines(Size)
    ;   throw(plan_fault(unknown_partition_strategy(Type)))
    ).
normalize_partition_strategy(Value, _) :-
    throw(plan_fault(invalid_partition_strategy(Value))).

normalize_expr(input(Name), input(Name)) :- !.
normalize_expr(var(Name), var(Name)) :- !.
normalize_expr(field(Base0, Key), field(Base, Key)) :-
    !,
    normalize_expr(Base0, Base).
normalize_expr(literal(Value), literal(Value)) :- !.
normalize_expr(list(Values0), list(Values)) :-
    !,
    maplist(normalize_expr, Values0, Values).
normalize_expr(object(Pairs0), object(Pairs)) :-
    !,
    maplist(normalize_pair, Pairs0, Pairs).
normalize_expr(Dict, Expr) :-
    is_dict(Dict),
    get_dict(ref, Dict, Ref0),
    !,
    (   text_atom(Ref0, Ref)
    ->  normalize_ref_expr(Ref, Dict, Expr)
    ;   throw(plan_fault(invalid_reference(Ref0)))
    ).
normalize_expr(Dict, object(Pairs)) :-
    is_dict(Dict),
    !,
    dict_pairs(Dict, _, RawPairs),
    maplist(normalize_pair, RawPairs, Pairs).
normalize_expr(List0, list(List)) :-
    is_list(List0),
    !,
    maplist(normalize_expr, List0, List).
normalize_expr(Value, literal(Value)).

normalize_ref_expr(input, Dict, input(Name)) :-
    !,
    require_text_atom(Dict, name, Name).
normalize_ref_expr(var, Dict, var(Name)) :-
    !,
    require_text_atom(Dict, name, Name).
normalize_ref_expr(field, Dict, field(Base, Key)) :-
    !,
    require_dict_key(Dict, value, Base0),
    normalize_expr(Base0, Base),
    require_text_atom(Dict, key, Key).
normalize_ref_expr(Ref, _, _) :-
    throw(plan_fault(unknown_reference(Ref))).

normalize_pair(Key-Value0, Key-Value) :-
    atom(Key),
    !,
    normalize_expr(Value0, Value).
normalize_pair(Pair, _) :-
    throw(plan_fault(invalid_object_pair(Pair))).

/* -------------------------------------------------------------------------
 * Validation
 * ---------------------------------------------------------------------- */

plan_validate(Plan0, Capabilities, Budget0, Outcome) :-
    catch(plan_validate_(Plan0, Capabilities, Budget0, Outcome),
          Exception,
          validation_exception(Exception, Outcome)).

plan_validate_(Plan0, Capabilities, Budget0, Outcome) :-
    normalize_for_validation(Plan0, Plan),
    validate_capability_list(Capabilities),
    normalize_budget(Budget0, Budget),
    validate_plan_structure(Plan, Capabilities, [], _),
    plan_estimate(Plan, Estimate),
    validate_estimate(Estimate, Budget),
    Outcome = ok(validated_plan{plan:Plan,
                                capabilities:Capabilities,
                                budget:Budget,
                                estimate:Estimate}).

normalize_for_validation(plan(Steps), plan(Steps)) :- !.
normalize_for_validation(Value, Plan) :-
    plan_normalize(Value, Outcome),
    require_ok(Outcome, Plan).

validate_capability_list(Caps) :-
    (   is_list(Caps)
    ->  true
    ;   throw(plan_validation(invalid_capabilities(Caps)))
    ).

normalize_budget(default, Budget) :-
    !,
    default_plan_budget(Budget).
normalize_budget(Budget0, Budget) :-
    is_dict(Budget0),
    !,
    default_plan_budget(Default),
    budget_update_pairs(Budget0, Updates),
    put_dict(Updates, Default, Budget),
    validate_budget_values(Budget).
normalize_budget(Value, _) :-
    throw(plan_validation(invalid_budget(Value))).

budget_update_pairs(Budget0, Updates) :-
    dict_pairs(Budget0, _, Pairs),
    maplist(validate_budget_pair, Pairs),
    dict_pairs(Updates, _, Pairs).

validate_budget_pair(Key-_) :-
    memberchk(Key, [max_steps,
                    max_depth,
                    max_parallel,
                    max_model_calls,
                    max_tool_calls,
                    max_context_ops,
                    max_output_bytes,
                    time_limit]),
    !.
validate_budget_pair(Key-_) :-
    throw(plan_validation(unknown_budget_field(Key))).

validate_budget_values(Budget) :-
    positive_integer_field(Budget, max_steps),
    positive_integer_field(Budget, max_depth),
    positive_integer_field(Budget, max_parallel),
    nonnegative_integer_field(Budget, max_model_calls),
    nonnegative_integer_field(Budget, max_tool_calls),
    nonnegative_integer_field(Budget, max_context_ops),
    positive_integer_field(Budget, max_output_bytes),
    get_dict(time_limit, Budget, TimeLimit),
    (   number(TimeLimit), TimeLimit > 0
    ->  true
    ;   throw(plan_validation(invalid_budget_field(time_limit, TimeLimit)))
    ).

validate_plan_structure(plan(Steps), Caps, Scope0, Scope) :-
    (   is_list(Steps), Steps \== []
    ->  true
    ;   throw(plan_validation(empty_plan))
    ),
    ensure_final_last(Steps),
    validate_steps(Steps, Caps, Scope0, Scope).

ensure_final_last(Steps) :-
    append(Prefix, [final(_)], Steps),
    \+ (member(Step, Prefix), Step = final(_)),
    !.
ensure_final_last(_) :-
    throw(plan_validation(final_must_be_unique_and_last)).

validate_steps([], _, Scope, Scope).
validate_steps([Step|Steps], Caps, Scope0, Scope) :-
    validate_step(Step, Caps, Scope0, Scope1),
    validate_steps(Steps, Caps, Scope1, Scope).

validate_step(context(Handle, Action, Bind), Caps, Scope0, Scope) :-
    !,
    validate_expr(Handle, Scope0),
    validate_context_action(Action),
    context_capability(Action, Cap),
    require_capability(Cap, Caps),
    add_binding(Bind, Scope0, Scope).
validate_step(model(Provider, Prompt, Options, Bind), Caps, Scope0, Scope) :-
    !,
    require_atom(Provider, provider),
    validate_expr(Prompt, Scope0),
    must_dict_validation(Options, model_options),
    require_capability(model(Provider), Caps),
    add_binding(Bind, Scope0, Scope).
validate_step(rlm(Plan, Bind), Caps, Scope0, Scope) :-
    !,
    require_capability(rlm, Caps),
    validate_plan_structure(Plan, Caps, Scope0, _),
    add_binding(Bind, Scope0, Scope).
validate_step(tool(Name, Args, Bind), Caps, Scope0, Scope) :-
    !,
    require_atom(Name, tool),
    validate_expr(Args, Scope0),
    require_capability(tool(Name), Caps),
    add_binding(Bind, Scope0, Scope).
validate_step(parallel(Plans, Bind), Caps, Scope0, Scope) :-
    !,
    require_capability(parallel, Caps),
    (   is_list(Plans), Plans \== []
    ->  true
    ;   throw(plan_validation(invalid_parallel_plans))
    ),
    maplist(validate_branch(Caps, Scope0), Plans),
    add_binding(Bind, Scope0, Scope).
validate_step(retry(Attempts, Plan, Bind), Caps, Scope0, Scope) :-
    !,
    require_positive_integer(Attempts, retry_attempts),
    require_capability(retry, Caps),
    validate_plan_structure(Plan, Caps, Scope0, _),
    add_binding(Bind, Scope0, Scope).
validate_step(checkpoint(Label), Caps, Scope, Scope) :-
    !,
    require_capability(checkpoint, Caps),
    (   (atom(Label) ; string(Label))
    ->  true
    ;   throw(plan_validation(invalid_checkpoint_label(Label)))
    ).
validate_step(final(Value), _, Scope, Scope) :-
    !,
    validate_expr(Value, Scope).
validate_step(Step, _, _, _) :-
    functor_shape(Step, Shape),
    throw(plan_validation(unknown_or_malformed_operation(Shape))).

validate_branch(Caps, Scope, Plan) :-
    validate_plan_structure(Plan, Caps, Scope, _).

validate_expr(literal(_), _) :- !.
validate_expr(input(Name), _) :-
    !,
    require_atom(Name, input_name).
validate_expr(var(Name), Scope) :-
    !,
    require_atom(Name, variable_name),
    (   memberchk(Name, Scope)
    ->  true
    ;   throw(plan_validation(unbound_variable(Name)))
    ).
validate_expr(field(Base, Key), Scope) :-
    !,
    validate_expr(Base, Scope),
    require_atom(Key, field_key).
validate_expr(list(Values), Scope) :-
    !,
    must_list_validation(Values, expression_list),
    maplist(validate_expr_in_scope(Scope), Values).
validate_expr(object(Pairs), Scope) :-
    !,
    must_list_validation(Pairs, expression_object),
    maplist(validate_expr_pair(Scope), Pairs).
validate_expr(Expr, _) :-
    throw(plan_validation(invalid_expression(Expr))).

validate_expr_in_scope(Scope, Expr) :-
    validate_expr(Expr, Scope).

validate_expr_pair(Scope, Key-Expr) :-
    atom(Key),
    !,
    validate_expr(Expr, Scope).
validate_expr_pair(_, Pair) :-
    throw(plan_validation(invalid_expression_pair(Pair))).

validate_context_action(peek(Selector)) :-
    !,
    validate_selector(Selector).
validate_context_action(slice(Start, Length)) :-
    !,
    require_nonnegative_integer(Start, slice_start),
    require_nonnegative_integer(Length, slice_length).
validate_context_action(search(Pattern)) :-
    !,
    (   string(Pattern), Pattern \== ""
    ->  true
    ;   atom(Pattern), Pattern \== ''
    ->  true
    ;   throw(plan_validation(invalid_search_pattern(Pattern)))
    ).
validate_context_action(partition(Strategy)) :-
    !,
    validate_partition_strategy(Strategy).
validate_context_action(map(Transform)) :-
    !,
    (   memberchk(Transform, [identity, lowercase, uppercase, length])
    ->  true
    ;   throw(plan_validation(invalid_map_transform(Transform)))
    ).
validate_context_action(reduce(Reducer)) :-
    !,
    (   memberchk(Reducer, [count, byte_count])
    ->  true
    ;   throw(plan_validation(invalid_reducer(Reducer)))
    ).
validate_context_action(Action) :-
    throw(plan_validation(invalid_context_action(Action))).

validate_selector(metadata) :- !.
validate_selector(head(Count)) :-
    !,
    require_nonnegative_integer(Count, peek_count).
validate_selector(tail(Count)) :-
    !,
    require_nonnegative_integer(Count, peek_count).
validate_selector(item(Index)) :-
    !,
    require_nonnegative_integer(Index, item_index).
validate_selector(Value) :-
    throw(plan_validation(invalid_selector(Value))).

validate_partition_strategy(fixed(Size)) :-
    !,
    require_positive_integer(Size, partition_size).
validate_partition_strategy(lines(Size)) :-
    !,
    require_positive_integer(Size, partition_size).
validate_partition_strategy(Value) :-
    throw(plan_validation(invalid_partition_strategy(Value))).

context_capability(peek(_), context(peek)).
context_capability(slice(_, _), context(slice)).
context_capability(search(_), context(search)).
context_capability(partition(_), context(partition)).
context_capability(map(_), context(map)).
context_capability(reduce(_), context(reduce)).

require_capability(Cap, Caps) :-
    (   memberchk(Cap, Caps)
    ->  true
    ;   throw(plan_validation(capability_denied(Cap)))
    ).

add_binding(Bind, Scope0, [Bind|Scope0]) :-
    require_atom(Bind, binding),
    (   memberchk(Bind, Scope0)
    ->  throw(plan_validation(duplicate_binding(Bind)))
    ;   true
    ).

plan_estimate(Plan, Estimate) :-
    estimate_plan(Plan, 1, Estimate).

estimate_plan(plan(Steps), Depth, Estimate) :-
    zero_estimate(Zero0),
    put_dict(depth, Zero0, Depth, Zero),
    estimate_steps(Steps, Depth, Zero, Estimate).

zero_estimate(plan_estimate{steps:0,
                            depth:1,
                            parallel_width:0,
                            model_calls:0,
                            tool_calls:0,
                            context_ops:0}).

estimate_steps([], _, Estimate, Estimate).
estimate_steps([Step|Steps], Depth, Estimate0, Estimate) :-
    estimate_step(Step, Depth, StepEstimate),
    estimate_add(Estimate0, StepEstimate, Estimate1),
    estimate_steps(Steps, Depth, Estimate1, Estimate).

estimate_step(context(_, _, _), Depth, Estimate) :-
    !,
    single_estimate(Depth, context_ops, Estimate).
estimate_step(model(_, _, _, _), Depth, Estimate) :-
    !,
    single_estimate(Depth, model_calls, Estimate).
estimate_step(tool(_, _, _), Depth, Estimate) :-
    !,
    single_estimate(Depth, tool_calls, Estimate).
estimate_step(checkpoint(_), Depth, Estimate) :-
    !,
    single_estimate(Depth, none, Estimate).
estimate_step(final(_), Depth, Estimate) :-
    !,
    single_estimate(Depth, none, Estimate).
estimate_step(rlm(Plan, _), Depth, Estimate) :-
    !,
    ChildDepth is Depth+1,
    estimate_plan(Plan, ChildDepth, Child),
    single_estimate(ChildDepth, none, Wrapper),
    estimate_add(Wrapper, Child, Estimate).
estimate_step(parallel(Plans, _), Depth, Estimate) :-
    !,
    ChildDepth is Depth+1,
    maplist(estimate_at_depth(ChildDepth), Plans, Branches),
    sum_estimates(Branches, Sum),
    length(Plans, Width),
    single_estimate(ChildDepth, none, Base),
    put_dict(parallel_width, Base, Width, Wrapper),
    estimate_add(Wrapper, Sum, Estimate).
estimate_step(retry(Attempts, Plan, _), Depth, Estimate) :-
    !,
    ChildDepth is Depth+1,
    estimate_plan(Plan, ChildDepth, Child),
    estimate_scale(Child, Attempts, Scaled),
    single_estimate(ChildDepth, none, Wrapper),
    estimate_add(Wrapper, Scaled, Estimate).

single_estimate(Depth, Counter, Estimate) :-
    zero_estimate(Zero0),
    put_dict(_{steps:1, depth:Depth}, Zero0, Base),
    increment_estimate_counter(Counter, Base, Estimate).

increment_estimate_counter(none, Estimate, Estimate) :- !.
increment_estimate_counter(Name, Estimate0, Estimate) :-
    get_dict(Name, Estimate0, Value0),
    Value is Value0+1,
    put_dict(Name, Estimate0, Value, Estimate).

estimate_at_depth(Depth, Plan, Estimate) :-
    estimate_plan(Plan, Depth, Estimate).

sum_estimates(Estimates, Sum) :-
    zero_estimate(Zero),
    foldl(estimate_add, Estimates, Zero, Sum).

estimate_add(A, B, C) :-
    Steps is A.steps+B.steps,
    Depth is max(A.depth, B.depth),
    Parallel is max(A.parallel_width, B.parallel_width),
    Models is A.model_calls+B.model_calls,
    Tools is A.tool_calls+B.tool_calls,
    Context is A.context_ops+B.context_ops,
    C = plan_estimate{steps:Steps,
                      depth:Depth,
                      parallel_width:Parallel,
                      model_calls:Models,
                      tool_calls:Tools,
                      context_ops:Context}.

estimate_scale(A, Factor, C) :-
    Steps is A.steps*Factor,
    Models is A.model_calls*Factor,
    Tools is A.tool_calls*Factor,
    Context is A.context_ops*Factor,
    put_dict(_{steps:Steps,
               model_calls:Models,
               tool_calls:Tools,
               context_ops:Context},
             A,
             C).

validate_estimate(Estimate, Budget) :-
    budget_check(steps, Estimate.steps, Budget.max_steps),
    budget_check(depth, Estimate.depth, Budget.max_depth),
    budget_check(parallel, Estimate.parallel_width, Budget.max_parallel),
    budget_check(model_calls, Estimate.model_calls, Budget.max_model_calls),
    budget_check(tool_calls, Estimate.tool_calls, Budget.max_tool_calls),
    budget_check(context_ops, Estimate.context_ops, Budget.max_context_ops).

budget_check(_, Used, Limit) :-
    Used =< Limit,
    !.
budget_check(Name, Used, Limit) :-
    throw(plan_validation(budget_exceeded(Name, Used, Limit))).

/* -------------------------------------------------------------------------
 * Execution
 * ---------------------------------------------------------------------- */

plan_run(PlanInput, Capabilities, Options, Inputs, Outcome) :-
    option_value(budget, Options, default, Budget),
    plan_parse(PlanInput, ParseOutcome),
    run_parsed(ParseOutcome, Capabilities, Budget, Options, Inputs, Outcome).

run_parsed(error(Error), _, _, _, _, error(Error)) :- !.
run_parsed(ok(Plan), Caps, Budget, Options, Inputs, Outcome) :-
    plan_validate(Plan, Caps, Budget, ValidationOutcome),
    run_validated(ValidationOutcome, Options, Inputs, Outcome).

run_validated(error(Error), _, _, error(Error)) :- !.
run_validated(ok(Validated), Options, Inputs, Outcome) :-
    plan_execute(Validated, Options, Inputs, Outcome).

plan_execute(Validated, Options, Inputs, Outcome) :-
    catch(plan_execute_(Validated, Options, Inputs, Outcome),
          Exception,
          execution_exception(Exception, Outcome)).

plan_execute_(Validated, Options, Inputs, Outcome) :-
    must_validated_plan(Validated),
    must_dict_execution(Inputs, inputs),
    runtime_config(Options, Runtime),
    get_dict(plan, Validated, Plan),
    preflight_runtime(Plan, Runtime),
    get_dict(budget, Validated, Budget),
    initial_execution_state(Budget, State0),
    get_dict(time_limit, Budget, TimeLimit),
    catch(call_with_time_limit(TimeLimit,
                               execute_plan(Plan, Runtime, Inputs, State0,
                                            ExecOutcome)),
          TimeException,
          timed_execution_exception(TimeException, State0, ExecOutcome)),
    finalize_execution(ExecOutcome, Outcome).

runtime_config(Options,
               runtime{providers:Providers,
                       tools:Tools,
                       context_options:ContextOptions}) :-
    (   is_list(Options)
    ->  true
    ;   throw(plan_execution(invalid_options(Options)))
    ),
    option_value(providers, Options, [], Providers),
    option_value(tools, Options, [], Tools),
    option_value(context_options, Options, [], ContextOptions),
    validate_provider_entries(Providers),
    validate_tool_entries(Tools),
    (   is_list(ContextOptions)
    ->  true
    ;   throw(plan_execution(invalid_context_options(ContextOptions)))
    ).

validate_provider_entries([]) :- !.
validate_provider_entries([provider_ref(Name, Provider)|Rest]) :-
    atom(Name),
    nonvar(Provider),
    !,
    validate_provider_entries(Rest).
validate_provider_entries(Value) :-
    throw(plan_execution(invalid_provider_registry(Value))).

validate_tool_entries([]) :- !.
validate_tool_entries([tool(Name, Handler)|Rest]) :-
    atom(Name),
    callable(Handler),
    !,
    validate_tool_entries(Rest).
validate_tool_entries(Value) :-
    throw(plan_execution(invalid_tool_registry(Value))).

preflight_runtime(plan(Steps), Runtime) :-
    maplist(preflight_step(Runtime), Steps).

preflight_step(Runtime, model(Name, _, _, _)) :-
    !,
    get_dict(providers, Runtime, Providers),
    (   memberchk(provider_ref(Name, _), Providers)
    ->  true
    ;   throw(plan_execution(unknown_provider(Name)))
    ).
preflight_step(Runtime, tool(Name, _, _)) :-
    !,
    get_dict(tools, Runtime, Tools),
    (   memberchk(tool(Name, _), Tools)
    ->  true
    ;   throw(plan_execution(unknown_tool(Name)))
    ).
preflight_step(Runtime, rlm(Plan, _)) :-
    !,
    preflight_runtime(Plan, Runtime).
preflight_step(Runtime, parallel(Plans, _)) :-
    !,
    maplist(preflight_runtime_with(Runtime), Plans).
preflight_step(Runtime, retry(_, Plan, _)) :-
    !,
    preflight_runtime(Plan, Runtime).
preflight_step(_, _).

preflight_runtime_with(Runtime, Plan) :-
    preflight_runtime(Plan, Runtime).

initial_execution_state(Budget,
                        exec_state{vars:_{},
                                   model_responses:[],
                                   model_events:[],
                                   model_event_sequence:0,
                                   trace_depth:0,
                                   trace_parent:root_planner,
                                   trace_reason:direct_plan_model,
                                   trace_last_model:none,
                                   transitions:[],
                                   sequence:0,
                                   checkpoints:[],
                                   remaining:Remaining}) :-
    Remaining = runtime_budget{steps:Budget.max_steps,
                               model_calls:Budget.max_model_calls,
                               tool_calls:Budget.max_tool_calls,
                               context_ops:Budget.max_context_ops,
                               output_bytes:Budget.max_output_bytes}.

execute_plan(plan(Steps), Runtime, Inputs, State0, Outcome) :-
    execute_steps(Steps, Runtime, Inputs, State0, Outcome).

execute_steps([], _, _, State, error(Error, State)) :-
    Error = plan_error{phase:execute,
                       kind:missing_final,
                       message:"plan ended without final result"}.
execute_steps([Step|Steps], Runtime, Inputs, State0, Outcome) :-
    consume_step_budget(Step, State0, BudgetOutcome),
    (   BudgetOutcome = error(Error, State1)
    ->  Outcome = error(Error, State1)
    ;   BudgetOutcome = ok(State1),
        execute_step(Step, Runtime, Inputs, State1, StepOutcome),
        continue_after_step(StepOutcome, Steps, Runtime, Inputs, Outcome)
    ).

continue_after_step(error(Error, State), _, _, _, error(Error, State)) :- !.
continue_after_step(final(Value, State), _, _, _, final(Value, State)) :- !.
continue_after_step(ok(State), Steps, Runtime, Inputs, Outcome) :-
    execute_steps(Steps, Runtime, Inputs, State, Outcome).

consume_step_budget(Step, State0, Outcome) :-
    decrement_remaining(steps, State0, First),
    (   First = error(_, _)
    ->  Outcome = First
    ;   First = ok(State1),
        step_counter(Step, Counter),
        consume_optional_counter(Counter, State1, Outcome)
    ).

step_counter(context(_, _, _), context_ops) :- !.
step_counter(model(_, _, _, _), model_calls) :- !.
step_counter(tool(_, _, _), tool_calls) :- !.
step_counter(_, none).

consume_optional_counter(none, State, ok(State)) :- !.
consume_optional_counter(Name, State, Outcome) :-
    decrement_remaining(Name, State, Outcome).

decrement_remaining(Name, State0, Outcome) :-
    get_dict(remaining, State0, Remaining0),
    get_dict(Name, Remaining0, Value0),
    (   Value0 > 0
    ->  Value is Value0-1,
        put_dict(Name, Remaining0, Value, Remaining),
        put_dict(remaining, State0, Remaining, State),
        Outcome = ok(State)
    ;   Outcome = error(plan_error{phase:execute,
                                   kind:budget_exhausted,
                                   budget:Name,
                                   message:"runtime plan budget exhausted"},
                       State0)
    ).

execute_step(context(HandleExpr, Action, Bind), Runtime, Inputs, State0,
             Outcome) :-
    !,
    resolve_expr(HandleExpr, Inputs, State0, HandleOutcome),
    (   HandleOutcome = error(Error)
    ->  Outcome = error(Error, State0)
    ;   HandleOutcome = ok(Handle),
        get_dict(context_options, Runtime, ContextOptions),
        run_context_action(Action, Handle, ContextOptions, ContextOutcome),
        handle_context_result(ContextOutcome, Action, Bind, State0, Outcome)
    ).
execute_step(model(ProviderName, PromptExpr, RequestOptions, Bind), Runtime,
             Inputs, State0, Outcome) :-
    !,
    resolve_expr(PromptExpr, Inputs, State0, PromptOutcome),
    (   PromptOutcome = error(Error)
    ->  Outcome = error(Error, State0)
    ;   PromptOutcome = ok(PromptValue),
        (   text_string(PromptValue, Prompt)
        ->  lookup_provider(ProviderName, Runtime, Provider),
            Request = model_request{messages:[message{role:user,
                                                      content:Prompt}],
                                    options:RequestOptions},
            rlm_chain:model_complete_execute(Provider, Request, ModelOutcome),
            handle_model_result(ModelOutcome, ProviderName, Bind, State0,
                                Outcome)
        ;   Outcome = error(plan_error{phase:execute,
                                       kind:invalid_prompt,
                                       provider:ProviderName,
                                       message:"model prompt did not resolve to text"},
                           State0)
        )
    ).
execute_step(rlm(Plan, Bind), Runtime, Inputs, State0, Outcome) :-
    !,
    parent_vars(State0, ParentVars),
    trace_context(State0, ParentTrace),
    child_trace_state(nested_rlm_model, State0, NestedStart),
    execute_plan(Plan, Runtime, Inputs, NestedStart, NestedOutcome),
    nested_result(rlm,
                  NestedOutcome,
                  ParentVars,
                  ParentTrace,
                  Bind,
                  Outcome).
execute_step(tool(Name, ArgsExpr, Bind), Runtime, Inputs, State0, Outcome) :-
    !,
    resolve_expr(ArgsExpr, Inputs, State0, ArgsOutcome),
    (   ArgsOutcome = error(Error)
    ->  Outcome = error(Error, State0)
    ;   ArgsOutcome = ok(Args),
        lookup_tool(Name, Runtime, Handler),
        catch(call(Handler, Args, ToolResult),
              Exception,
              trusted_tool_exception(Exception, ToolResult)),
        handle_tool_result(ToolResult, Name, Bind, State0, Outcome)
    ).
execute_step(parallel(Plans, Bind), Runtime, Inputs, State0, Outcome) :-
    !,
    parent_vars(State0, ParentVars),
    trace_context(State0, ParentTrace),
    execute_branches(Plans,
                     Runtime,
                     Inputs,
                     ParentVars,
                     ParentTrace,
                     State0,
                     [],
                     BranchOutcome),
    (   BranchOutcome = error(Error, State)
    ->  Outcome = error(Error, State)
    ;   BranchOutcome = ok(Values, State1),
        restore_scope(State1, ParentVars, ParentTrace, Restored),
        bind_value(Bind, Values, Restored, BindOutcome),
        transition_result(BindOutcome, parallel, Bind, Outcome)
    ).
execute_step(retry(Attempts, Plan, Bind), Runtime, Inputs, State0, Outcome) :-
    !,
    parent_vars(State0, ParentVars),
    trace_context(State0, ParentTrace),
    execute_retry(Attempts,
                  Plan,
                  Runtime,
                  Inputs,
                  ParentVars,
                  ParentTrace,
                  State0,
                  RetryOutcome),
    (   RetryOutcome = error(Error, State)
    ->  Outcome = error(Error, State)
    ;   RetryOutcome = ok(Value, State1),
        restore_scope(State1, ParentVars, ParentTrace, Restored),
        bind_value(Bind, Value, Restored, BindOutcome),
        transition_result(BindOutcome, retry, Bind, Outcome)
    ).
execute_step(checkpoint(Label), _, _, State0, ok(State)) :-
    !,
    get_dict(checkpoints, State0, Checkpoints0),
    put_dict(checkpoints, State0, [Label|Checkpoints0], State1),
    add_transition(checkpoint, none, State1, State).
execute_step(final(ValueExpr), _, Inputs, State0, Outcome) :-
    !,
    resolve_expr(ValueExpr, Inputs, State0, ValueOutcome),
    (   ValueOutcome = error(Error)
    ->  Outcome = error(Error, State0)
    ;   ValueOutcome = ok(Value),
        consume_output(Value, State0, OutputOutcome),
        (   OutputOutcome = error(Error, State1)
        ->  Outcome = error(Error, State1)
        ;   OutputOutcome = ok(State1),
            add_transition(final, none, State1, State),
            Outcome = final(Value, State)
        )
    ).
execute_step(Step, _, _, State,
             error(plan_error{phase:execute,
                              kind:unknown_operation,
                              operation:Step,
                              message:"validated plan contained an unknown operation"},
                   State)).

run_context_action(peek(Selector), Handle, Options, Outcome) :-
    context_peek(Handle, Selector, Options, Outcome).
run_context_action(slice(Start, Length), Handle, Options, Outcome) :-
    context_slice(Handle, Start, Length, Options, Outcome).
run_context_action(search(Pattern), Handle, Options, Outcome) :-
    context_search(Handle, Pattern, Options, Outcome).
run_context_action(partition(Strategy), Handle, Options, Outcome) :-
    context_partition(Handle, Strategy, Options, Outcome).
run_context_action(map(Transform), Handle, Options, Outcome) :-
    context_map(Handle, Transform, Options, Outcome).
run_context_action(reduce(Reducer), Handle, Options, Outcome) :-
    context_reduce(Handle, Reducer, Options, Outcome).

handle_context_result(error(ContextError), _, _, State,
                      error(plan_error{phase:execute,
                                       kind:context_error,
                                       cause:ContextError,
                                       message:"context operation failed"},
                            State)) :- !.
handle_context_result(ok(ContextResult), Action, Bind, State0, Outcome) :-
    get_dict(value, ContextResult, Value),
    bind_value(Bind, Value, State0, BindOutcome),
    context_action_name(Action, OpName),
    transition_result(BindOutcome, context(OpName), Bind, Outcome).

context_action_name(Action, Name) :-
    functor(Action, Name, _).

handle_model_result(error(ModelError), Provider, _, State,
                    error(plan_error{phase:execute,
                                     kind:model_error,
                                     provider:Provider,
                                     cause:ModelError,
                                     message:"model operation failed"},
                          State)) :- !.
handle_model_result(ok(Response), Provider, Bind, State0, Outcome) :-
    record_model_response(Response, Provider, State0, State1),
    bind_value(Bind, Response, State1, BindOutcome),
    transition_result(BindOutcome, model(Provider), Bind, Outcome).

record_model_response(Response, State0, State) :-
    record_model_response(Response, unknown, State0, State).

record_model_response(Response, Provider, State0, State) :-
    state_value(model_responses, State0, [], Responses0),
    state_value(model_events, State0, [], Events0),
    state_value(model_event_sequence, State0, 0, Sequence0),
    state_value(trace_depth, State0, 0, Depth),
    state_value(trace_parent, State0, root_planner, Parent),
    state_value(trace_reason, State0, direct_plan_model, Reason),
    Sequence is Sequence0+1,
    format(atom(Id), 'plan_model_~d', [Sequence]),
    Event = plan_model_event{sequence:Sequence,
                             id:Id,
                             parent:Parent,
                             depth:Depth,
                             reason:Reason,
                             provider:Provider,
                             response:Response},
    put_dict(_{model_responses:[Response|Responses0],
               model_events:[Event|Events0],
               model_event_sequence:Sequence,
               trace_last_model:Id},
             State0,
             State).

trusted_tool_exception(time_limit_exceeded, _) :-
    !,
    throw(time_limit_exceeded).
trusted_tool_exception(time_limit_exceeded(Context), _) :-
    !,
    throw(time_limit_exceeded(Context)).
trusted_tool_exception(error(rlm_cancelled(Token), Context), _) :-
    !,
    throw(error(rlm_cancelled(Token), Context)).
trusted_tool_exception(Exception, tool_exception(Exception)).

handle_tool_result(tool_exception(Exception), Name, _, State,
                   error(Error, State)) :-
    !,
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = plan_error{phase:execute,
                       kind:tool_error,
                       tool:Name,
                       exception:Safe,
                       message:"trusted host tool raised an exception"}.
handle_tool_result(Result, Name, Bind, State0, Outcome) :-
    bind_value(Bind, Result, State0, BindOutcome),
    transition_result(BindOutcome, tool(Name), Bind, Outcome).

transition_result(error(Error, State), _, _, error(Error, State)) :- !.
transition_result(ok(State1), Operation, Bind, ok(State)) :-
    add_transition(Operation, Bind, State1, State).

bind_value(Bind, Value, State0, Outcome) :-
    consume_output(Value, State0, OutputOutcome),
    (   OutputOutcome = error(Error, State1)
    ->  Outcome = error(Error, State1)
    ;   OutputOutcome = ok(State1),
        get_dict(vars, State1, Vars0),
        put_dict(Bind, Vars0, Value, Vars),
        put_dict(vars, State1, Vars, State),
        Outcome = ok(State)
    ).

consume_output(Value, State0, Outcome) :-
    value_bytes(Value, Bytes),
    get_dict(remaining, State0, Remaining0),
    get_dict(output_bytes, Remaining0, Left0),
    (   Bytes =< Left0
    ->  Left is Left0-Bytes,
        put_dict(output_bytes, Remaining0, Left, Remaining),
        put_dict(remaining, State0, Remaining, State),
        Outcome = ok(State)
    ;   Outcome = error(plan_error{phase:execute,
                                   kind:budget_exhausted,
                                   budget:output_bytes,
                                   requested:Bytes,
                                   remaining:Left0,
                                   message:"plan output byte budget exhausted"},
                       State0)
    ).

add_transition(Operation, Bind, State0, State) :-
    get_dict(sequence, State0, Seq0),
    Seq is Seq0+1,
    Transition = plan_transition{sequence:Seq,
                                 operation:Operation,
                                 bind:Bind,
                                 status:ok},
    get_dict(transitions, State0, Transitions0),
    put_dict(_{sequence:Seq,
               transitions:[Transition|Transitions0]},
             State0,
             State).

execute_branches([], _, _, _, _, State, Values, ok(Results, State)) :-
    reverse(Values, Results).
execute_branches([Plan|Plans],
                 Runtime,
                 Inputs,
                 ParentVars,
                 ParentTrace,
                 State0,
                 Values0,
                 Outcome) :-
    restore_scope(State0, ParentVars, ParentTrace, ParentStart),
    child_trace_state(parallel_model, ParentStart, BranchStart),
    execute_plan(Plan, Runtime, Inputs, BranchStart, BranchOutcome),
    (   BranchOutcome = final(Value, BranchState0)
    ->  restore_scope(BranchState0,
                       ParentVars,
                       ParentTrace,
                       BranchState),
        execute_branches(Plans,
                         Runtime,
                         Inputs,
                         ParentVars,
                         ParentTrace,
                         BranchState,
                         [Value|Values0],
                         Outcome)
    ;   BranchOutcome = error(Error, BranchState0),
        restore_scope(BranchState0,
                       ParentVars,
                       ParentTrace,
                       BranchState),
        Outcome = error(Error, BranchState)
    ).

execute_retry(Attempts,
              Plan,
              Runtime,
              Inputs,
              ParentVars,
              ParentTrace,
              State0,
              Outcome) :-
    Attempts > 0,
    restore_scope(State0, ParentVars, ParentTrace, ParentStart),
    child_trace_state(retry_model, ParentStart, AttemptState),
    execute_plan(Plan, Runtime, Inputs, AttemptState, AttemptOutcome),
    (   AttemptOutcome = final(Value, State1)
    ->  Outcome = ok(Value, State1)
    ;   AttemptOutcome = error(Error, State1),
        restore_scope(State1, ParentVars, ParentTrace, RetryState),
        Attempts1 is Attempts-1,
        (   Attempts1 > 0
        ->  execute_retry(Attempts1,
                          Plan,
                          Runtime,
                          Inputs,
                          ParentVars,
                          ParentTrace,
                          RetryState,
                          Outcome)
        ;   Outcome = error(Error, RetryState)
        )
    ).

nested_result(_, error(Error, NestedState), ParentVars, ParentTrace, _,
              error(Error, Restored)) :-
    !,
    restore_scope(NestedState, ParentVars, ParentTrace, Restored).
nested_result(Operation,
              final(Value, NestedState),
              ParentVars,
              ParentTrace,
              Bind,
              Outcome) :-
    restore_scope(NestedState, ParentVars, ParentTrace, Restored),
    bind_value(Bind, Value, Restored, BindOutcome),
    transition_result(BindOutcome, Operation, Bind, Outcome).

parent_vars(State, Vars) :-
    get_dict(vars, State, Vars).

trace_context(State,
              trace_context{depth:Depth,
                            parent:Parent,
                            reason:Reason,
                            last_model:LastModel}) :-
    state_value(trace_depth, State, 0, Depth),
    state_value(trace_parent, State, root_planner, Parent),
    state_value(trace_reason, State, direct_plan_model, Reason),
    state_value(trace_last_model, State, none, LastModel).

child_trace_state(Reason, State0, State) :-
    trace_context(State0, Trace),
    ChildDepth is Trace.depth+1,
    (   Trace.last_model == none
    ->  ChildParent = Trace.parent
    ;   ChildParent = Trace.last_model
    ),
    put_dict(_{trace_depth:ChildDepth,
               trace_parent:ChildParent,
               trace_reason:Reason,
               trace_last_model:none},
             State0,
             State).

restore_scope(State0, Vars, Trace, State) :-
    put_dict(_{vars:Vars,
               trace_depth:Trace.depth,
               trace_parent:Trace.parent,
               trace_reason:Trace.reason,
               trace_last_model:Trace.last_model},
             State0,
             State).

restore_vars(State0, Vars, State) :-
    put_dict(vars, State0, Vars, State).

state_value(Key, State, Default, Value) :-
    (   get_dict(Key, State, Found)
    ->  Value = Found
    ;   Value = Default
    ).

resolve_expr(literal(Value), _, _, ok(Value)) :- !.
resolve_expr(input(Name), Inputs, _, Outcome) :-
    !,
    (   get_dict(Name, Inputs, Value)
    ->  Outcome = ok(Value)
    ;   Outcome = error(plan_error{phase:execute,
                                   kind:missing_input,
                                   input:Name,
                                   message:"plan input is not available"})
    ).
resolve_expr(var(Name), _, State, Outcome) :-
    !,
    get_dict(vars, State, Vars),
    (   get_dict(Name, Vars, Value)
    ->  Outcome = ok(Value)
    ;   Outcome = error(plan_error{phase:execute,
                                   kind:unbound_variable,
                                   variable:Name,
                                   message:"plan variable is not bound"})
    ).
resolve_expr(field(Base, Key), Inputs, State, Outcome) :-
    !,
    resolve_expr(Base, Inputs, State, BaseOutcome),
    resolve_field(BaseOutcome, Key, Outcome).
resolve_expr(list(Exprs), Inputs, State, Outcome) :-
    !,
    resolve_expr_list(Exprs, Inputs, State, Outcome).
resolve_expr(object(Pairs), Inputs, State, Outcome) :-
    !,
    resolve_expr_pairs(Pairs, Inputs, State, Outcome).
resolve_expr(Expr, _, _,
             error(plan_error{phase:execute,
                              kind:invalid_expression,
                              expression:Expr,
                              message:"validated plan contained invalid expression"})).

resolve_field(error(Error), _, error(Error)) :- !.
resolve_field(ok(Base), Key, Outcome) :-
    (   is_dict(Base), get_dict(Key, Base, Value)
    ->  Outcome = ok(Value)
    ;   Outcome = error(plan_error{phase:execute,
                                   kind:missing_field,
                                   field:Key,
                                   message:"field expression could not be resolved"})
    ).

resolve_expr_list([], _, _, ok([])).
resolve_expr_list([Expr|Exprs], Inputs, State, Outcome) :-
    resolve_expr(Expr, Inputs, State, HeadOutcome),
    (   HeadOutcome = error(Error)
    ->  Outcome = error(Error)
    ;   HeadOutcome = ok(Value),
        resolve_expr_list(Exprs, Inputs, State, TailOutcome),
        prepend_resolved(Value, TailOutcome, Outcome)
    ).

prepend_resolved(_, error(Error), error(Error)) :- !.
prepend_resolved(Value, ok(Values), ok([Value|Values])).

resolve_expr_pairs(Pairs, Inputs, State, Outcome) :-
    resolve_pairs(Pairs, Inputs, State, PairOutcome),
    (   PairOutcome = error(Error)
    ->  Outcome = error(Error)
    ;   PairOutcome = ok(Resolved),
        dict_pairs(Dict, json, Resolved),
        Outcome = ok(Dict)
    ).

resolve_pairs([], _, _, ok([])).
resolve_pairs([Key-Expr|Pairs], Inputs, State, Outcome) :-
    resolve_expr(Expr, Inputs, State, ValueOutcome),
    (   ValueOutcome = error(Error)
    ->  Outcome = error(Error)
    ;   ValueOutcome = ok(Value),
        resolve_pairs(Pairs, Inputs, State, TailOutcome),
        prepend_pair(Key, Value, TailOutcome, Outcome)
    ).

prepend_pair(_, _, error(Error), error(Error)) :- !.
prepend_pair(Key, Value, ok(Pairs), ok([Key-Value|Pairs])).

lookup_provider(Name, Runtime, Provider) :-
    get_dict(providers, Runtime, Providers),
    memberchk(provider_ref(Name, Provider), Providers).

lookup_tool(Name, Runtime, Handler) :-
    get_dict(tools, Runtime, Tools),
    memberchk(tool(Name, Handler), Tools).

finalize_execution(final(Value, State), ok(Result)) :-
    !,
    get_dict(transitions, State, RevTransitions),
    reverse(RevTransitions, Transitions),
    get_dict(checkpoints, State, RevCheckpoints),
    reverse(RevCheckpoints, Checkpoints),
    get_dict(vars, State, Vars),
    get_dict(model_responses, State, RevModelResponses),
    reverse(RevModelResponses, ModelResponses),
    state_value(model_events, State, [], RevModelEvents),
    reverse(RevModelEvents, ModelEvents),
    get_dict(remaining, State, Remaining),
    Result = plan_result{value:Value,
                         vars:Vars,
                         model_responses:ModelResponses,
                         model_events:ModelEvents,
                         transitions:Transitions,
                         checkpoints:Checkpoints,
                         budget_remaining:Remaining}.
finalize_execution(error(Error0, State), error(Error)) :-
    !,
    get_dict(transitions, State, RevTransitions),
    reverse(RevTransitions, Transitions),
    get_dict(model_responses, State, RevModelResponses),
    reverse(RevModelResponses, ModelResponses),
    state_value(model_events, State, [], RevModelEvents),
    reverse(RevModelEvents, ModelEvents),
    get_dict(remaining, State, Remaining),
    put_dict(_{transitions:Transitions,
               model_responses:ModelResponses,
               model_events:ModelEvents,
               budget_remaining:Remaining},
             Error0,
             Error).
finalize_execution(exception(Error), error(Error)).

/* -------------------------------------------------------------------------
 * Structured errors and helpers
 * ---------------------------------------------------------------------- */

preflight_error(Kind, Value,
                plan_error{phase:preflight,
                           kind:Kind,
                           value:Value,
                           message:"plan runtime preflight failed"}).

must_validated_plan(Value) :-
    (   is_dict(Value, validated_plan),
        get_dict(plan, Value, plan(_)),
        get_dict(budget, Value, _)
    ->  true
    ;   throw(plan_execution(invalid_validated_plan(Value)))
    ).

must_dict_execution(Value, _) :-
    is_dict(Value),
    !.
must_dict_execution(Value, Field) :-
    throw(plan_execution(invalid_field(Field, Value))).

option_value(Name, Options, Default, Value) :-
    (   is_list(Options),
        member(Option, Options),
        Option =.. [Name, Found]
    ->  Value = Found
    ;   Value = Default
    ).

require_ok(ok(Value), Value) :- !.
require_ok(error(Error), _) :-
    throw(plan_fault(nested_error(Error))).

normalize_exception(Phase, plan_fault(Fault), error(Error)) :-
    !,
    Error = plan_error{phase:Phase,
                       kind:invalid_plan,
                       detail:Fault,
                       message:"plan could not be normalized"}.
normalize_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = plan_error{phase:Phase,
                       kind:normalization_error,
                       exception:Safe,
                       message:"plan normalization failed"}.

validation_exception(plan_validation(Fault), error(Error)) :-
    !,
    validation_fault(Fault, Error).
validation_exception(plan_fault(nested_error(Error)), error(Error)) :- !.
validation_exception(Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = plan_error{phase:validate,
                       kind:validation_error,
                       exception:Safe,
                       message:"plan validation failed"}.

validation_fault(capability_denied(Cap),
                 plan_error{phase:validate,
                            kind:capability_denied,
                            capability:Cap,
                            message:"plan requires a capability that was not granted"}) :- !.
validation_fault(budget_exceeded(Name, Used, Limit),
                 plan_error{phase:validate,
                            kind:budget_exceeded,
                            budget:Name,
                            estimated:Used,
                            limit:Limit,
                            message:"estimated plan cost exceeds its budget"}) :- !.
validation_fault(Fault,
                 plan_error{phase:validate,
                            kind:invalid_plan,
                            detail:Fault,
                            message:"plan failed structural validation"}).

execution_exception(plan_execution(Fault), error(Error)) :-
    !,
    execution_fault(Fault, Error).
execution_exception(error(rlm_cancelled(Token), Context), _) :-
    !,
    throw(error(rlm_cancelled(Token), Context)).
execution_exception(Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = plan_error{phase:execute,
                       kind:runtime_error,
                       exception:Safe,
                       message:"plan execution failed"}.

execution_fault(unknown_provider(Name), Error) :-
    !,
    preflight_error(unknown_provider, Name, Error).
execution_fault(unknown_tool(Name), Error) :-
    !,
    preflight_error(unknown_tool, Name, Error).
execution_fault(Fault,
                plan_error{phase:preflight,
                           kind:invalid_runtime,
                           detail:Fault,
                           message:"plan runtime configuration is invalid"}).

timed_execution_exception(time_limit_exceeded, State,
                          error(plan_error{phase:execute,
                                           kind:time_limit_exceeded,
                                           message:"plan exceeded its wall-time budget"},
                                State)) :- !.
timed_execution_exception(time_limit_exceeded(_), State,
                          error(plan_error{phase:execute,
                                           kind:time_limit_exceeded,
                                           message:"plan exceeded its wall-time budget"},
                                State)) :- !.
timed_execution_exception(Exception, _, _) :-
    throw(Exception).

positive_integer_field(Dict, Key) :-
    (   get_dict(Key, Dict, Value)
    ->  require_positive_integer(Value, Key)
    ;   throw(plan_validation(missing_budget_field(Key)))
    ).

nonnegative_integer_field(Dict, Key) :-
    (   get_dict(Key, Dict, Value)
    ->  require_nonnegative_integer(Value, Key)
    ;   throw(plan_validation(missing_budget_field(Key)))
    ).

require_positive_integer(Value, _) :-
    integer(Value), Value > 0,
    !.
require_positive_integer(Value, Field) :-
    throw(plan_validation(invalid_positive_integer(Field, Value))).

require_nonnegative_integer(Value, _) :-
    integer(Value), Value >= 0,
    !.
require_nonnegative_integer(Value, Field) :-
    throw(plan_validation(invalid_nonnegative_integer(Field, Value))).

require_atom(Value, _) :-
    atom(Value),
    !.
require_atom(Value, Field) :-
    throw(plan_validation(invalid_atom(Field, Value))).

must_dict_validation(Value, _) :-
    is_dict(Value),
    !.
must_dict_validation(Value, Field) :-
    throw(plan_validation(invalid_dict(Field, Value))).

must_list_validation(Value, _) :-
    is_list(Value),
    !.
must_list_validation(Value, Field) :-
    throw(plan_validation(invalid_list(Field, Value))).

require_dict_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(plan_fault(missing_field(Key)))
    ).

require_text_atom(Dict, Key, Atom) :-
    require_dict_key(Dict, Key, Value),
    (   text_atom(Value, Atom)
    ->  true
    ;   throw(plan_fault(invalid_text_field(Key, Value)))
    ).

require_integer(Dict, Key, Integer) :-
    require_dict_key(Dict, Key, Value),
    (   integer(Value)
    ->  Integer = Value
    ;   throw(plan_fault(invalid_integer_field(Key, Value)))
    ).

dict_default(Key, Dict, Default, Value) :-
    (   get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

must_list(Value, _) :-
    is_list(Value),
    !.
must_list(Value, Field) :-
    throw(plan_fault(invalid_list(Field, Value))).

must_dict(Value, _) :-
    is_dict(Value),
    !.
must_dict(Value, Field) :-
    throw(plan_fault(invalid_dict(Field, Value))).

text_atom(Value, Atom) :-
    atom(Value),
    !,
    Atom = Value.
text_atom(Value, Atom) :-
    string(Value),
    !,
    atom_string(Atom, Value).

text_string(Value, String) :-
    string(Value),
    !,
    String = Value.
text_string(Value, String) :-
    atom(Value),
    !,
    atom_string(Value, String).

value_bytes(Value, Bytes) :-
    term_string(Value, Text, [quoted(true), numbervars(true)]),
    string_bytes(Text, Octets, utf8),
    length(Octets, Bytes).

value_shape(Value, Shape) :-
    (   var(Value) -> Shape = variable
    ;   is_dict(Value) -> Shape = dict
    ;   is_list(Value) -> Shape = list
    ;   compound(Value) -> functor_shape(Value, Shape)
    ;   atom(Value) -> Shape = atom
    ;   string(Value) -> Shape = string
    ;   number(Value) -> Shape = number
    ;   Shape = other
    ).

functor_shape(Value, Functor/Arity) :-
    compound(Value),
    !,
    functor(Value, Functor, Arity).
functor_shape(Value, Value/0).
