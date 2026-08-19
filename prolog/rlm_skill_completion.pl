:- module(rlm_skill_completion,
          [ skill_completion_options/3,
            rlm_skill_completion_ready/0,
            install_completion_skill_wrapper/0
          ]).

/** <module> Skill compiler bridge for canonical completion

This module is the boundary between the generic skill compiler and the RLM
planner. It compiles skills before a planner request exists and folds the
selected instruction fragment into the trusted planner instruction option.
The bridge never exposes the skill catalog to the model and never grants
capabilities.

The canonical completion guard is decorated with SWI-Prolog's predicate wrapper
facility. Wrapping the guarded operation rather than the public async scheduler
keeps file/catalog work inside the scheduled completion task and covers callers
that use the low-level completion module through managed conversation or CLI
facades. A compilation fingerprint marker prevents nested/public facades from
injecting the same skill instructions twice.
*/

:- use_module(library(apply)).
:- use_module(library(prolog_wrap)).
:- use_module(rlm_completion, []).
:- use_module(rlm_skill).
:- use_module(rlm_skill_mattpocock).

:- initialization(install_completion_skill_wrapper).

rlm_skill_completion_ready :-
    rlm_skill_mattpocock:rlm_skill_mattpocock_ready,
    install_completion_skill_wrapper,
    skill_completion_options("",
                             [skill_mode(off)],
                             ok(skill_completion{options:_, compiled:_})).

install_completion_skill_wrapper :-
    prolog_wrap:wrap_predicate(
        rlm_completion:rlm_completion_guarded(Query,
                                              Context,
                                              Options,
                                              Outcome),
        prolog_rlm_skill_compiler,
        Wrapped,
        rlm_skill_completion:completion_guarded_with_skills(
            Wrapped,
            Query,
            Context,
            Options,
            Outcome)).

completion_guarded_with_skills(call(Closure),
                               Query,
                               Context,
                               Options,
                               Outcome) :-
    (   skill_compiled_marker(Options)
    ->  call_completion_closure(Closure,
                                Query,
                                Context,
                                Options,
                                Outcome)
    ;   skill_completion_options(Query, Options, SkillOutcome),
        completion_guard_after_skills(SkillOutcome,
                                      Closure,
                                      Query,
                                      Context,
                                      Outcome)
    ).

completion_guard_after_skills(ok(Prepared),
                              Closure,
                              Query,
                              Context,
                              Outcome) :-
    !,
    call_completion_closure(Closure,
                            Query,
                            Context,
                            Prepared.options,
                            Outcome).
completion_guard_after_skills(error(Error), _, _, _, error(CompletionError)) :-
    CompletionError = completion_error{
                          phase:prompt_compile,
                          kind:skill_compilation_failed,
                          cause:Error,
                          message:"Prolog skill compilation failed before planner execution"
                      }.

call_completion_closure(Closure, Query, Context, Options, Outcome) :-
    functor(Closure, ClosureBlob, 4),
    call(ClosureBlob, Query, Context, Options, Outcome).

skill_compiled_marker(Options) :-
    is_list(Options),
    memberchk(skill_compiled(_), Options).

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
    merge_planner_instruction(Options0, SkillPrompt, PromptOptions),
    mark_skill_compiled(PromptOptions, Compiled.fingerprint, Options).

completion_skill_catalog(Options, Catalog, DistributionRules) :-
    option_value(skill_catalog, Options, default, Spec),
    completion_skill_catalog_spec(Spec, Catalog, DistributionRules).

completion_skill_catalog_spec(default, Catalog, Rules) :-
    !,
    default_completion_skill_catalog(Outcome),
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

/* Prefer the complete pinned upstream collection when its submodule is
   initialized. Source archives and ordinary CI clones fall back to the
   vendored stable corpus, so skill compilation never performs a network fetch. */
default_completion_skill_catalog(Outcome) :-
    complete_mattpocock_skill_root(Root),
    exists_directory(Root),
    !,
    skill_catalog_load([skill_root(mattpocock, Root)], [], Outcome).
default_completion_skill_catalog(Outcome) :-
    skill_default_catalog(Outcome).

complete_mattpocock_skill_root(Root) :-
    source_file(rlm_skill_completion:rlm_skill_completion_ready, Source),
    file_directory_name(Source, PrologDir),
    file_directory_name(PrologDir, RepoRoot),
    directory_file_path(RepoRoot,
                        'third_party/mattpocock-skills/upstream/skills',
                        Root).

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

mark_skill_compiled(Options0, Fingerprint, Options) :-
    exclude(named_option(skill_compiled), Options0, Rest),
    Options = [skill_compiled(Fingerprint)|Rest].

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
