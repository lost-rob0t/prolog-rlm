:- module(rlm_style_overlay,
          [ rlm_style_overlay_ready/0,
            style_scope_rank/2,
            style_rule_validate/2,
            style_overlay_resolve/3
          ]).

/** <module> Generic deterministic style overlay resolution

This module owns only reusable style-rule validation and overlay selection.
Domain rules and StyleExpert brains are external data.  Resolution is pure,
zero-model, capability-neutral, and scoped by an explicit project identity and
generation supplied by the caller.
*/

:- use_module(library(apply), [include/3]).
:- use_module(library(lists), [member/2, memberchk/2, max_list/2]).
:- use_module(library(pairs), [pairs_keys/2]).

rlm_style_overlay_ready.

style_scope_rank(library_default, 10).
style_scope_rank(user_global, 20).
style_scope_rank(user_language, 30).
style_scope_rank(project_global, 40).
style_scope_rank(project_language, 50).
style_scope_rank(session, 60).

style_rule_validate(Rule0, Context0) :-
    style_context_validate(Context0, Context),
    style_rule_validate_(Rule0, Context, _).

style_overlay_resolve(Rules0, Context0, Result) :-
    style_context_validate(Context0, Context),
    require_rule_list(Rules0),
    validate_rules(Rules0, Context, Rules),
    reject_duplicate_ids(Rules),
    reject_unknown_overrides(Rules),
    reject_override_cycles(Rules),
    reject_stale_project_generations(Rules, Context),
    include(rule_applies(Context), Rules, Applicable),
    applicable_checks(Applicable, Checks),
    resolve_checks(Checks, Rules, Applicable, Effective, Decisions),
    Result = style_overlay{
                 effective:Effective,
                 decisions:Decisions,
                 project_id:Context.project_id,
                 project_generation:Context.project_generation,
                 language:Context.language,
                 usage:style_usage{model_calls:0}
             }.

/* Context ------------------------------------------------------------- */

style_context_validate(Context0, Context) :-
    require_dict(context, Context0),
    allowed_context_keys(Allowed),
    reject_unknown_keys(context, Context0, Allowed),
    require_key(context, Context0, project_id, Project),
    require_key(context, Context0, project_generation, Generation),
    require_key(context, Context0, language, Language),
    require_key(context, Context0, known_languages, KnownLanguages),
    require_key(context, Context0, max_model_calls, MaxModelCalls),
    require_identity(project_id, Project),
    require_nonnegative_integer(project_generation, Generation),
    require_language_atom(Language),
    require_known_languages(KnownLanguages),
    (   MaxModelCalls == 0
    ->  true
    ;   throw(style_overlay_fault(model_calls_must_be_zero(MaxModelCalls)))
    ),
    (   memberchk(Language, KnownLanguages)
    ->  true
    ;   throw(style_overlay_fault(unknown_language(Language)))
    ),
    Context = style_context{
                  project_id:Project,
                  project_generation:Generation,
                  language:Language,
                  known_languages:KnownLanguages,
                  max_model_calls:0
              }.

allowed_context_keys([project_id,
                      project_generation,
                      language,
                      known_languages,
                      max_model_calls]).

require_known_languages(Languages) :-
    is_list(Languages),
    Languages \== [],
    all_atoms(Languages),
    sort(Languages, Unique),
    length(Languages, Count),
    length(Unique, Count),
    !.
require_known_languages(Languages) :-
    throw(style_overlay_fault(invalid_known_languages(Languages))).

all_atoms([]).
all_atoms([Head|Tail]) :-
    atom(Head),
    all_atoms(Tail).

/* Rules --------------------------------------------------------------- */

require_rule_list(Rules) :-
    is_list(Rules),
    !.
require_rule_list(Rules) :-
    throw(style_overlay_fault(invalid_rule_list(Rules))).

validate_rules([], _, []).
validate_rules([Rule0|Rest0], Context, [Rule|Rest]) :-
    style_rule_validate_(Rule0, Context, Rule),
    validate_rules(Rest0, Context, Rest).

style_rule_validate_(Rule0, Context, Rule) :-
    require_dict(rule, Rule0),
    allowed_rule_keys(Allowed),
    reject_unknown_rule_keys(Rule0, Allowed),
    require_key(rule, Rule0, id, Id),
    require_key(rule, Rule0, scope, Scope),
    require_key(rule, Rule0, language, Language),
    require_key(rule, Rule0, project_id, Project),
    require_key(rule, Rule0, project_generation, Generation),
    require_key(rule, Rule0, check, Check),
    require_key(rule, Rule0, preferred, Preferred),
    require_key(rule, Rule0, autofix, Autofix),
    require_key(rule, Rule0, provenance, Provenance),
    require_key(rule, Rule0, revision, Revision),
    require_key(rule, Rule0, overrides, Overrides),
    require_rule_id(Id),
    require_scope(Scope),
    require_rule_language(Language, Context.known_languages),
    require_scope_binding(Scope, Language, Project, Generation),
    require_rule_id(Check),
    require_safe_data(preferred, Preferred),
    require_autofix(Autofix),
    require_dict(provenance, Provenance),
    require_safe_data(provenance, Provenance),
    require_revision(Revision),
    require_overrides(Overrides),
    Rule = style_rule{
               id:Id,
               scope:Scope,
               language:Language,
               project_id:Project,
               project_generation:Generation,
               check:Check,
               preferred:Preferred,
               autofix:Autofix,
               provenance:Provenance,
               revision:Revision,
               overrides:Overrides
           }.

allowed_rule_keys([id,
                   scope,
                   language,
                   project_id,
                   project_generation,
                   check,
                   preferred,
                   autofix,
                   provenance,
                   revision,
                   overrides]).

reject_unknown_rule_keys(Rule, Allowed) :-
    dict_pairs(Rule, _, Pairs),
    pairs_keys(Pairs, Keys),
    (   member(Key, Keys),
        \+ memberchk(Key, Allowed)
    ->  throw(style_overlay_fault(unknown_rule_key(Key)))
    ;   true
    ).

require_rule_id(Id) :-
    atom(Id),
    Id \== '',
    !.
require_rule_id(Id) :-
    throw(style_overlay_fault(invalid_rule_id(Id))).

require_scope(Scope) :-
    style_scope_rank(Scope, _),
    !.
require_scope(Scope) :-
    throw(style_overlay_fault(unknown_scope(Scope))).

require_rule_language(any, _) :- !.
require_rule_language(Language, KnownLanguages) :-
    atom(Language),
    memberchk(Language, KnownLanguages),
    !.
require_rule_language(Language, _) :-
    throw(style_overlay_fault(unknown_language(Language))).

require_scope_binding(library_default, any, any, any) :- !.
require_scope_binding(user_global, any, any, any) :- !.
require_scope_binding(user_language, Language, any, any) :-
    Language \== any,
    !.
require_scope_binding(project_global, any, Project, Generation) :-
    Project \== any,
    require_identity(project_id, Project),
    require_nonnegative_integer(project_generation, Generation),
    !.
require_scope_binding(project_language, Language, Project, Generation) :-
    Language \== any,
    Project \== any,
    require_identity(project_id, Project),
    require_nonnegative_integer(project_generation, Generation),
    !.
require_scope_binding(session, Language, Project, Generation) :-
    Language \== any,
    Project \== any,
    require_identity(project_id, Project),
    require_nonnegative_integer(project_generation, Generation),
    !.
require_scope_binding(Scope, Language, Project, Generation) :-
    throw(style_overlay_fault(invalid_scope_binding(Scope,
                                                    Language,
                                                    Project,
                                                    Generation))).

require_autofix(none) :- !.
require_autofix(manual) :- !.
require_autofix(canonical_edit_verify) :- !.
require_autofix(Autofix) :-
    throw(style_overlay_fault(unsupported_autofix(Autofix))).

require_revision(Revision) :-
    atomic(Revision),
    Revision \== '',
    !.
require_revision(Revision) :-
    throw(style_overlay_fault(invalid_revision(Revision))).

require_overrides(Overrides) :-
    is_list(Overrides),
    all_rule_ids(Overrides),
    sort(Overrides, Unique),
    length(Overrides, Count),
    length(Unique, Count),
    !.
require_overrides(Overrides) :-
    throw(style_overlay_fault(invalid_overrides(Overrides))).

all_rule_ids([]).
all_rule_ids([Id|Rest]) :-
    require_rule_id(Id),
    all_rule_ids(Rest).

/* Closed data --------------------------------------------------------- */

require_safe_data(Field, Value) :-
    acyclic_term(Value),
    safe_data(Value),
    !.
require_safe_data(Field, Value) :-
    throw(style_overlay_fault(unsafe_data(Field, Value))).

safe_data(Value) :-
    nonvar(Value),
    (   atomic(Value)
    ->  true
    ;   is_list(Value)
    ->  safe_data_list(Value)
    ;   is_dict(Value)
    ->  dict_pairs(Value, _, Pairs),
        safe_data_pairs(Pairs)
    ).

safe_data_list([]).
safe_data_list([Head|Tail]) :-
    safe_data(Head),
    safe_data_list(Tail).

safe_data_pairs([]).
safe_data_pairs([Key-Value|Rest]) :-
    atom(Key),
    safe_data(Value),
    safe_data_pairs(Rest).

/* Structural rejection ---------------------------------------------- */

reject_duplicate_ids(Rules) :-
    reject_duplicate_ids(Rules, []).

reject_duplicate_ids([], _).
reject_duplicate_ids([Rule|Rest], Seen) :-
    Id = Rule.id,
    (   memberchk(Id, Seen)
    ->  throw(style_overlay_fault(duplicate_rule_id(Id)))
    ;   reject_duplicate_ids(Rest, [Id|Seen])
    ).

reject_unknown_overrides(Rules) :-
    findall(Id, member_rule_id(Rules, Id), Ids),
    (   member(Rule, Rules),
        member(Target, Rule.overrides),
        \+ memberchk(Target, Ids)
    ->  throw(style_overlay_fault(unknown_override_id(Rule.id, Target)))
    ;   true
    ).

member_rule_id(Rules, Id) :-
    member(Rule, Rules),
    Id = Rule.id.

reject_override_cycles(Rules) :-
    (   member(Rule, Rules),
        Id = Rule.id,
        override_cycle_from(Id, Rules, [Id], Cycle)
    ->  throw(style_overlay_fault(override_cycle(Cycle)))
    ;   true
    ).

override_cycle_from(Id, Rules, Path, Cycle) :-
    rule_by_id(Id, Rules, Rule),
    member(Next, Rule.overrides),
    (   memberchk(Next, Path)
    ->  append(Path, [Next], Cycle)
    ;   append(Path, [Next], NextPath),
        override_cycle_from(Next, Rules, NextPath, Cycle)
    ).

reject_stale_project_generations(Rules, Context) :-
    Project = Context.project_id,
    Current = Context.project_generation,
    (   member(Rule, Rules),
        project_bound_scope(Rule.scope),
        Rule.project_id == Project,
        Rule.project_generation \== Current
    ->  throw(style_overlay_fault(
                  stale_project_generation(Project,
                                           Rule.project_generation,
                                           Current)))
    ;   true
    ).

project_bound_scope(project_global).
project_bound_scope(project_language).
project_bound_scope(session).

/* Selection ----------------------------------------------------------- */

rule_applies(_, Rule) :-
    Rule.scope == library_default,
    !.
rule_applies(_, Rule) :-
    Rule.scope == user_global,
    !.
rule_applies(Context, Rule) :-
    Rule.scope == user_language,
    !,
    Rule.language == Context.language.
rule_applies(Context, Rule) :-
    Rule.scope == project_global,
    !,
    Rule.project_id == Context.project_id,
    Rule.project_generation == Context.project_generation.
rule_applies(Context, Rule) :-
    Rule.scope == project_language,
    !,
    Rule.project_id == Context.project_id,
    Rule.project_generation == Context.project_generation,
    Rule.language == Context.language.
rule_applies(Context, Rule) :-
    Rule.scope == session,
    Rule.project_id == Context.project_id,
    Rule.project_generation == Context.project_generation,
    Rule.language == Context.language.

applicable_checks(Rules, Checks) :-
    findall(Check,
            ( member(Rule, Rules),
              Check = Rule.check
            ),
            Raw),
    sort(Raw, Checks).

resolve_checks([], _, _, [], []).
resolve_checks([Check|Rest], Rules, Applicable,
               [Winner|EffectiveRest], [Decision|DecisionRest]) :-
    rules_for_check(Applicable, Check, Group),
    choose_winner(Check, Applicable, Group, Winner),
    shadowed_rules(Group, Winner.id, Shadowed),
    shadow_ids(Shadowed, ShadowIds),
    shadow_provenance(Shadowed, ShadowProvenance),
    Decision = style_decision{
                   check:Check,
                   winner:Winner.id,
                   winner_scope:Winner.scope,
                   winner_revision:Winner.revision,
                   winner_provenance:Winner.provenance,
                   shadowed:ShadowIds,
                   shadowed_provenance:ShadowProvenance
               },
    resolve_checks(Rest, Rules, Applicable, EffectiveRest, DecisionRest).

rules_for_check(Rules, Check, Group) :-
    include(has_check(Check), Rules, Group).

has_check(Check, Rule) :-
    Rule.check == Check.

choose_winner(Check, Rules, Group, Winner) :-
    findall(Rank,
            ( member(Rule, Group),
              style_scope_rank(Rule.scope, Rank)
            ),
            Ranks),
    max_list(Ranks, Highest),
    include(has_rank(Highest), Group, Top),
    choose_top(Check, Rules, Top, Winner).

has_rank(Rank, Rule) :-
    style_scope_rank(Rule.scope, RuleRank),
    RuleRank =:= Rank.

choose_top(_, _, [Winner], Winner) :- !.
choose_top(Check, Rules, Top, Winner) :-
    findall(Candidate,
            ( member(Candidate, Top),
              overrides_all_top(Candidate, Top, Rules)
            ),
            Candidates),
    (   Candidates = [Winner]
    ->  true
    ;   top_conflict_ids(Top, A, B),
        throw(style_overlay_fault(equal_precedence_conflict(Check, A, B)))
    ).

overrides_all_top(Candidate, Top, Rules) :-
    forall(( member(Other, Top),
             Other.id \== Candidate.id
           ),
           override_reaches(Candidate.id, Other.id, Rules, [])).

override_reaches(From, Target, Rules, Seen) :-
    \+ memberchk(From, Seen),
    rule_by_id(From, Rules, Rule),
    (   memberchk(Target, Rule.overrides)
    ->  true
    ;   member(Next, Rule.overrides),
        override_reaches(Next, Target, Rules, [From|Seen])
    ).

rule_by_id(Id, [Rule|_], Rule) :-
    Rule.id == Id,
    !.
rule_by_id(Id, [_|Rest], Rule) :-
    rule_by_id(Id, Rest, Rule).

top_conflict_ids(Top, A, B) :-
    findall(Id,
            ( member(Rule, Top),
              Id = Rule.id
            ),
            Ids0),
    sort(Ids0, [A,B|_]).

shadowed_rules([], _, []).
shadowed_rules([Rule|Rest], WinnerId, Shadowed) :-
    (   Rule.id == WinnerId
    ->  shadowed_rules(Rest, WinnerId, Shadowed)
    ;   Shadowed = [Rule|Tail],
        shadowed_rules(Rest, WinnerId, Tail)
    ).

shadow_ids([], []).
shadow_ids([Rule|Rest], [Rule.id|Ids]) :-
    shadow_ids(Rest, Ids).

shadow_provenance([], []).
shadow_provenance([Rule|Rest], [Entry|Entries]) :-
    Entry = style_shadow{
                id:Rule.id,
                scope:Rule.scope,
                revision:Rule.revision,
                provenance:Rule.provenance
            },
    shadow_provenance(Rest, Entries).

/* Shared validation helpers ------------------------------------------ */

require_dict(_, Value) :-
    is_dict(Value),
    !.
require_dict(Label, Value) :-
    throw(style_overlay_fault(expected_dict(Label, Value))).

reject_unknown_keys(Label, Dict, Allowed) :-
    dict_pairs(Dict, _, Pairs),
    pairs_keys(Pairs, Keys),
    (   member(Key, Keys),
        \+ memberchk(Key, Allowed)
    ->  throw(style_overlay_fault(unknown_key(Label, Key)))
    ;   true
    ).

require_key(Label, Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(style_overlay_fault(missing_key(Label, Key)))
    ).

require_identity(_, Value) :-
    atom(Value),
    Value \== '',
    Value \== any,
    !.
require_identity(Label, Value) :-
    throw(style_overlay_fault(invalid_identity(Label, Value))).

require_nonnegative_integer(_, Value) :-
    integer(Value),
    Value >= 0,
    !.
require_nonnegative_integer(Label, Value) :-
    throw(style_overlay_fault(invalid_nonnegative_integer(Label, Value))).

require_language_atom(Language) :-
    atom(Language),
    Language \== '',
    Language \== any,
    !.
require_language_atom(Language) :-
    throw(style_overlay_fault(invalid_language(Language))).
