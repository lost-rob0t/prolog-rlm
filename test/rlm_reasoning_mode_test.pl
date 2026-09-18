:- begin_tests(rlm_reasoning_mode).

:- use_module('../prolog/rlm_reasoning_mode').

cleanup_mode(Context) :-
    reasoning_mode_destroy(Context, _).

test(open_defaults_to_auto_pending,
     [cleanup(cleanup_mode(mode_default))]) :-
    reasoning_mode_open(mode_default, ok(State)),
    assertion(State.context == mode_default),
    assertion(State.requested == auto),
    assertion(State.effective == none),
    assertion(State.reason == awaiting_selection),
    assertion(State.generation =:= 0),
    assertion(State.status == active).

test(auto_constraints_select_symbolic,
     [cleanup(cleanup_mode(mode_constraints))]) :-
    reasoning_mode_open(mode_constraints, ok(_)),
    reasoning_mode_select(
        mode_constraints,
        _{has_constraints:true},
        [],
        ok(State)),
    assertion(State.requested == auto),
    assertion(State.effective == symbolic),
    assertion(State.reason == constraints),
    assertion(State.generation =:= 1).

test(auto_frozen_spec_selects_symbolic,
     [cleanup(cleanup_mode(mode_spec))]) :-
    reasoning_mode_open(mode_spec, ok(_)),
    reasoning_mode_select(
        mode_spec,
        _{has_frozen_spec:true},
        [],
        ok(State)),
    assertion(State.effective == symbolic),
    assertion(State.reason == frozen_spec).

test(auto_verification_selects_symbolic,
     [cleanup(cleanup_mode(mode_verify))]) :-
    reasoning_mode_open(mode_verify, ok(_)),
    reasoning_mode_select(
        mode_verify,
        _{requires_verification:true},
        [],
        ok(State)),
    assertion(State.effective == symbolic),
    assertion(State.reason == verification).

test(auto_expert_selects_symbolic,
     [cleanup(cleanup_mode(mode_expert))]) :-
    reasoning_mode_open(mode_expert, ok(_)),
    reasoning_mode_select(
        mode_expert,
        _{expert_applicable:true},
        [],
        ok(State)),
    assertion(State.effective == symbolic),
    assertion(State.reason == expert_applicable).

test(auto_expert_decomposition_selects_symbolic_recursive,
     [cleanup(cleanup_mode(mode_expert_recursive))]) :-
    reasoning_mode_open(mode_expert_recursive, ok(_)),
    reasoning_mode_select(
        mode_expert_recursive,
        _{expert_applicable:true,
          decomposable:true,
          recursion_allowed:true},
        [],
        ok(State)),
    assertion(State.effective == 'symbolic-recursive'),
    assertion(State.reason == expert_decomposition).

test(auto_long_horizon_decomposition_selects_symbolic_recursive,
     [cleanup(cleanup_mode(mode_long_recursive))]) :-
    reasoning_mode_open(mode_long_recursive, ok(_)),
    reasoning_mode_select(
        mode_long_recursive,
        _{long_horizon:true,
          decomposable:true,
          recursion_allowed:true},
        [],
        ok(State)),
    assertion(State.effective == 'symbolic-recursive'),
    assertion(State.reason == decomposable_long_horizon).

test(auto_recursive_signal_without_recursion_permission_stays_symbolic,
     [cleanup(cleanup_mode(mode_no_recursive_cap))]) :-
    reasoning_mode_open(mode_no_recursive_cap, ok(_)),
    reasoning_mode_select(
        mode_no_recursive_cap,
        _{expert_applicable:true,
          decomposable:true,
          recursion_allowed:false},
        [],
        ok(State)),
    assertion(State.effective == symbolic),
    assertion(State.reason == expert_applicable).

test(auto_flexible_default_selects_direct,
     [cleanup(cleanup_mode(mode_direct))]) :-
    reasoning_mode_open(mode_direct, ok(_)),
    reasoning_mode_select(mode_direct, _{}, [], ok(State)),
    assertion(State.effective == direct),
    assertion(State.reason == flexible_default).

test(explicit_symbolic_overrides_auto_selector_until_changed,
     [cleanup(cleanup_mode(mode_sticky))]) :-
    reasoning_mode_open(mode_sticky, symbolic, ok(Open)),
    assertion(Open.requested == symbolic),
    reasoning_mode_select(
        mode_sticky,
        _{long_horizon:true,
          decomposable:true,
          recursion_allowed:true},
        [],
        ok(Explicit)),
    assertion(Explicit.effective == symbolic),
    assertion(Explicit.reason == explicit_override),
    reasoning_mode_set(mode_sticky, auto, ok(AutoPending)),
    assertion(AutoPending.effective == none),
    reasoning_mode_select(
        mode_sticky,
        _{long_horizon:true,
          decomposable:true,
          recursion_allowed:true},
        [],
        ok(Auto)),
    assertion(Auto.effective == 'symbolic-recursive').

test(mode_switch_preserves_context_identity_and_advances_generation,
     [cleanup(cleanup_mode(session(test_identity)))]) :-
    Context = session(test_identity),
    reasoning_mode_open(Context, direct, ok(S0)),
    reasoning_mode_set(Context, symbolic, ok(S1)),
    reasoning_mode_set(Context, direct, ok(S2)),
    assertion(S0.context == Context),
    assertion(S1.context == Context),
    assertion(S2.context == Context),
    assertion(S0.generation =:= 0),
    assertion(S1.generation =:= 1),
    assertion(S2.generation =:= 2).

test(invalid_mode_fails_closed,
     [cleanup(cleanup_mode(mode_invalid))]) :-
    reasoning_mode_open(mode_invalid, ok(_)),
    reasoning_mode_set(mode_invalid, yolo, error(Error)),
    assertion(Error.kind == invalid_mode).

test(unknown_task_signal_fails_closed,
     [cleanup(cleanup_mode(mode_unknown_signal))]) :-
    reasoning_mode_open(mode_unknown_signal, ok(_)),
    reasoning_mode_select(
        mode_unknown_signal,
        _{capabilities:[tool(shell)]},
        [],
        error(Error)),
    assertion(Error.kind == invalid_task_context).

test(non_boolean_signal_fails_closed,
     [cleanup(cleanup_mode(mode_bad_signal))]) :-
    reasoning_mode_open(mode_bad_signal, ok(_)),
    reasoning_mode_select(
        mode_bad_signal,
        _{expert_applicable:yes},
        [],
        error(Error)),
    assertion(Error.kind == invalid_task_context).

test(unknown_option_fails_closed,
     [cleanup(cleanup_mode(mode_bad_option))]) :-
    reasoning_mode_open(mode_bad_option, ok(_)),
    reasoning_mode_select(
        mode_bad_option,
        _{},
        [capabilities([tool(shell)])],
        error(Error)),
    assertion(Error.kind == invalid_options).

test(closed_context_rejects_mutation_and_selection,
     [cleanup(cleanup_mode(mode_closed))]) :-
    reasoning_mode_open(mode_closed, ok(_)),
    reasoning_mode_close(mode_closed, user_cancelled, ok(Closed)),
    assertion(Closed.status == closed),
    assertion(Closed.reason == user_cancelled),
    reasoning_mode_set(mode_closed, direct, error(SetError)),
    assertion(SetError.kind == inactive_context),
    reasoning_mode_select(mode_closed, _{}, [], error(SelectError)),
    assertion(SelectError.kind == inactive_context).

:- end_tests(rlm_reasoning_mode).
