:- module(rlm_skill,
          [ rlm_skill_ready/0,
            skill_catalog_load/3,
            bundled_skill_catalog/2,
            bundled_skill_root/1,
            skill_catalog_skills/2,
            skill_compile/4,
            skill_compilation_summary/2,
            skill_explain/3,
            skill_render/2,
            skill_resource_read/4
          ]).

/** <module> Deterministic host-owned SKILL.md selection

`SKILL.md` files are inert instruction data.  Prolog discovers bounded
metadata, selects relevant skills, closes declared skill dependencies, applies
a hard prompt-token ceiling, and only then reads selected Markdown bodies.

Activation is not authorization.  Nothing parsed here becomes executable
Prolog or widens tool, filesystem, network, MCP, process, or model capability.
*/

:- use_module(library(crypto)).
:- use_module(library(filesex)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(ordsets)).
:- use_module(library(readutil)).
:- use_module(rlm_context_budget, [token_count_text/3]).

rlm_skill_ready.

/* Public catalog --------------------------------------------------------- */

skill_catalog_load(Root0, Options, Outcome) :-
    catch(( require_options(Options),
            catalog_root(Root0, Root),
            catalog_limits(Options, Limits),
            scan_skill_files(Root, Limits.max_skills, Paths),
            maplist(load_skill_metadata(Root, Limits), Paths, Skills0),
            predsort(compare_skill_meta, Skills0, Skills),
            ensure_unique_skill_names(Skills),
            catalog_fingerprint(Skills, Fingerprint),
            Catalog = skill_catalog{root:Root,
                                    skills:Skills,
                                    limits:Limits,
                                    fingerprint:Fingerprint},
            Outcome = ok(Catalog)
          ),
          Exception,
          skill_exception(catalog, Exception, Outcome)).

bundled_skill_catalog(Options, Outcome) :-
    (   bundled_skill_root(Root)
    ->  skill_catalog_load(Root, Options, Outcome)
    ;   Outcome = error(skill_error{
                            phase:catalog,
                            kind:bundled_skills_unavailable,
                            message:"bundled skills are not initialized; initialize the pinned third-party submodule"
                        })
    ).

bundled_skill_root(Root) :-
    source_file(rlm_skill:rlm_skill_ready, Source),
    file_directory_name(Source, PrologDir),
    file_directory_name(PrologDir, RepoRoot),
    directory_file_path(RepoRoot,
                        'third_party/mattpocock-skills/skills',
                        Candidate),
    exists_directory(Candidate),
    absolute_file_name(Candidate,
                       Root,
                       [ file_type(directory),
                         access(read),
                         solutions(first)
                       ]).

skill_catalog_skills(Catalog, Skills) :-
    require_catalog(Catalog),
    findall(skill{name:Meta.name,
                  description:Meta.description,
                  explicit_only:Meta.explicit_only,
                  relative_path:Meta.relative_path,
                  priority:Meta.priority,
                  requires:Meta.requires},
            member(Meta, Catalog.skills),
            Skills).

/* Compilation ----------------------------------------------------------- */

skill_compile(Catalog, Input0, Options, Outcome) :-
    catch(( require_catalog(Catalog),
            require_options(Options),
            text_string(Input0, Input),
            compile_options(Options, CompileOptions),
            normalize_skill_names(CompileOptions.explicit_skills,
                                  ExplicitNames),
            ensure_known_explicit_skills(Catalog, ExplicitNames),
            normalize_input(Input, NormalizedInput),
            evaluate_catalog(Catalog.skills,
                             NormalizedInput,
                             ExplicitNames,
                             CompileOptions.minimum_score,
                             Evaluations),
            candidate_evaluations(Evaluations, Candidates),
            initial_rejections(Evaluations, Rejected0),
            select_candidates(Candidates,
                              Catalog,
                              NormalizedInput,
                              ExplicitNames,
                              CompileOptions,
                              [],
                              0,
                              Rejected0,
                              Selected0,
                              PromptTokens,
                              Rejected1),
            stable_unique_selections(Selected0, Selected),
            stable_rejections(Rejected1, Rejected),
            render_selected_skills(Selected, Rendered),
            compilation_fingerprint(Catalog,
                                    Input,
                                    ExplicitNames,
                                    CompileOptions,
                                    Selected,
                                    Rejected,
                                    PromptTokens,
                                    Fingerprint),
            Compilation = skill_compilation{
                              selected:Selected,
                              rejected:Rejected,
                              prompt_tokens:PromptTokens,
                              max_prompt_tokens:CompileOptions.max_prompt_tokens,
                              fingerprint:Fingerprint,
                              rendered:Rendered
                          },
            Outcome = ok(Compilation)
          ),
          Exception,
          skill_exception(compile, Exception, Outcome)).

skill_compilation_summary(Compilation, Summary) :-
    require_compilation(Compilation),
    maplist(selection_summary, Compilation.selected, Selected),
    Summary = skill_compilation_summary{
                  selected:Selected,
                  rejected:Compilation.rejected,
                  prompt_tokens:Compilation.prompt_tokens,
                  max_prompt_tokens:Compilation.max_prompt_tokens,
                  fingerprint:Compilation.fingerprint
              }.

selection_summary(Selection,
                  skill_selection{name:Selection.name,
                                  relative_path:Selection.relative_path,
                                  priority:Selection.priority,
                                  reasons:Selection.reasons,
                                  tokens:Selection.tokens,
                                  token_count:Selection.token_count,
                                  body_hash:Selection.body_hash}).

skill_explain(Compilation, Name0, Outcome) :-
    catch(( require_compilation(Compilation),
            normalize_skill_name(Name0, Name),
            explain_skill(Compilation, Name, Outcome)
          ),
          Exception,
          skill_exception(explain, Exception, Outcome)).

explain_skill(Compilation, Name, ok(selected(Selection))) :-
    member(Selection, Compilation.selected),
    Selection.name == Name,
    !.
explain_skill(Compilation, Name, ok(rejected(Rejection))) :-
    member(Rejection, Compilation.rejected),
    Rejection.name == Name,
    !.
explain_skill(_, Name,
              error(skill_error{phase:explain,
                                kind:unknown_skill,
                                skill:Name,
                                message:"skill is not present in this compilation"})).

skill_render(Compilation, Text) :-
    require_compilation(Compilation),
    Text = Compilation.rendered.

compile_options(Options,
                skill_compile_options{
                    explicit_skills:ExplicitSkills,
                    max_prompt_tokens:MaxPromptTokens,
                    minimum_score:MinimumScore,
                    token_options:TokenOptions
                }) :-
    option(explicit_skills(ExplicitSkills), Options, []),
    option(max_skill_prompt_tokens(MaxPromptTokens), Options, 8192),
    option(minimum_skill_score(MinimumScore), Options, 12),
    option(token_counter(TokenCounter), Options, none),
    require_list(ExplicitSkills, explicit_skills),
    require_positive_integer(MaxPromptTokens, max_skill_prompt_tokens),
    require_nonnegative_integer(MinimumScore, minimum_skill_score),
    token_options(TokenCounter, TokenOptions).

token_options(none, []) :- !.
token_options(TokenCounter, [token_counter(TokenCounter)]) :-
    callable(TokenCounter),
    !.
token_options(TokenCounter, _) :-
    throw(skill_fault(invalid_token_counter(TokenCounter))).

ensure_known_explicit_skills(_, []).
ensure_known_explicit_skills(Catalog, [Name|Names]) :-
    (   catalog_skill(Catalog, Name, _)
    ->  true
    ;   throw(skill_fault(unknown_explicit_skill(Name)))
    ),
    ensure_known_explicit_skills(Catalog, Names).

evaluate_catalog([], _, _, _, []).
evaluate_catalog([Meta|Metas], Input, ExplicitNames, MinimumScore,
                 [Evaluation|Evaluations]) :-
    skill_evaluation(Meta,
                     Input,
                     ExplicitNames,
                     MinimumScore,
                     Evaluation),
    evaluate_catalog(Metas,
                     Input,
                     ExplicitNames,
                     MinimumScore,
                     Evaluations).

skill_evaluation(Meta, Input, ExplicitNames, MinimumScore, Evaluation) :-
    (   memberchk(Meta.name, ExplicitNames)
    ->  Explicit = true,
        Score = 1000000,
        Evidence = [explicit_selection]
    ;   Explicit = false,
        lexical_evidence(Meta, Input, Score, Evidence)
    ),
    skill_negated(Meta, Input, Negated),
    evaluation_state(Meta,
                     Explicit,
                     Negated,
                     Score,
                     MinimumScore,
                     State,
                     StateReasons),
    append(Evidence, StateReasons, Reasons),
    Evaluation = skill_evaluation{
                     name:Meta.name,
                     meta:Meta,
                     explicit:Explicit,
                     negated:Negated,
                     score:Score,
                     priority:Meta.priority,
                     state:State,
                     reasons:Reasons
                 }.

evaluation_state(_, true, _, _, _, candidate, []) :- !.
evaluation_state(Meta, false, _, _, _, rejected,
                 [explicit_selection_required]) :-
    Meta.explicit_only == true,
    !.
evaluation_state(_, false, true, _, _, rejected,
                 [negated_by_input]) :- !.
evaluation_state(_, false, _, Score, MinimumScore, candidate, []) :-
    Score >= MinimumScore,
    !.
evaluation_state(_, false, _, Score, MinimumScore, rejected,
                 [below_relevance_threshold(Score, MinimumScore)]).

candidate_evaluations(Evaluations, Candidates) :-
    include(candidate_evaluation, Evaluations, Candidate0),
    predsort(compare_candidate, Candidate0, Candidates).

candidate_evaluation(Evaluation) :- Evaluation.state == candidate.

compare_candidate(Order, A, B) :-
    candidate_key(A, KeyA),
    candidate_key(B, KeyB),
    compare(KeyOrder, KeyB, KeyA),
    (   KeyOrder == (=)
    ->  compare(Order, A.name, B.name)
    ;   Order = KeyOrder
    ).

candidate_key(Evaluation, key(Explicit, Score, Priority)) :-
    ( Evaluation.explicit == true -> Explicit = 1 ; Explicit = 0 ),
    Score = Evaluation.score,
    Priority = Evaluation.priority.

initial_rejections(Evaluations, Rejections) :-
    findall(skill_rejection{name:Evaluation.name,
                            reasons:Evaluation.reasons},
            ( member(Evaluation, Evaluations),
              Evaluation.state == rejected
            ),
            Rejections).

/* Lexical evidence ------------------------------------------------------ */

lexical_evidence(Meta, Input, Score, Reasons) :-
    skill_display_phrase(Meta.name, NamePhrase),
    phrase_evidence(NamePhrase,
                    Input,
                    name_phrase,
                    60,
                    NameScore,
                    NameReasons),
    list_evidence(Meta.phrases,
                  Input,
                  phrase,
                  45,
                  PhraseScore,
                  PhraseReasons),
    list_evidence(Meta.intents,
                  Input,
                  intent,
                  30,
                  IntentScore,
                  IntentReasons),
    list_evidence(Meta.keywords,
                  Input,
                  keyword,
                  15,
                  KeywordScore,
                  KeywordReasons),
    description_evidence(Meta.description,
                         Input,
                         DescriptionScore,
                         DescriptionReasons),
    Score is NameScore+PhraseScore+IntentScore+KeywordScore+DescriptionScore,
    append([NameReasons,
            PhraseReasons,
            IntentReasons,
            KeywordReasons,
            DescriptionReasons],
           Reasons).

phrase_evidence("", _, _, _, 0, []) :- !.
phrase_evidence(Phrase0, Input, Kind, Weight, Weight, [Reason]) :-
    normalize_input(Phrase0, Phrase),
    Phrase \== "",
    sub_string(Input, _, _, _, Phrase),
    !,
    Reason =.. [Kind, Phrase, Weight].
phrase_evidence(_, _, _, _, 0, []).

list_evidence([], _, _, _, 0, []).
list_evidence([Phrase|Phrases], Input, Kind, Weight, Score, Reasons) :-
    phrase_evidence(Phrase,
                    Input,
                    Kind,
                    Weight,
                    HereScore,
                    HereReasons),
    list_evidence(Phrases,
                  Input,
                  Kind,
                  Weight,
                  RestScore,
                  RestReasons),
    Score is HereScore+RestScore,
    append(HereReasons, RestReasons, Reasons).

description_evidence(Description0, Input, Score, Reasons) :-
    normalize_input(Description0, Description),
    lexical_words(Description, DescriptionWords0),
    lexical_words(Input, InputWords0),
    include(significant_word, DescriptionWords0, DescriptionWords1),
    include(significant_word, InputWords0, InputWords1),
    sort(DescriptionWords1, DescriptionWords),
    sort(InputWords1, InputWords),
    ord_intersection(DescriptionWords, InputWords, Common),
    take(6, Common, Limited),
    length(Limited, Count),
    Score is Count*4,
    findall(description_word(Word, 4), member(Word, Limited), Reasons).

take(0, _, []) :- !.
take(_, [], []) :- !.
take(Count, [Item|Items], [Item|Taken]) :-
    Next is Count-1,
    take(Next, Items, Taken).

significant_word(Word) :-
    string_length(Word, Length),
    Length >= 4,
    \+ stop_word(Word).

stop_word("about").
stop_word("after").
stop_word("based").
stop_word("before").
stop_word("from").
stop_word("into").
stop_word("only").
stop_word("that").
stop_word("their").
stop_word("these").
stop_word("this").
stop_word("those").
stop_word("using").
stop_word("when").
stop_word("with").
stop_word("work").

skill_negated(Meta, Input, true) :-
    skill_display_phrase(Meta.name, NamePhrase),
    NamePhrase \== "",
    member(Prefix,
           ["do not use ", "dont use ", "don t use ", "avoid ", "without "]),
    string_concat(Prefix, NamePhrase, Pattern),
    sub_string(Input, _, _, _, Pattern),
    !.
skill_negated(_, _, false).

/* Dependency closure and budget ---------------------------------------- */

select_candidates([], _, _, _, _, Selected, Tokens, Rejected,
                  Selected, Tokens, Rejected).
select_candidates([Evaluation|Evaluations],
                  Catalog,
                  Input,
                  ExplicitNames,
                  Options,
                  Selected0,
                  Tokens0,
                  Rejected0,
                  Selected,
                  Tokens,
                  Rejected) :-
    (   selected_name(Selected0, Evaluation.name)
    ->  Selected1 = Selected0,
        Tokens1 = Tokens0,
        Rejected1 = Rejected0
    ;   candidate_attempt(Evaluation,
                          Catalog,
                          Input,
                          ExplicitNames,
                          Options,
                          Selected0,
                          Tokens0,
                          Attempt),
        apply_candidate_attempt(Attempt,
                                Evaluation,
                                Selected0,
                                Tokens0,
                                Rejected0,
                                Selected1,
                                Tokens1,
                                Rejected1)
    ),
    select_candidates(Evaluations,
                      Catalog,
                      Input,
                      ExplicitNames,
                      Options,
                      Selected1,
                      Tokens1,
                      Rejected1,
                      Selected,
                      Tokens,
                      Rejected).

candidate_attempt(Evaluation,
                  Catalog,
                  Input,
                  ExplicitNames,
                  Options,
                  Selected,
                  Tokens,
                  Attempt) :-
    catch(( dependency_closure(Catalog,
                               Evaluation.name,
                               Input,
                               ExplicitNames,
                               Closure),
            missing_selection_names(Closure, Selected, NewNames),
            load_selections(NewNames,
                            Evaluation,
                            Catalog,
                            Options.token_options,
                            NewSelections,
                            AddedTokens),
            NewTotal is Tokens+AddedTokens,
            (   NewTotal =< Options.max_prompt_tokens
            ->  append(Selected, NewSelections, Selected1),
                Attempt = selected(Selected1, NewTotal)
            ;   Attempt = budget_exceeded(NewTotal,
                                          Options.max_prompt_tokens)
            )
          ),
          skill_fault(Fault),
          Attempt = dependency_error(Fault)).

apply_candidate_attempt(selected(Selected, Tokens), _, _, _, Rejected,
                        Selected, Tokens, Rejected) :- !.
apply_candidate_attempt(budget_exceeded(Needed, Limit), Evaluation,
                        Selected, Tokens, Rejected0,
                        Selected, Tokens, Rejected) :-
    (   Evaluation.explicit == true
    ->  throw(skill_fault(explicit_skill_budget_exceeded(Evaluation.name,
                                                         Needed,
                                                         Limit)))
    ;   upsert_rejection(
            skill_rejection{
                name:Evaluation.name,
                reasons:[prompt_budget_exceeded(Needed, Limit)|Evaluation.reasons]
            },
            Rejected0,
            Rejected)
    ),
    !.
apply_candidate_attempt(dependency_error(Fault), Evaluation,
                        Selected, Tokens, Rejected0,
                        Selected, Tokens, Rejected) :-
    (   Evaluation.explicit == true
    ->  throw(skill_fault(explicit_skill_dependency_failed(Evaluation.name,
                                                            Fault)))
    ;   upsert_rejection(
            skill_rejection{
                name:Evaluation.name,
                reasons:[dependency_failed(Fault)|Evaluation.reasons]
            },
            Rejected0,
            Rejected)
    ).

dependency_closure(Catalog, Name, Input, ExplicitNames, Closure) :-
    dependency_visit(Catalog,
                     Name,
                     Input,
                     ExplicitNames,
                     [],
                     [],
                     Closure,
                     _).

dependency_visit(_, Name, _, _, Stack, _, _, _) :-
    memberchk(Name, Stack),
    !,
    reverse([Name|Stack], Cycle),
    throw(skill_fault(dependency_cycle(Cycle))).
dependency_visit(_, Name, _, _, _, Visited, [], Visited) :-
    memberchk(Name, Visited),
    !.
dependency_visit(Catalog,
                 Name,
                 Input,
                 ExplicitNames,
                 Stack,
                 Visited0,
                 Closure,
                 Visited) :-
    (   catalog_skill(Catalog, Name, Meta)
    ->  true
    ;   throw(skill_fault(missing_dependency(Name)))
    ),
    dependency_admissible(Meta, Input, ExplicitNames),
    dependency_list(Meta.requires,
                    Catalog,
                    Input,
                    ExplicitNames,
                    [Name|Stack],
                    [Name|Visited0],
                    DependencyClosure,
                    Visited1),
    append(DependencyClosure, [Name], Closure),
    Visited = Visited1.

dependency_list([], _, _, _, _, Visited, [], Visited).
dependency_list([Name|Names],
                Catalog,
                Input,
                ExplicitNames,
                Stack,
                Visited0,
                Closure,
                Visited) :-
    dependency_visit(Catalog,
                     Name,
                     Input,
                     ExplicitNames,
                     Stack,
                     Visited0,
                     Here,
                     Visited1),
    dependency_list(Names,
                    Catalog,
                    Input,
                    ExplicitNames,
                    Stack,
                    Visited1,
                    Rest,
                    Visited),
    append(Here, Rest, Closure).

dependency_admissible(Meta, _, ExplicitNames) :-
    Meta.explicit_only == true,
    !,
    (   memberchk(Meta.name, ExplicitNames)
    ->  true
    ;   throw(skill_fault(explicit_dependency_not_selected(Meta.name)))
    ).
dependency_admissible(Meta, Input, _) :-
    skill_negated(Meta, Input, true),
    !,
    throw(skill_fault(negated_dependency(Meta.name))).
dependency_admissible(_, _, _).

missing_selection_names([], _, []).
missing_selection_names([Name|Names], Selected, Missing) :-
    (   selected_name(Selected, Name)
    ->  Missing = Rest
    ;   Missing = [Name|Rest]
    ),
    missing_selection_names(Names, Selected, Rest).

selected_name(Selected, Name) :-
    member(Selection, Selected),
    Selection.name == Name.

load_selections([], _, _, _, [], 0).
load_selections([Name|Names], Evaluation, Catalog, TokenOptions,
                [Selection|Selections], Tokens) :-
    catalog_skill(Catalog, Name, Meta),
    load_selected_body(Meta,
                       TokenOptions,
                       Body,
                       Rendered,
                       TokenCount,
                       BodyHash),
    selection_reasons(Name, Evaluation, Reasons),
    Selection = skill_selection{
                    name:Name,
                    relative_path:Meta.relative_path,
                    priority:Meta.priority,
                    reasons:Reasons,
                    tokens:TokenCount.tokens,
                    token_count:TokenCount,
                    body_hash:BodyHash,
                    body:Body,
                    rendered:Rendered
                },
    load_selections(Names,
                    Evaluation,
                    Catalog,
                    TokenOptions,
                    Selections,
                    RestTokens),
    Tokens is TokenCount.tokens+RestTokens.

selection_reasons(Name, Evaluation, Reasons) :-
    (   Name == Evaluation.name
    ->  Reasons = Evaluation.reasons
    ;   Reasons = [required_by(Evaluation.name)]
    ).

load_selected_body(Meta, TokenOptions, Body, Rendered,
                   TokenCount, BodyHash) :-
    size_file(Meta.path, Size),
    (   Size =< Meta.max_body_bytes
    ->  true
    ;   throw(skill_fault(skill_body_too_large(Meta.name,
                                               Size,
                                               Meta.max_body_bytes)))
    ),
    read_file_to_string(Meta.path, Content, [encoding(utf8)]),
    strip_frontmatter(Content, Body),
    crypto_data_hash(Body,
                     BodyHash,
                     [algorithm(sha256), encoding(utf8)]),
    format(string(Rendered),
           "<prolog-rlm-skill name=~q>\n~s\n</prolog-rlm-skill>\n",
           [Meta.name, Body]),
    token_count_text(Rendered, TokenOptions, TokenOutcome),
    require_token_count(TokenOutcome, TokenCount).

require_token_count(ok(TokenCount), TokenCount) :- !.
require_token_count(error(Error), _) :-
    throw(skill_fault(token_count_failed(Error))).

upsert_rejection(Rejection, Rejections0, Rejections) :-
    exclude(rejection_named(Rejection.name), Rejections0, Rest),
    Rejections = [Rejection|Rest].

rejection_named(Name, Rejection) :- Rejection.name == Name.

stable_unique_selections(Selections0, Selections) :-
    unique_selections(Selections0, [], Selections).

unique_selections([], _, []).
unique_selections([Selection|Selections], Seen, Unique) :-
    (   memberchk(Selection.name, Seen)
    ->  Unique = Rest,
        Seen1 = Seen
    ;   Unique = [Selection|Rest],
        Seen1 = [Selection.name|Seen]
    ),
    unique_selections(Selections, Seen1, Rest).

stable_rejections(Rejections0, Rejections) :-
    predsort(compare_rejection, Rejections0, Rejections).

compare_rejection(Order, A, B) :- compare(Order, A.name, B.name).

render_selected_skills([], "").
render_selected_skills(Selections, Text) :-
    Selections \== [],
    findall(Rendered,
            ( member(Selection, Selections),
              Rendered = Selection.rendered
            ),
            Parts),
    atomics_to_string([
        "The following skill instructions were selected by the trusted Prolog runtime. They are model-visible instruction data only and grant no execution authority or capabilities.\n\n"
        | Parts
    ], "", Text).

/* Resource confinement -------------------------------------------------- */

skill_resource_read(Catalog, Name0, Relative0, Outcome) :-
    catch(( require_catalog(Catalog),
            normalize_skill_name(Name0, Name),
            (   catalog_skill(Catalog, Name, Meta)
            ->  true
            ;   throw(skill_fault(unknown_skill(Name)))
            ),
            text_atom(Relative0, Relative),
            safe_relative_path(Relative, Segments),
            reject_symlink_path(Meta.directory, Segments),
            directory_file_path(Meta.directory, Relative, Candidate),
            absolute_file_name(Candidate,
                               Absolute,
                               [ file_type(regular),
                                 access(read),
                                 solutions(first)
                               ]),
            ensure_within(Meta.directory, Absolute),
            ensure_within(Catalog.root, Absolute),
            size_file(Absolute, Size),
            (   Size =< Catalog.limits.max_resource_bytes
            ->  true
            ;   throw(skill_fault(resource_too_large(Relative,
                                                     Size,
                                                     Catalog.limits.max_resource_bytes)))
            ),
            read_file_to_string(Absolute, Text, [encoding(utf8)]),
            Outcome = ok(skill_resource{name:Name,
                                        relative_path:Relative,
                                        text:Text})
          ),
          Exception,
          skill_exception(resource, Exception, Outcome)).

safe_relative_path(Relative, Segments) :-
    (   Relative == ''
    ->  throw(skill_fault(invalid_resource_path(Relative)))
    ;   sub_atom(Relative, 0, 1, _, '/')
    ->  throw(skill_fault(resource_path_escape(Relative)))
    ;   atomic_list_concat(Segments0, '/', Relative),
        (   memberchk('..', Segments0)
        ->  throw(skill_fault(resource_path_escape(Relative)))
        ;   true
        ),
        exclude(dot_segment, Segments0, Segments),
        (   Segments == []
        ->  throw(skill_fault(invalid_resource_path(Relative)))
        ;   true
        )
    ).

dot_segment('.').
dot_segment('').

reject_symlink_path(_, []).
reject_symlink_path(Base, [Segment|Segments]) :-
    directory_file_path(Base, Segment, Path),
    (   path_is_symlink(Path)
    ->  throw(skill_fault(symlink_not_allowed(Path)))
    ;   true
    ),
    reject_symlink_path(Path, Segments).

/* Catalog discovery ----------------------------------------------------- */

catalog_limits(Options,
               skill_catalog_limits{
                   max_skills:MaxSkills,
                   max_frontmatter_bytes:MaxFrontmatterBytes,
                   max_body_bytes:MaxBodyBytes,
                   max_resource_bytes:MaxResourceBytes
               }) :-
    option(max_skills(MaxSkills), Options, 2048),
    option(max_frontmatter_bytes(MaxFrontmatterBytes), Options, 65536),
    option(max_skill_body_bytes(MaxBodyBytes), Options, 262144),
    option(max_skill_resource_bytes(MaxResourceBytes), Options, 262144),
    require_positive_integer(MaxSkills, max_skills),
    require_positive_integer(MaxFrontmatterBytes, max_frontmatter_bytes),
    require_positive_integer(MaxBodyBytes, max_skill_body_bytes),
    require_positive_integer(MaxResourceBytes, max_skill_resource_bytes).

catalog_root(Root0, Root) :-
    text_atom(Root0, RootAtom),
    (   path_is_symlink(RootAtom)
    ->  throw(skill_fault(symlink_root_not_allowed(RootAtom)))
    ;   true
    ),
    absolute_file_name(RootAtom,
                       Root,
                       [ file_type(directory),
                         access(read),
                         solutions(first)
                       ]).

scan_skill_files(Root, MaxSkills, Paths) :-
    scan_directory(Root, Root, Paths0),
    sort(Paths0, Paths),
    length(Paths, Count),
    (   Count =< MaxSkills
    ->  true
    ;   throw(skill_fault(skill_count_exceeded(Count, MaxSkills)))
    ).

scan_directory(Root, Directory, Paths) :-
    directory_files(Directory, Entries0),
    exclude(dot_or_hidden_entry, Entries0, Entries1),
    sort(Entries1, Entries),
    scan_entries(Entries, Root, Directory, Paths).

scan_entries([], _, _, []).
scan_entries([Entry|Entries], Root, Directory, Paths) :-
    directory_file_path(Directory, Entry, Path),
    scan_entry(Entry, Path, Root, Here),
    scan_entries(Entries, Root, Directory, Rest),
    append(Here, Rest, Paths).

scan_entry(_, Path, _, _) :-
    path_is_symlink(Path),
    !,
    throw(skill_fault(symlink_not_allowed(Path))).
scan_entry(_, Path, Root, Paths) :-
    exists_directory(Path),
    !,
    scan_directory(Root, Path, Paths).
scan_entry('SKILL.md', Path, Root, [Path]) :-
    exists_file(Path),
    !,
    ensure_within(Root, Path).
scan_entry(_, _, _, []).

dot_or_hidden_entry('.').
dot_or_hidden_entry('..').
dot_or_hidden_entry(Entry) :- atom_chars(Entry, ['.'|_]).

path_is_symlink(Path) :-
    catch(read_link(Path, _, _), _, fail).

ensure_within(Directory, Path) :-
    directory_prefix(Directory, Prefix),
    (   Path == Directory
    ->  true
    ;   atom_concat(Prefix, _, Path)
    ->  true
    ;   throw(skill_fault(path_escape(Path, Directory)))
    ).

directory_prefix(Directory, Prefix) :-
    (   sub_atom(Directory, _, 1, 0, '/')
    ->  Prefix = Directory
    ;   atom_concat(Directory, '/', Prefix)
    ).

load_skill_metadata(Root, Limits, Path, Meta) :-
    file_directory_name(Path, Directory),
    file_base_name(Directory, DefaultName),
    manifest_frontmatter(Path,
                         Limits.max_frontmatter_bytes,
                         Frontmatter),
    metadata_value(Frontmatter, name, DefaultName, Name0),
    normalize_skill_name(Name0, Name),
    metadata_value(Frontmatter, description, "", Description0),
    text_string(Description0, Description),
    metadata_explicit_only(Frontmatter, ExplicitOnly),
    metadata_list(Frontmatter, phrases, [], Phrases0),
    metadata_list(Frontmatter, 'trigger-phrases', Phrases0, Phrases1),
    normalize_text_list(Phrases1, Phrases),
    metadata_list(Frontmatter, keywords, [], Keywords0),
    normalize_text_list(Keywords0, Keywords),
    metadata_list(Frontmatter, intents, [], Intents0),
    normalize_text_list(Intents0, Intents),
    metadata_list(Frontmatter, requires, [], Requires0),
    normalize_skill_names(Requires0, Requires),
    metadata_value(Frontmatter, priority, 0, Priority0),
    normalize_priority(Priority0, Priority),
    relative_path(Root, Path, RelativePath),
    Meta = skill_meta{
               name:Name,
               description:Description,
               explicit_only:ExplicitOnly,
               path:Path,
               directory:Directory,
               relative_path:RelativePath,
               phrases:Phrases,
               keywords:Keywords,
               intents:Intents,
               requires:Requires,
               priority:Priority,
               max_body_bytes:Limits.max_body_bytes
           }.

manifest_frontmatter(Path, MaxBytes, Pairs) :-
    setup_call_cleanup(
        open(Path, read, Stream, [encoding(utf8)]),
        read_frontmatter(Stream, MaxBytes, Pairs),
        close(Stream)).

read_frontmatter(Stream, MaxBytes, Pairs) :-
    read_line_to_string(Stream, First0),
    strip_cr(First0, First),
    (   First == "---"
    ->  read_frontmatter_lines(Stream, MaxBytes, 0, Lines),
        maplist(parse_frontmatter_line, Lines, Parsed),
        exclude(empty_metadata_pair, Parsed, Pairs0),
        ensure_unique_metadata_keys(Pairs0),
        Pairs = Pairs0
    ;   Pairs = []
    ).

read_frontmatter_lines(Stream, MaxBytes, Used0, Lines) :-
    read_line_to_string(Stream, Line0),
    (   Line0 == end_of_file
    ->  throw(skill_fault(unterminated_frontmatter))
    ;   strip_cr(Line0, Line),
        string_length(Line, LineChars),
        Used is Used0+LineChars+1,
        (   Used =< MaxBytes
        ->  true
        ;   throw(skill_fault(frontmatter_too_large(Used, MaxBytes)))
        ),
        (   Line == "---"
        ->  Lines = []
        ;   Lines = [Line|Rest],
            read_frontmatter_lines(Stream, MaxBytes, Used, Rest)
        )
    ).

parse_frontmatter_line(Line0, Pair) :-
    normalize_space(string(Line), Line0),
    (   Line == ""
    ->  Pair = none-none
    ;   sub_string(Line, 0, 1, _, "#")
    ->  Pair = none-none
    ;   sub_string(Line, Before, 1, After, ":")
    ->  sub_string(Line, 0, Before, _, Key0),
        ValueStart is Before+1,
        sub_string(Line, ValueStart, After, 0, Value0),
        normalize_space(string(KeyText0), Key0),
        string_lower(KeyText0, KeyText),
        atom_string(Key, KeyText),
        normalize_space(string(ValueText), Value0),
        parse_metadata_value(ValueText, Value),
        Pair = Key-Value
    ;   throw(skill_fault(invalid_frontmatter_line(Line0)))
    ).

empty_metadata_pair(none-none).

ensure_unique_metadata_keys(Pairs) :-
    findall(Key, member(Key-_, Pairs), Keys),
    sort(Keys, Unique),
    length(Keys, Count),
    length(Unique, Count),
    !.
ensure_unique_metadata_keys(_) :-
    throw(skill_fault(duplicate_frontmatter_key)).

parse_metadata_value("", "") :- !.
parse_metadata_value("true", true) :- !.
parse_metadata_value("false", false) :- !.
parse_metadata_value(Text, Number) :-
    catch(number_string(Number0, Text), _, fail),
    integer(Number0),
    !,
    Number = Number0.
parse_metadata_value(Text, Values) :-
    sub_string(Text, 0, 1, _, "["),
    sub_string(Text, _, 1, 0, "]"),
    !,
    string_length(Text, Length),
    InnerLength is Length-2,
    sub_string(Text, 1, InnerLength, 1, Inner),
    normalize_space(string(Trimmed), Inner),
    parse_inline_list(Trimmed, Values).
parse_metadata_value(Text, Value) :- unquote_string(Text, Value).

parse_inline_list("", []) :- !.
parse_inline_list(Text, Values) :-
    split_string(Text, ",", " ", Parts),
    maplist(unquote_string, Parts, Values).

unquote_string(Text0, Text) :-
    normalize_space(string(Trimmed), Text0),
    string_length(Trimmed, Length),
    Length >= 2,
    sub_string(Trimmed, 0, 1, _, Quote),
    memberchk(Quote, ["\"", "'"]),
    sub_string(Trimmed, _, 1, 0, Quote),
    !,
    InnerLength is Length-2,
    sub_string(Trimmed, 1, InnerLength, 1, Text).
unquote_string(Text, Text).

metadata_value(Pairs, Key, Default, Value) :-
    ( memberchk(Key-Found, Pairs) -> Value = Found ; Value = Default ).

metadata_list(Pairs, Key, Default, Values) :-
    metadata_value(Pairs, Key, Default, Raw),
    (   is_list(Raw)
    ->  Values = Raw
    ;   Raw == ""
    ->  Values = []
    ;   Values = [Raw]
    ).

metadata_explicit_only(Pairs, true) :-
    (   metadata_boolean(Pairs, 'explicit-user-only', false, true)
    ;   metadata_boolean(Pairs, 'disable-model-invocation', false, true)
    ;   metadata_boolean(Pairs, 'user-invocable-only', false, true)
    ),
    !.
metadata_explicit_only(_, false).

metadata_boolean(Pairs, Key, Default, Value) :-
    metadata_value(Pairs, Key, Default, Raw),
    (   memberchk(Raw, [true, false])
    ->  Value = Raw
    ;   throw(skill_fault(invalid_boolean_metadata(Key, Raw)))
    ).

normalize_priority(Priority, Priority) :- integer(Priority), !.
normalize_priority(Value, _) :- throw(skill_fault(invalid_priority(Value))).

normalize_text_list(Values0, Values) :-
    maplist(text_string, Values0, Values1),
    sort(Values1, Values).

normalize_skill_names(Names0, Names) :-
    maplist(normalize_skill_name, Names0, Names1),
    sort(Names1, Names).

compare_skill_meta(Order, A, B) :- compare(Order, A.name, B.name).

ensure_unique_skill_names(Skills) :-
    findall(Name, (member(Meta, Skills), Name = Meta.name), Names),
    sort(Names, Unique),
    length(Names, Count),
    length(Unique, Count),
    !.
ensure_unique_skill_names(_) :- throw(skill_fault(duplicate_skill_name)).

catalog_skill(Catalog, Name, Meta) :-
    member(Meta, Catalog.skills),
    Meta.name == Name,
    !.

relative_path(Root, Path, Relative) :-
    directory_prefix(Root, Prefix),
    atom_concat(Prefix, Relative, Path),
    !.
relative_path(Root, Path, _) :- throw(skill_fault(path_escape(Path, Root))).

strip_frontmatter(Content, Body) :-
    split_string(Content, "\n", "", Lines),
    (   Lines = [First|Rest],
        strip_cr(First, "---")
    ->  drop_frontmatter(Rest, BodyLines),
        atomics_to_string(BodyLines, "\n", Body)
    ;   Body = Content
    ).

drop_frontmatter([], _) :- throw(skill_fault(unterminated_frontmatter)).
drop_frontmatter([Line|Lines], BodyLines) :-
    strip_cr(Line, Clean),
    (   Clean == "---"
    ->  BodyLines = Lines
    ;   drop_frontmatter(Lines, BodyLines)
    ).

strip_cr(end_of_file, end_of_file) :- !.
strip_cr(Line0, Line) :-
    (   sub_string(Line0, Before, 1, 0, "\r")
    ->  sub_string(Line0, 0, Before, _, Line)
    ;   Line = Line0
    ).

/* Fingerprints ---------------------------------------------------------- */

catalog_fingerprint(Skills, Fingerprint) :-
    findall(skill(Meta.name,
                  Meta.description,
                  Meta.explicit_only,
                  Meta.relative_path,
                  Meta.phrases,
                  Meta.keywords,
                  Meta.intents,
                  Meta.requires,
                  Meta.priority),
            member(Meta, Skills),
            Canonical),
    stable_hash(Canonical, Fingerprint).

compilation_fingerprint(Catalog,
                        Input,
                        ExplicitNames,
                        Options,
                        Selected,
                        Rejected,
                        PromptTokens,
                        Fingerprint) :-
    findall(selected(Selection.name,
                     Selection.body_hash,
                     Selection.tokens,
                     Selection.reasons),
            member(Selection, Selected),
            SelectedCanonical),
    Canonical = skill_compile(Catalog.fingerprint,
                              Input,
                              ExplicitNames,
                              Options.max_prompt_tokens,
                              Options.minimum_score,
                              SelectedCanonical,
                              Rejected,
                              PromptTokens),
    stable_hash(Canonical, Fingerprint).

stable_hash(Term, Hash) :-
    term_string(Term,
                Text,
                [ quoted(true),
                  numbervars(true),
                  ignore_ops(true)
                ]),
    crypto_data_hash(Text, Hash, [algorithm(sha256), encoding(utf8)]).

/* Helpers and error normalization -------------------------------------- */

require_catalog(Catalog) :-
    is_dict(Catalog, skill_catalog),
    get_dict(root, Catalog, Root),
    atom(Root),
    get_dict(skills, Catalog, Skills),
    is_list(Skills),
    get_dict(limits, Catalog, Limits),
    is_dict(Limits),
    get_dict(fingerprint, Catalog, _),
    !.
require_catalog(Catalog) :- throw(skill_fault(invalid_catalog(Catalog))).

require_compilation(Compilation) :-
    is_dict(Compilation, skill_compilation),
    get_dict(selected, Compilation, Selected),
    is_list(Selected),
    get_dict(rejected, Compilation, Rejected),
    is_list(Rejected),
    get_dict(fingerprint, Compilation, _),
    !.
require_compilation(Compilation) :-
    throw(skill_fault(invalid_compilation(Compilation))).

require_options(Options) :- is_list(Options), !.
require_options(Options) :- throw(skill_fault(invalid_options(Options))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Name) :- throw(skill_fault(invalid_list(Name, Value))).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Name) :-
    throw(skill_fault(invalid_positive_integer(Name, Value))).

require_nonnegative_integer(Value, _) :- integer(Value), Value >= 0, !.
require_nonnegative_integer(Value, Name) :-
    throw(skill_fault(invalid_nonnegative_integer(Name, Value))).

normalize_skill_name(Name0, Name) :-
    text_atom(Name0, Candidate0),
    downcase_atom(Candidate0, Candidate),
    atom_chars(Candidate, Chars),
    Chars \== [],
    maplist(safe_skill_name_char, Chars),
    !,
    Name = Candidate.
normalize_skill_name(Name, _) :- throw(skill_fault(invalid_skill_name(Name))).

safe_skill_name_char(Char) :- char_type(Char, alnum), !.
safe_skill_name_char('-').
safe_skill_name_char('_').
safe_skill_name_char('.').

skill_display_phrase(Name, Phrase) :-
    atom_string(Name, Text),
    split_string(Text, "-_", "", Parts),
    atomics_to_string(Parts, " ", Phrase0),
    normalize_input(Phrase0, Phrase).

normalize_input(Text0, Normalized) :-
    text_string(Text0, Text),
    string_lower(Text, Lower),
    string_codes(Lower, Codes0),
    maplist(normalize_input_code, Codes0, Codes),
    string_codes(Spaced, Codes),
    normalize_space(string(Normalized), Spaced).

normalize_input_code(Code, 32) :-
    \+ code_type(Code, alnum),
    !.
normalize_input_code(Code, Code).

lexical_words("", []) :- !.
lexical_words(Text, Words) :- split_string(Text, " ", " ", Words).

text_atom(Value, Atom) :- atom(Value), !, Atom = Value.
text_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
text_atom(Value, _) :- throw(skill_fault(expected_text(Value))).

text_string(Value, String) :- string(Value), !, String = Value.
text_string(Value, String) :- atom(Value), !, atom_string(Value, String).
text_string(Value, _) :- throw(skill_fault(expected_text(Value))).

skill_exception(Phase, skill_fault(Fault), error(Error)) :-
    !,
    Error = skill_error{phase:Phase,
                        kind:rejected,
                        detail:Fault,
                        message:"skill compiler rejected invalid, unsafe, or unsatisfied input"}.
skill_exception(Phase, error(existence_error(source_sink, Path), _), error(Error)) :-
    !,
    Error = skill_error{phase:Phase,
                        kind:not_found,
                        path:Path,
                        message:"skill catalog path or resource was not found"}.
skill_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = skill_error{phase:Phase,
                        kind:exception,
                        exception:Safe,
                        message:"skill compiler operation failed"}.

safe_exception(Exception, Safe) :-
    catch(term_string(Exception,
                      Text,
                      [quoted(true), numbervars(true)]),
          _,
          Text = "unprintable_exception"),
    string_length(Text, Length),
    PrefixLength is min(512, Length),
    sub_string(Text, 0, PrefixLength, _, Safe).
