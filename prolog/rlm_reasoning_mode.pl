:- module(rlm_reasoning_mode,
          [ rlm_reasoning_mode_ready/0,
            reasoning_mode_open/2,
            reasoning_mode_open/3,
            reasoning_mode_close/3,
            reasoning_mode_destroy/2,
            reasoning_mode_set/3,
            reasoning_mode_get/2,
            reasoning_mode_select/4,
            reasoning_mode_valid/1
          ]).

/** <module> Canonical reasoning-mode state and deterministic auto selection

Reasoning mode is strategy, never authority.

This module owns only the small mutable selection record keyed by a trusted
host-supplied run/session identity. It does not own conversation history,
provider state, capabilities, authority, effects, verification state, budgets,
or a scheduler. Switching modes therefore cannot grant or reset any of those
runtime concerns.

The public modes are direct, symbolic, symbolic-recursive, and auto.

An auto record is pending (effective:none) until task evidence is supplied
through reasoning_mode_select/4. The initial selector is deliberately small
and deterministic. Trusted formal/expert signals prefer symbolic execution;
explicitly decomposable work with recursion permission may select
symbolic-recursive; otherwise the selector uses direct mode.

Task evidence uses a closed boolean vocabulary. In particular, capability,
authority and budget data are not accepted by this module, keeping strategy
selection structurally separate from permission.
*/

:- dynamic reasoning_mode_state/6.

rlm_reasoning_mode_ready :-
    reasoning_mode_valid(auto),
    reasoning_mode_valid(direct),
    reasoning_mode_valid(symbolic),
    reasoning_mode_valid('symbolic-recursive').

reasoning_mode_valid(direct).
reasoning_mode_valid(symbolic).
reasoning_mode_valid('symbolic-recursive').
reasoning_mode_valid(auto).

reasoning_mode_open(Context, Outcome) :-
    reasoning_mode_open(Context, auto, Outcome).

reasoning_mode_open(Context0, Mode0, Outcome) :-
    catch(
        ( normalize_context(Context0, Context),
          normalize_mode(Mode0, Mode),
          with_mutex(
              rlm_reasoning_mode,
              reasoning_mode_open_locked(Context, Mode, Outcome)
          )
        ),
        Exception,
        reasoning_mode_exception(open, Exception, Outcome)
    ).

reasoning_mode_open_locked(Context, _, Outcome) :-
    reasoning_mode_state(Context, _, _, _, _, _),
    !,
    Outcome = error(reasoning_mode_error{
                        phase:open,
                        kind:duplicate_context,
                        context:Context,
                        message:"reasoning-mode context already exists"
                    }).
reasoning_mode_open_locked(Context, Mode, ok(State)) :-
    initial_effective(Mode, Effective, Reason),
    assertz(reasoning_mode_state(
                Context,
                Mode,
                Effective,
                Reason,
                0,
                active
            )),
    mode_state_dict(
        Context,
        Mode,
        Effective,
        Reason,
        0,
        active,
        State
    ).

reasoning_mode_close(Context0, Reason0, Outcome) :-
    catch(
        ( normalize_context(Context0, Context),
          normalize_close_reason(Reason0, Reason),
          with_mutex(
              rlm_reasoning_mode,
              reasoning_mode_close_locked(Context, Reason, Outcome)
          )
        ),
        Exception,
        reasoning_mode_exception(close, Exception, Outcome)
    ).

reasoning_mode_close_locked(Context, _, Outcome) :-
    \+ reasoning_mode_state(Context, _, _, _, _, _),
    !,
    Outcome = error(reasoning_mode_error{
                        phase:close,
                        kind:unknown_context,
                        context:Context,
                        message:"reasoning-mode context does not exist"
                    }).
reasoning_mode_close_locked(Context, _, Outcome) :-
    reasoning_mode_state(Context, _, _, _, _, Status),
    Status \== active,
    !,
    Outcome = error(reasoning_mode_error{
                        phase:close,
                        kind:inactive_context,
                        context:Context,
                        status:Status,
                        message:"reasoning-mode context is not active"
                    }).
reasoning_mode_close_locked(Context, Reason, ok(State)) :-
    retract(reasoning_mode_state(
                Context,
                Requested,
                Effective,
                _,
                Generation0,
                active
            )),
    Generation is Generation0 + 1,
    assertz(reasoning_mode_state(
                Context,
                Requested,
                Effective,
                Reason,
                Generation,
                closed
            )),
    mode_state_dict(
        Context,
        Requested,
        Effective,
        Reason,
        Generation,
        closed,
        State
    ).

reasoning_mode_destroy(Context0, Outcome) :-
    catch(
        ( normalize_context(Context0, Context),
          with_mutex(
              rlm_reasoning_mode,
              reasoning_mode_destroy_locked(Context, Outcome)
          )
        ),
        Exception,
        reasoning_mode_exception(destroy, Exception, Outcome)
    ).

reasoning_mode_destroy_locked(Context, ok(destroyed)) :-
    retractall(reasoning_mode_state(Context, _, _, _, _, _)).

reasoning_mode_set(Context0, Mode0, Outcome) :-
    catch(
        ( normalize_context(Context0, Context),
          normalize_mode(Mode0, Mode),
          with_mutex(
              rlm_reasoning_mode,
              reasoning_mode_set_locked(Context, Mode, Outcome)
          )
        ),
        Exception,
        reasoning_mode_exception(set, Exception, Outcome)
    ).

reasoning_mode_set_locked(Context, _, Outcome) :-
    \+ reasoning_mode_state(Context, _, _, _, _, _),
    !,
    Outcome = error(reasoning_mode_error{
                        phase:set,
                        kind:unknown_context,
                        context:Context,
                        message:"reasoning-mode context does not exist"
                    }).
reasoning_mode_set_locked(Context, _, Outcome) :-
    reasoning_mode_state(Context, _, _, _, _, Status),
    Status \== active,
    !,
    Outcome = error(reasoning_mode_error{
                        phase:set,
                        kind:inactive_context,
                        context:Context,
                        status:Status,
                        message:"reasoning-mode context is not active"
                    }).
reasoning_mode_set_locked(Context, Mode, ok(State)) :-
    retract(reasoning_mode_state(
                Context,
                _,
                _,
                _,
                Generation0,
                active
            )),
    Generation is Generation0 + 1,
    initial_effective(Mode, Effective, Reason),
    assertz(reasoning_mode_state(
                Context,
                Mode,
                Effective,
                Reason,
                Generation,
                active
            )),
    mode_state_dict(
        Context,
        Mode,
        Effective,
        Reason,
        Generation,
        active,
        State
    ).

reasoning_mode_get(Context0, Outcome) :-
    catch(
        ( normalize_context(Context0, Context),
          with_mutex(
              rlm_reasoning_mode,
              reasoning_mode_get_locked(Context, Outcome)
          )
        ),
        Exception,
        reasoning_mode_exception(get, Exception, Outcome)
    ).

reasoning_mode_get_locked(Context, ok(State)) :-
    reasoning_mode_state(
        Context,
        Requested,
        Effective,
        Reason,
        Generation,
        Status
    ),
    !,
    mode_state_dict(
        Context,
        Requested,
        Effective,
        Reason,
        Generation,
        Status,
        State
    ).
reasoning_mode_get_locked(Context, error(reasoning_mode_error{
                                           phase:get,
                                           kind:unknown_context,
                                           context:Context,
                                           message:"reasoning-mode context does not exist"
                                       })).

reasoning_mode_select(Context0, TaskContext0, Options0, Outcome) :-
    catch(
        ( normalize_context(Context0, Context),
          normalize_task_context(TaskContext0, TaskContext),
          normalize_selector_options(Options0, SelectorOptions),
          with_mutex(
              rlm_reasoning_mode,
              reasoning_mode_select_locked(
                  Context,
                  TaskContext,
                  SelectorOptions,
                  Outcome
              )
          )
        ),
        Exception,
        reasoning_mode_exception(select, Exception, Outcome)
    ).

reasoning_mode_select_locked(Context, _, _, Outcome) :-
    \+ reasoning_mode_state(Context, _, _, _, _, _),
    !,
    Outcome = error(reasoning_mode_error{
                        phase:select,
                        kind:unknown_context,
                        context:Context,
                        message:"reasoning-mode context does not exist"
                    }).
reasoning_mode_select_locked(Context, _, _, Outcome) :-
    reasoning_mode_state(Context, _, _, _, _, Status),
    Status \== active,
    !,
    Outcome = error(reasoning_mode_error{
                        phase:select,
                        kind:inactive_context,
                        context:Context,
                        status:Status,
                        message:"reasoning-mode context is not active"
                    }).
reasoning_mode_select_locked(Context, _, _, ok(State)) :-
    reasoning_mode_state(
        Context,
        Requested,
        Effective,
        Reason,
        Generation,
        active
    ),
    Requested \== auto,
    !,
    mode_state_dict(
        Context,
        Requested,
        Effective,
        Reason,
        Generation,
        active,
        State
    ).
reasoning_mode_select_locked(
    Context,
    TaskContext,
    selector_options{policy:v1},
    ok(State)
) :-
    reasoning_mode_state(Context, auto, _, _, Generation0, active),
    auto_select_v1(TaskContext, Effective, Reason),
    retract(reasoning_mode_state(Context, auto, _, _, Generation0, active)),
    Generation is Generation0 + 1,
    assertz(reasoning_mode_state(
                Context,
                auto,
                Effective,
                Reason,
                Generation,
                active
            )),
    mode_state_dict(
        Context,
        auto,
        Effective,
        Reason,
        Generation,
        active,
        State
    ).

initial_effective(auto, none, awaiting_selection) :-
    !.
initial_effective(Mode, Mode, explicit_override).

auto_select_v1(Context, 'symbolic-recursive', expert_decomposition) :-
    Context.expert_applicable == true,
    Context.decomposable == true,
    Context.recursion_allowed == true,
    !.
auto_select_v1(Context, 'symbolic-recursive', decomposable_long_horizon) :-
    Context.long_horizon == true,
    Context.decomposable == true,
    Context.recursion_allowed == true,
    !.
auto_select_v1(Context, symbolic, expert_applicable) :-
    Context.expert_applicable == true,
    !.
auto_select_v1(Context, symbolic, frozen_spec) :-
    Context.has_frozen_spec == true,
    !.
auto_select_v1(Context, symbolic, constraints) :-
    Context.has_constraints == true,
    !.
auto_select_v1(Context, symbolic, verification) :-
    Context.requires_verification == true,
    !.
auto_select_v1(_, direct, flexible_default).

normalize_task_context(Input, Context) :-
    ( is_dict(Input)
    -> true
    ; throw(mode_fault(invalid_task_context(expected_object)))
    ),
    dict_pairs(Input, _, Pairs),
    pairs_keys(Pairs, Keys),
    Allowed = [
        decomposable,
        expert_applicable,
        has_constraints,
        has_frozen_spec,
        long_horizon,
        recursion_allowed,
        requires_verification
    ],
    subtract(Keys, Allowed, Unknown),
    ( Unknown == []
    -> true
    ; throw(mode_fault(invalid_task_context(unexpected_fields(Unknown))))
    ),
    context_boolean(Input, expert_applicable, false, ExpertApplicable),
    context_boolean(Input, has_constraints, false, HasConstraints),
    context_boolean(Input, has_frozen_spec, false, HasFrozenSpec),
    context_boolean(Input, requires_verification, false, RequiresVerification),
    context_boolean(Input, decomposable, false, Decomposable),
    context_boolean(Input, long_horizon, false, LongHorizon),
    context_boolean(Input, recursion_allowed, false, RecursionAllowed),
    Context = reasoning_task_context{
                  expert_applicable:ExpertApplicable,
                  has_constraints:HasConstraints,
                  has_frozen_spec:HasFrozenSpec,
                  requires_verification:RequiresVerification,
                  decomposable:Decomposable,
                  long_horizon:LongHorizon,
                  recursion_allowed:RecursionAllowed
              }.

context_boolean(Dict, Key, Default, Value) :-
    ( get_dict(Key, Dict, Raw)
    -> require_boolean(Key, Raw),
       Value = Raw
    ; Value = Default
    ).

normalize_selector_options(Options, selector_options{policy:Policy}) :-
    ( is_list(Options)
    -> true
    ; throw(mode_fault(invalid_options(expected_list)))
    ),
    normalize_selector_options_(Options, v1, Policy).

normalize_selector_options_([], Policy, Policy).
normalize_selector_options_([policy(Policy0)|Rest], _, Policy) :-
    !,
    ( Policy0 == v1
    -> normalize_selector_options_(Rest, v1, Policy)
    ; throw(mode_fault(invalid_options(unsupported_policy(Policy0))))
    ).
normalize_selector_options_([Option|_], _, _) :-
    throw(mode_fault(invalid_options(unknown_option(Option)))).

normalize_context(Context, Context) :-
    ground(Context),
    acyclic_term(Context),
    Context \== [],
    !.
normalize_context(Context, _) :-
    throw(mode_fault(invalid_context(Context))).

normalize_mode(Mode, Mode) :-
    reasoning_mode_valid(Mode),
    !.
normalize_mode(Mode, _) :-
    throw(mode_fault(invalid_mode(Mode))).

normalize_close_reason(Reason, Reason) :-
    atom(Reason),
    Reason \== '',
    !.
normalize_close_reason(Reason0, Reason) :-
    string(Reason0),
    Reason0 \== "",
    atom_string(Reason, Reason0),
    !.
normalize_close_reason(Reason, _) :-
    throw(mode_fault(invalid_close_reason(Reason))).

require_boolean(_, true) :-
    !.
require_boolean(_, false) :-
    !.
require_boolean(Key, Value) :-
    throw(mode_fault(invalid_task_context(non_boolean(Key, Value)))).

mode_state_dict(
    Context,
    Requested,
    Effective,
    Reason,
    Generation,
    Status,
    reasoning_mode_state{
        context:Context,
        requested:Requested,
        effective:Effective,
        reason:Reason,
        generation:Generation,
        status:Status
    }
).

reasoning_mode_exception(
    Phase,
    mode_fault(invalid_mode(Mode)),
    error(reasoning_mode_error{
              phase:Phase,
              kind:invalid_mode,
              detail:Mode,
              message:"reasoning mode is invalid"
          })
) :-
    !.
reasoning_mode_exception(
    Phase,
    mode_fault(invalid_task_context(Detail)),
    error(reasoning_mode_error{
              phase:Phase,
              kind:invalid_task_context,
              detail:Detail,
              message:"auto-selection task context is invalid"
          })
) :-
    !.
reasoning_mode_exception(
    Phase,
    mode_fault(invalid_options(Detail)),
    error(reasoning_mode_error{
              phase:Phase,
              kind:invalid_options,
              detail:Detail,
              message:"auto-selection options are invalid"
          })
) :-
    !.
reasoning_mode_exception(
    Phase,
    mode_fault(Detail),
    error(reasoning_mode_error{
              phase:Phase,
              kind:invalid_request,
              detail:Detail,
              message:"reasoning-mode request is invalid"
          })
) :-
    !.
reasoning_mode_exception(
    Phase,
    Exception,
    error(reasoning_mode_error{
              phase:Phase,
              kind:exception,
              exception:Safe,
              message:"reasoning-mode operation failed"
          })
) :-
    catch(
        term_string(
            Exception,
            Safe,
            [quoted(true), numbervars(true), max_depth(8)]
        ),
        _,
        Safe = "<unprintable exception>"
    ).
