:- set_prolog_flag(on_error, status).
:- initialization(main, main).

:- begin_tests(rlm_style_overlay).

:- use_module('../prolog/rlm_style_overlay').

context(Project, Generation, Language,
        style_context{project_id:Project,
                      project_generation:Generation,
                      language:Language,
                      known_languages:[python,nix,bash,common_lisp],
                      max_model_calls:0}).

rule(Id, Scope, Language, Project, Generation, Preferred, Overrides, Rule) :-
    Rule = style_rule{id:Id,
                      scope:Scope,
                      language:Language,
                      project_id:Project,
                      project_generation:Generation,
                      check:naming,
                      preferred:Preferred,
                      autofix:none,
                      provenance:_{source:test, revision:'rev-1'},
                      revision:'rev-1',
                      overrides:Overrides}.

base_rules(Rules) :-
    rule(default, library_default, any, any, any, snake, [], Default),
    rule(user, user_global, any, any, any, camel, [], User),
    rule(user_python, user_language, python, any, any, pascal, [], UserPython),
    rule(project_a, project_global, any, project_a, 7, kebab, [], ProjectA),
    rule(project_a_python, project_language, python, project_a, 7, dotted, [], ProjectPython),
    rule(session_a, session, python, project_a, 7, upper, [], Session),
    Rules = [Default, User, UserPython, ProjectA, ProjectPython, Session].

test(scope_precedence_is_frozen) :-
    findall(Scope-Rank, style_scope_rank(Scope, Rank), Pairs),
    assertion(Pairs == [library_default-10,
                        user_global-20,
                        user_language-30,
                        project_global-40,
                        project_language-50,
                        session-60]).

test(project_a_session_wins_with_shadow_provenance) :-
    base_rules(Rules),
    context(project_a, 7, python, Context),
    style_overlay_resolve(Rules, Context, Result),
    Result.effective = [Winner],
    assertion(Winner.id == session_a),
    assertion(Winner.preferred == upper),
    Result.decisions = [Decision],
    assertion(Decision.check == naming),
    assertion(Decision.winner == session_a),
    assertion(Decision.shadowed == [default,user,user_python,project_a,project_a_python]),
    assertion(Result.usage.model_calls == 0).

test(project_a_rules_never_leak_into_project_b) :-
    base_rules(Rules),
    context(project_b, 3, python, Context),
    style_overlay_resolve(Rules, Context, Result),
    Result.effective = [Winner],
    assertion(Winner.id == user_python),
    assertion(Winner.preferred == pascal),
    Result.decisions = [Decision],
    assertion(Decision.shadowed == [default,user]).

test(stale_project_generation_fails_closed,
     [throws(style_overlay_fault(stale_project_generation(project_a, 7, 8)))]) :-
    base_rules(Rules),
    context(project_a, 8, python, Context),
    style_overlay_resolve(Rules, Context, _).

test(duplicate_rule_ids_fail_closed,
     [throws(style_overlay_fault(duplicate_rule_id(default)))]) :-
    base_rules([Default|Rules]),
    context(project_b, 3, nix, Context),
    style_overlay_resolve([Default,Default|Rules], Context, _).

test(equal_precedence_conflict_fails_closed,
     [throws(style_overlay_fault(equal_precedence_conflict(naming, user_a, user_b)))]) :-
    rule(user_a, user_global, any, any, any, one, [], A),
    rule(user_b, user_global, any, any, any, two, [], B),
    context(project_b, 1, nix, Context),
    style_overlay_resolve([A,B], Context, _).

test(explicit_same_rank_override_is_deterministic) :-
    rule(user_a, user_global, any, any, any, one, [user_b], A),
    rule(user_b, user_global, any, any, any, two, [], B),
    context(project_b, 1, nix, Context),
    style_overlay_resolve([B,A], Context, Result),
    Result.effective = [Winner],
    assertion(Winner.id == user_a),
    Result.decisions = [Decision],
    assertion(Decision.shadowed == [user_b]).

test(override_cycle_fails_closed,
     [throws(style_overlay_fault(override_cycle([user_a,user_b,user_a])))]) :-
    rule(user_a, user_global, any, any, any, one, [user_b], A),
    rule(user_b, user_global, any, any, any, two, [user_a], B),
    context(project_b, 1, nix, Context),
    style_overlay_resolve([A,B], Context, _).

test(malicious_compound_data_is_rejected,
     [throws(style_overlay_fault(unsafe_data(preferred, call(halt))))]) :-
    rule(bad, user_global, any, any, any, call(halt), [], Bad),
    context(project_b, 1, nix, Context),
    style_overlay_resolve([Bad], Context, _).

test(capability_widening_keys_are_rejected,
     [throws(style_overlay_fault(unknown_rule_key(capabilities)))]) :-
    rule(base, user_global, any, any, any, one, [], Base),
    Bad = Base.put(capabilities, [network]),
    context(project_b, 1, nix, Context),
    style_overlay_resolve([Bad], Context, _).

test(unknown_language_fails_closed,
     [throws(style_overlay_fault(unknown_language(rust)))]) :-
    rule(default, library_default, any, any, any, one, [], Default),
    context(project_b, 1, rust, Context),
    style_overlay_resolve([Default], Context, _).

test(nonzero_model_budget_is_rejected,
     [throws(style_overlay_fault(model_calls_must_be_zero(1)))]) :-
    rule(default, library_default, any, any, any, one, [], Default),
    context(project_b, 1, nix, Context0),
    Context = Context0.put(max_model_calls, 1),
    style_overlay_resolve([Default], Context, _).

:- end_tests(rlm_style_overlay).

main(_) :-
    (   run_tests([rlm_style_overlay])
    ->  halt(0)
    ;   halt(1)
    ).
