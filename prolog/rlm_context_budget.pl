:- module(rlm_context_budget,
          [ rlm_context_budget_ready/0,
            default_context_policy/1,
            context_policy/2,
            token_count_text/3,
            context_section/5,
            context_pack/4
          ]).

/** <module> Token-budgeted provider-visible context packing

This module owns the hard arithmetic boundary for provider-visible context.
Callers describe fixed rendered sections plus selectable units.  A unit may
have multiple representations with different token costs and utilities.  CLPFD
selects exactly one representation per unit and maximizes utility without
crossing the effective context ceiling.

The provider's physical context window and the operator's working cap are
separate.  The smaller value wins.  Output reserve and safety margin are
charged before selectable context is admitted.
*/

:- use_module(library(clpfd)).
:- use_module(library(option)).

rlm_context_budget_ready.

default_context_policy(
    context_policy{max_context_tokens:131072,
                   provider_context_tokens:131072,
                   reserve_output_tokens:16384,
                   safety_margin_tokens:4096,
                   min_recent_turns:12,
                   overflow:deny}).

context_policy(Input, Outcome) :-
    catch(( context_policy_(Input, Policy),
            Outcome = ok(Policy)
          ),
          Exception,
          budget_exception(policy, Exception, Outcome)).

context_policy_(Input, Policy) :-
    default_context_policy(Default),
    (   is_dict(Input)
    ->  put_dict(Input, Default, Candidate)
    ;   is_list(Input)
    ->  options_policy(Input, Default, Candidate)
    ;   throw(context_budget_fault(invalid_policy(Input)))
    ),
    validate_policy(Candidate),
    Effective is min(Candidate.max_context_tokens,
                     Candidate.provider_context_tokens),
    put_dict(effective_context_tokens, Candidate, Effective, Policy).

options_policy(Options, Default, Policy) :-
    option(max_context_tokens(Max),
           Options,
           Default.max_context_tokens),
    option(provider_context_tokens(ProviderMax),
           Options,
           Default.provider_context_tokens),
    option(reserve_output_tokens(Reserve),
           Options,
           Default.reserve_output_tokens),
    option(safety_margin_tokens(Safety),
           Options,
           Default.safety_margin_tokens),
    option(min_recent_turns(MinRecent),
           Options,
           Default.min_recent_turns),
    option(overflow(Overflow), Options, Default.overflow),
    Policy = Default.put(_{max_context_tokens:Max,
                           provider_context_tokens:ProviderMax,
                           reserve_output_tokens:Reserve,
                           safety_margin_tokens:Safety,
                           min_recent_turns:MinRecent,
                           overflow:Overflow}).

validate_policy(Policy) :-
    require_positive_integer(Policy.max_context_tokens,
                             max_context_tokens),
    require_positive_integer(Policy.provider_context_tokens,
                             provider_context_tokens),
    require_nonnegative_integer(Policy.reserve_output_tokens,
                                reserve_output_tokens),
    require_nonnegative_integer(Policy.safety_margin_tokens,
                                safety_margin_tokens),
    require_nonnegative_integer(Policy.min_recent_turns,
                                min_recent_turns),
    (   Policy.overflow == deny
    ->  true
    ;   throw(context_budget_fault(unsupported_overflow(Policy.overflow)))
    ).

token_count_text(Text0, Options, Outcome) :-
    catch(( require_text(Text0, Text),
            require_options(Options),
            token_count_text_(Text, Options, Count),
            Outcome = ok(Count)
          ),
          Exception,
          budget_exception(token_count, Exception, Outcome)).

token_count_text_(Text, Options, Count) :-
    option(token_counter(Counter), Options, none),
    (   Counter == none
    ->  string_length(Text, Chars),
        Tokens is max(1, (Chars*115+399)//400),
        Count = token_count{tokens:Tokens,
                            method:estimated,
                            basis:characters,
                            safety_percent:15}
    ;   callable(Counter)
    ->  call(Counter, Text, Tokens),
        require_nonnegative_integer(Tokens, token_counter_result),
        Count = token_count{tokens:Tokens,
                            method:exact,
                            basis:registered_counter}
    ;   throw(context_budget_fault(invalid_token_counter(Counter)))
    ).

context_section(Name0, Visibility0, Text0, Options, Outcome) :-
    catch(( normalize_name(Name0, Name),
            normalize_visibility(Visibility0, Visibility),
            require_text(Text0, Text),
            token_count_text_(Text, Options, Count),
            Section = context_section{name:Name,
                                      visibility:Visibility,
                                      tokens:Count.tokens,
                                      token_count:Count},
            Outcome = ok(Section)
          ),
          Exception,
          budget_exception(section, Exception, Outcome)).

context_pack(Units, Sections, PolicyInput, Outcome) :-
    catch(( context_policy_(PolicyInput, Policy),
            context_pack_(Units, Sections, Policy, Pack),
            Outcome = ok(Pack)
          ),
          Exception,
          budget_exception(pack, Exception, Outcome)).

context_pack_(Units0, Sections0, Policy, Pack) :-
    require_list(Units0, units),
    require_list(Sections0, sections),
    maplist(normalize_section, Sections0, Sections),
    maplist(normalize_unit, Units0, Units),
    sections_token_totals(Sections, VisibleFixed, HostOnly),
    Base is VisibleFixed
            + Policy.reserve_output_tokens
            + Policy.safety_margin_tokens,
    Effective = Policy.effective_context_tokens,
    (   Base =< Effective
    ->  true
    ;   throw(context_budget_fault(fixed_context_exceeds_limit(Base,
                                                               Effective)))
    ),
    solve_units(Units,
                Effective-Base,
                Selected,
                SelectedTokens,
                Utility),
    Total is Base+SelectedTokens,
    Remaining is Effective-Total,
    Ledger = token_ledger{limit:Effective,
                          operator_limit:Policy.max_context_tokens,
                          provider_limit:Policy.provider_context_tokens,
                          visible_fixed_tokens:VisibleFixed,
                          host_only_metadata_tokens:HostOnly,
                          selected_context_tokens:SelectedTokens,
                          reserve_output_tokens:Policy.reserve_output_tokens,
                          safety_margin_tokens:Policy.safety_margin_tokens,
                          total_tokens:Total,
                          remaining_tokens:Remaining,
                          sections:Sections},
    Pack = context_pack{policy:Policy,
                        selected:Selected,
                        utility:Utility,
                        ledger:Ledger}.

solve_units([], _, [], 0, 0) :- !.
solve_units(Units, Available, Selected, SelectedTokens, Utility) :-
    build_unit_constraints(Units,
                           Indexes,
                           TokenVars,
                           UtilityVars,
                           VariantSets),
    sum(TokenVars, #=, SelectedTokensFD),
    sum(UtilityVars, #=, UtilityFD),
    SelectedTokensFD #=< Available,
    labeling([max(UtilityFD), ffc, bisect], Indexes),
    SelectedTokens #= SelectedTokensFD,
    Utility #= UtilityFD,
    maplist(selected_variant,
            Units,
            VariantSets,
            Indexes,
            Selected0),
    exclude(omitted_selection, Selected0, Selected).

build_unit_constraints([], [], [], [], []).
build_unit_constraints([Unit|Units],
                       [Index|Indexes],
                       [Token|Tokens],
                       [Utility|Utilities],
                       [Variants|VariantSets]) :-
    unit_variants(Unit, Variants),
    length(Variants, Count),
    Index in 1..Count,
    maplist(variant_tokens, Variants, TokenCosts),
    maplist(variant_utility, Variants, UtilityScores),
    element(Index, TokenCosts, Token),
    element(Index, UtilityScores, Utility),
    build_unit_constraints(Units,
                           Indexes,
                           Tokens,
                           Utilities,
                           VariantSets).

unit_variants(Unit, Variants) :-
    (   Unit.mandatory == true
    ->  exclude(variant_is_omitted, Unit.variants, Required),
        (   Required == []
        ->  throw(context_budget_fault(mandatory_unit_has_no_visible_variant(Unit.id)))
        ;   Variants = Required
        )
    ;   ensure_omitted_variant(Unit.variants, Variants)
    ).

ensure_omitted_variant(Variants, Variants) :-
    member(Variant, Variants),
    Variant.kind == omitted,
    !.
ensure_omitted_variant(Variants,
                       [context_variant{kind:omitted,
                                        tokens:0,
                                        utility:0,
                                        value:none}|Variants]).

variant_is_omitted(Variant) :- Variant.kind == omitted.
variant_tokens(Variant, Variant.tokens).
variant_utility(Variant, Variant.utility).

selected_variant(Unit, Variants, Index, Selection) :-
    nth1(Index, Variants, Variant),
    Selection = context_selection{id:Unit.id,
                                  section:Unit.section,
                                  kind:Variant.kind,
                                  tokens:Variant.tokens,
                                  utility:Variant.utility,
                                  value:Variant.value}.

omitted_selection(Selection) :- Selection.kind == omitted.

normalize_unit(Unit0, Unit) :-
    (   is_dict(Unit0),
        get_dict(id, Unit0, Id0),
        get_dict(section, Unit0, Section0),
        get_dict(variants, Unit0, Variants0)
    ->  normalize_name(Id0, Id),
        normalize_name(Section0, Section),
        require_list(Variants0, variants),
        Variants0 \== [],
        maplist(normalize_variant, Variants0, Variants),
        dict_default(Unit0, mandatory, false, Mandatory),
        require_boolean(Mandatory, mandatory),
        Unit = context_unit{id:Id,
                            section:Section,
                            mandatory:Mandatory,
                            variants:Variants}
    ;   throw(context_budget_fault(invalid_unit(Unit0)))
    ).

normalize_variant(Variant0, Variant) :-
    (   is_dict(Variant0),
        get_dict(kind, Variant0, Kind0),
        get_dict(tokens, Variant0, Tokens),
        get_dict(utility, Variant0, Utility),
        get_dict(value, Variant0, Value)
    ->  normalize_name(Kind0, Kind),
        require_nonnegative_integer(Tokens, variant_tokens),
        require_nonnegative_integer(Utility, variant_utility),
        require_ground(Value, variant_value),
        Variant = context_variant{kind:Kind,
                                  tokens:Tokens,
                                  utility:Utility,
                                  value:Value}
    ;   throw(context_budget_fault(invalid_variant(Variant0)))
    ).

normalize_section(Section0, Section) :-
    (   is_dict(Section0),
        get_dict(name, Section0, Name0),
        get_dict(visibility, Section0, Visibility0),
        get_dict(tokens, Section0, Tokens)
    ->  normalize_name(Name0, Name),
        normalize_visibility(Visibility0, Visibility),
        require_nonnegative_integer(Tokens, section_tokens),
        Section = Section0.put(_{name:Name,
                                 visibility:Visibility,
                                 tokens:Tokens})
    ;   throw(context_budget_fault(invalid_section(Section0)))
    ).

sections_token_totals(Sections, Visible, HostOnly) :-
    findall(Tokens,
            ( member(Section, Sections),
              Section.visibility == model,
              Tokens = Section.tokens ),
            VisibleTokens),
    findall(Tokens,
            ( member(Section, Sections),
              Section.visibility == host,
              Tokens = Section.tokens ),
            HostTokens),
    sum_list(VisibleTokens, Visible),
    sum_list(HostTokens, HostOnly).

normalize_visibility(model, model) :- !.
normalize_visibility(host, host) :- !.
normalize_visibility(Visibility, _) :-
    throw(context_budget_fault(invalid_visibility(Visibility))).

normalize_name(Value, Atom) :- atom(Value), !, Atom = Value.
normalize_name(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
normalize_name(Value, _) :-
    throw(context_budget_fault(expected_name(Value))).

require_text(Value, Text) :- string(Value), !, Text = Value.
require_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
require_text(Value, _) :- throw(context_budget_fault(expected_text(Value))).

require_options(Value) :- is_list(Value), !.
require_options(Value) :- throw(context_budget_fault(expected_options(Value))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Name) :-
    throw(context_budget_fault(expected_list(Name, Value))).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Name) :-
    throw(context_budget_fault(non_ground(Name, Value))).

require_boolean(true, _) :- !.
require_boolean(false, _) :- !.
require_boolean(Value, Name) :-
    throw(context_budget_fault(expected_boolean(Name, Value))).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Name) :-
    throw(context_budget_fault(expected_positive_integer(Name, Value))).

require_nonnegative_integer(Value, _) :- integer(Value), Value >= 0, !.
require_nonnegative_integer(Value, Name) :-
    throw(context_budget_fault(expected_nonnegative_integer(Name, Value))).

dict_default(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

budget_exception(Phase, context_budget_fault(Detail), error(Error)) :-
    !,
    Error = context_budget_error{phase:Phase,
                                 kind:validation_error,
                                 detail:Detail,
                                 message:"context budget validation failed"}.
budget_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = context_budget_error{phase:Phase,
                                 kind:exception,
                                 exception:Safe,
                                 message:"context budget operation raised an exception"}.

safe_exception(Exception, Safe) :-
    (   ground(Exception)
    ->  with_output_to(string(Safe),
                       write_term(Exception,
                                  [ quoted(true),
                                    portray(false),
                                    max_depth(8)
                                  ]))
    ;   Safe = "non-ground exception"
    ).
