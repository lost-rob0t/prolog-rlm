:- module(rlm_skill_completion,
          [ skill_completion_options/3,
            rlm_skill_completion_ready/0
          ]).

/** <module> Skill compiler bridge for public completion

This module is the boundary between the generic skill compiler and the RLM
planner. It compiles skills before a model request exists and folds the selected
instruction fragment into the trusted planner instruction option. The bridge
never exposes the skill catalog to the model and never grants capabilities.
*/

:- use_module(library(apply)).
:- use_module(rlm_skill).
:- use_module(rlm_skill_mattpocock).

rlm_skill_completion_ready :-
    rlm_skill_mattpocock:rlm_skill_mattpocock_ready,
    skill_completion_options("",
                             [skill_mode(off)],
                             ok(skill_completion{options:_, compiled:_})).

skill_completion_options(Query, Options0, Outcome) :-
    catch(skill_completion_options_(Query, Options0, Outcome),
          Exception,
          completion_skill_exception(Exception, Outcome)).

skill_completion_options_(Query, Options0,
                          ok(skill_completion{options:Options,
                                              compiled:Compiled})) :-
    require_options(Options0),
    completion_skill_catalog(Options0, Catalog, DistributionRules),
    merge_compile_rules(Options0, DistributionRules, CompileOptions),
    skill_compile(Catalog, Query, CompileOptions, CompileOutcome),
    require_skill_compile(CompileOutcome, Compiled),
    skill_prompt_fragment(Compiled, SkillPrompt),
    merge_planner_instruction(Options0, SkillPrompt, Options).

completion_skill_catalog(Options, Catalog, DistributionRules) :-
    option_value(skill_catalog, Options, default, Spec),
    completion_skill_catalog_spec(Spec, Catalog, DistributionRules).

completion_skill_catalog_spec(default, Catalog, Rules) :-
    !,
    skill_default_catalog(Outcome),
    require_catalog_outcome(Outcome, Catalog),
    rlm_skill_mattpocock:mattpocock_skill_rules(Rules).
completion_skill_catalog_spec(none, Catalog, []) :-
    !,
    skill_catalog_empty(Catalog).
completion_skill_catalog_spec(Catalog, Catalog, []) :-
    skill_catalog_skills(Catalog, _),
    !.
completion_skill_catalog_spec(Spec, _, _) :-
    throw(skill_completion_fault(invalid_skill_catalog_option(Spec))).

merge_compile_rules(Options, [], Options) :- !.
merge_compile_rules(Options0, DistributionRules, Options) :-
    option_value(skill_rules, Options0, [], UserRules),
    (   is_list(UserRules)
    ->  true
    ;   throw(skill_completion_fault(invalid_skill_rules(UserRules)))
    ),
    append(DistributionRules, UserRules, Rules),
    exclude(named_option(skill_rules), Options0, Rest),
    Options = [skill_rules(Rules)|Rest].

require_catalog_outcome(ok(Catalog), Catalog) :- !.
require_catalog_outcome(error(Error), _) :-
    throw(skill_completion_fault(default_catalog_failed(Error))).

require_skill_compile(ok(Compiled), Compiled) :- !.
require_skill_compile(error(Error), _) :-
    throw(skill_completion_fault(skill_compile_failed(Error))).

merge_planner_instruction(Options, "", Options) :- !.
merge_planner_instruction(Options0, SkillPrompt, Options) :-
    option_value(planner_instruction, Options0, "", Existing0),
    text_string(Existing0, Existing),
    merged_instruction(SkillPrompt, Existing, Combined),
    exclude(named_option(planner_instruction), Options0, Rest),
    Options = [planner_instruction(Combined)|Rest].

merged_instruction(SkillPrompt, "", SkillPrompt) :- !.
merged_instruction(SkillPrompt, Existing, Combined) :-
    format(string(Combined), "~s\n\n~s", [SkillPrompt, Existing]).

named_option(Name, Option) :-
    nonvar(Option),
    Option =.. [Name, _].

option_value(Name, Options, Default, Value) :-
    (   member(Option, Options),
        nonvar(Option),
        Option =.. [Name, Found]
    ->  Value = Found
    ;   Value = Default
    ).

require_options(Options) :-
    (   is_list(Options)
    ->  true
    ;   throw(skill_completion_fault(invalid_options(Options)))
    ).

text_string(Value, Value) :- string(Value), !.
text_string(Value, Text) :- atom(Value), !, atom_string(Value, Text).
text_string(Value, _) :-
    throw(skill_completion_fault(expected_text(Value))).

completion_skill_exception(skill_completion_fault(Detail),
                           error(skill_completion_error{
                                     kind:skill_compilation_failed,
                                     detail:Detail,
                                     message:"skill compilation failed before planner execution"
                                 })) :-
    !.
completion_skill_exception(Exception,
                           error(skill_completion_error{
                                     kind:exception,
                                     exception:Safe,
                                     message:"skill compilation bridge raised an exception"
                                 })) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).
