:- module(rlm_skill,
          [ rlm_skill_ready/0,
            skill_catalog_empty/1,
            skill_catalog_load/3,
            skill_catalog_merge/3,
            skill_catalog_skills/2,
            skill_catalog_skill/3,
            skill_default_catalog/1,
            skill_default_catalog_reset/0,
            skill_compile/4,
            skill_prompt_fragment/2,
            skill_read_resource/3
          ]).

/** <module> Trusted skill catalog and Prolog-owned activation

Skills are inert instruction documents. The model never selects, loads or grants
authority through this module. Trusted host configuration supplies skill roots
and optional compiler rules; Prolog deterministically decides which skills enter
the model-visible context.

A skill directory contains a `SKILL.md` file with YAML-style frontmatter. Only
the small discovery subset required by the runtime is parsed:

  * `name`
  * `description`
  * `disable-model-invocation`

Unknown frontmatter is ignored and no value is ever interpreted as executable
Prolog. Skill bodies are loaded only after selection. Relative resource reads
are confined to the skill directory after canonical path resolution.
*/

:- use_module(library(apply)).
:- use_module(library(filesex)).
:- use_module(library(lists)).
:- use_module(library(readutil)).

:- dynamic default_catalog_cache/1.

rlm_skill_ready :-
    skill_catalog_empty(Catalog),
    skill_compile(Catalog, "", [skill_mode(off)], ok(_)).

skill_catalog_empty(
    skill_catalog{roots:[],
                  skills:[],
                  fingerprint:skill_catalog_0}).

skill_catalog_load(RootSpecs0, Options, Outcome) :-
    catch(skill_catalog_load_(RootSpecs0, Options, Outcome),
          Exception,
          skill_exception(load, Exception, Outcome)).

skill_catalog_load_(RootSpecs0, Options, ok(Catalog)) :-
    require_list(Options, options),
    normalize_root_specs(RootSpecs0, RootSpecs),
    option_value(include_deprecated, Options, false, IncludeDeprecated),
    require_boolean(IncludeDeprecated, include_deprecated),
    maplist(scan_skill_root(IncludeDeprecated), RootSpecs, RootResults),
    roots_and_skills(RootResults, Roots, Skills0),
    sort_skills(Skills0, Skills),
    require_unique_skill_names(Skills),
    catalog_fingerprint(Roots, Skills, Fingerprint),
    Catalog = skill_catalog{roots:Roots,
                            skills:Skills,
                            fingerprint:Fingerprint}.

skill_catalog_merge(CatalogA, CatalogB, Outcome) :-
    catch(skill_catalog_merge_(CatalogA, CatalogB, Outcome),
          Exception,
          skill_exception(merge, Exception, Outcome)).

skill_catalog_merge_(CatalogA, CatalogB, ok(Catalog)) :-
    require_catalog(CatalogA),
    require_catalog(CatalogB),
    append(CatalogA.roots, CatalogB.roots, Roots0),
    sort(Roots0, Roots),
    append(CatalogA.skills, CatalogB.skills, Skills0),
    sort_skills(Skills0, Skills),
    require_unique_skill_names(Skills),
    catalog_fingerprint(Roots, Skills, Fingerprint),
    Catalog = skill_catalog{roots:Roots,
                            skills:Skills,
                            fingerprint:Fingerprint}.

skill_catalog_skills(Catalog, Skills) :-
    require_catalog(Catalog),
    Skills = Catalog.skills.

skill_catalog_skill(Catalog, Name0, Skill) :-
    require_catalog(Catalog),
    skill_name_atom(Name0, Name),
    member(Skill, Catalog.skills),
    Skill.name == Name,
    !.

skill_default_catalog(Outcome) :-
    catch(skill_default_catalog_(Outcome),
          Exception,
          skill_exception(default_catalog, Exception, Outcome)).

skill_default_catalog_(ok(Catalog)) :-
    with_mutex(rlm_skill_default_catalog,
               default_catalog_locked(Catalog)).

default_catalog_locked(Catalog) :-
    default_catalog_cache(Catalog),
    !.
default_catalog_locked(Catalog) :-
    default_skill_root(Root),
    (   exists_directory(Root)
    ->  skill_catalog_load_([skill_root(mattpocock, Root)],
                            [],
                            ok(Catalog))
    ;   skill_catalog_empty(Catalog)
    ),
    assertz(default_catalog_cache(Catalog)).

skill_default_catalog_reset :-
    with_mutex(rlm_skill_default_catalog,
               retractall(default_catalog_cache(_))).

default_skill_root(Root) :-
    source_file(rlm_skill:default_skill_root(_), Source),
    file_directory_name(Source, PrologDir),
    file_directory_name(PrologDir, RepoRoot),
    directory_file_path(RepoRoot,
                        'third_party/mattpocock-skills/skills',
                        Root).

skill_compile(Catalog, Input0, Options, Outcome) :-
    catch(skill_compile_(Catalog, Input0, Options, Outcome),
          Exception,
          skill_exception(compile, Exception, Outcome)).

skill_compile_(Catalog, Input0, Options, ok(Compiled)) :-
    require_catalog(Catalog),
    require_list(Options, options),
    text_string(Input0, Input),
    option_value(skill_mode, Options, auto, Mode),
    require_member(Mode, [auto, off], skill_mode),
    (   Mode == off
    ->  empty_compilation(Catalog, Input, Compiled)
    ;   compile_active_skills(Catalog, Input, Options, Compiled)
    ).

empty_compilation(Catalog, Input,
                  compiled_skills{input:Input,
                                  selected:[],
                                  rejected:[],
                                  estimated_prompt_tokens:0,
                                  fingerprint:Fingerprint}) :-
    compile_fingerprint(Catalog.fingerprint,
                        Input,
                        off,
                        [],
                        [],
                        Fingerprint).

compile_active_skills(Catalog, Input, Options, Compiled) :-
    compile_options(Options, Config),
    normalize_requested_names(Config.explicit_skills, Explicit),
    normalize_requested_names(Config.disabled_skills, Disabled),
    validate_known_names(Explicit, Catalog, explicit_skill),
    validate_known_names(Disabled, Catalog, disabled_skill),
    input_features(Input, Features),
    maplist(skill_decision(Features,
                           Explicit,
                           Disabled,
                           Config.rules,
                           Config.min_score),
            Catalog.skills,
            Decisions),
    partition_candidate_decisions(Decisions, Candidates, Rejected0),
    sort_candidates(Candidates, SortedCandidates),
    admit_candidates(SortedCandidates,
                     Catalog,
                     Explicit,
                     Disabled,
                     Config,
                     [],
                     [],
                     SelectedNames,
                     Rejected0,
                     Rejected1,
                     ReasonsByName),
    selected_skill_records(SelectedNames,
                           Catalog,
                           ReasonsByName,
                           Selected,
                           EstimatedTokens),
    sort_rejections(Rejected1, Rejected),
    compile_fingerprint(Catalog.fingerprint,
                        Input,
                        Config,
                        SelectedNames,
                        Rejected,
                        Fingerprint),
    Compiled = compiled_skills{
                   input:Input,
                   selected:Selected,
                   rejected:Rejected,
                   estimated_prompt_tokens:EstimatedTokens,
                   fingerprint:Fingerprint
               }.

compile_options(Options,
                skill_compile_options{
                    explicit_skills:Explicit,
                    disabled_skills:Disabled,
                    rules:Rules,
                    min_score:MinScore,
                    max_skills:MaxSkills,
                    max_skill_tokens:MaxTokens}) :-
    option_value(explicit_skills, Options, [], Explicit),
    option_value(disabled_skills, Options, [], Disabled),
    option_value(skill_rules, Options, [], Rules),
    option_value(skill_min_score, Options, 20, MinScore),
    option_value(skill_max_count, Options, 4, MaxSkills),
    option_value(skill_max_tokens, Options, 4096, MaxTokens),
    require_list(Explicit, explicit_skills),
    require_list(Disabled, disabled_skills),
    require_list(Rules, skill_rules),
    require_nonnegative_integer(MinScore, skill_min_score),
    require_positive_integer(MaxSkills, skill_max_count),
    require_nonnegative_integer(MaxTokens, skill_max_tokens),
    maplist(validate_skill_rule, Rules).

validate_skill_rule(alias(Name, Phrase)) :-
    !,
    skill_name_atom(Name, _),
    nonempty_text(Phrase).
validate_skill_rule(trigger(Name, Phrase, Weight)) :-
    !,
    skill_name_atom(Name, _),
    nonempty_text(Phrase),
    integer(Weight),
    Weight >= 0.
validate_skill_rule(requires(Name, Dependency)) :-
    !,
    skill_name_atom(Name, _),
    skill_name_atom(Dependency, _).
validate_skill_rule(priority(Name, Priority)) :-
    !,
    skill_name_atom(Name, _),
    integer(Priority).
validate_skill_rule(conflicts(Name, Other)) :-
    !,
    skill_name_atom(Name, _),
    skill_name_atom(Other, _).
validate_skill_rule(Rule) :-
    throw(skill_fault(invalid_skill_rule(Rule))).

normalize_root_specs(RootSpecs0, RootSpecs) :-
    (   is_list(RootSpecs0)
    ->  Raw = RootSpecs0
    ;   Raw = [RootSpecs0]
    ),
    maplist(normalize_root_spec, Raw, RootSpecs).

normalize_root_spec(skill_root(Source0, Path0),
                    skill_root{source:Source, path:Path}) :-
    !,
    require_ground(Source0, skill_source),
    normalize_source(Source0, Source),
    canonical_directory(Path0, Path).
normalize_root_spec(Path0,
                    skill_root{source:external, path:Path}) :-
    canonical_directory(Path0, Path).

normalize_source(Source, Source) :-
    atom(Source),
    !.
normalize_source(Source0, Source) :-
    string(Source0),
    !,
    atom_string(Source, Source0).
normalize_source(Source, _) :-
    throw(skill_fault(invalid_skill_source(Source))).

canonical_directory(Path0, Path) :-
    path_atom(Path0, Raw),
    absolute_file_name(Raw,
                       Path,
                       [ file_type(directory),
                         access(read),
                         file_errors(fail),
                         solutions(first)
                       ]),
    !.
canonical_directory(Path, _) :-
    throw(skill_fault(skill_root_unavailable(Path))).

scan_skill_root(IncludeDeprecated,
                RootSpec,
                root_scan{root:RootInfo, skills:Skills}) :-
    Root = RootSpec.path,
    find_skill_files(Root,
                     Root,
                     IncludeDeprecated,
                     Files0),
    sort(Files0, Files),
    maplist(load_skill_metadata(RootSpec), Files, Skills),
    RootInfo = skill_root{source:RootSpec.source, path:Root}.

find_skill_files(Root, Dir, IncludeDeprecated, Files) :-
    directory_files(Dir, Entries0),
    exclude(dot_entry, Entries0, Entries),
    findall(EntryFiles,
            ( member(Entry, Entries),
              allowed_entry(Entry, IncludeDeprecated),
              directory_file_path(Dir, Entry, Candidate0),
              canonical_under_root(Root, Candidate0, Candidate),
              entry_skill_files(Root,
                                Candidate,
                                IncludeDeprecated,
                                EntryFiles)
            ),
            Nested),
    append(Nested, Files).

entry_skill_files(_, Candidate, _, [Candidate]) :-
    exists_file(Candidate),
    file_base_name(Candidate, 'SKILL.md'),
    !.
entry_skill_files(Root, Candidate, IncludeDeprecated, Files) :-
    exists_directory(Candidate),
    !,
    find_skill_files(Root,
                     Candidate,
                     IncludeDeprecated,
                     Files).
entry_skill_files(_, _, _, []).

allowed_entry(deprecated, false) :- !, fail.
allowed_entry(_, _).

dot_entry('.').
dot_entry('..').
dot_entry('.git').

canonical_under_root(Root, Candidate0, Candidate) :-
    absolute_file_name(Candidate0,
                       Candidate,
                       [ access(read),
                         file_errors(fail),
                         solutions(first)
                       ]),
    (   path_within(Root, Candidate)
    ->  true
    ;   throw(skill_fault(path_escape(Candidate0)))
    ).

path_within(Root, Path) :-
    Path == Root,
    !.
path_within(Root, Path) :-
    atom_concat(Root, '/', Prefix),
    sub_atom(Path, 0, _, _, Prefix).

load_skill_metadata(RootSpec, SkillFile, Skill) :-
    read_skill_frontmatter(SkillFile, Frontmatter),
    require_frontmatter_text(Frontmatter, name, NameText),
    skill_name_atom(NameText, Name),
    require_frontmatter_text(Frontmatter, description, Description),
    frontmatter_boolean(Frontmatter,
                        'disable-model-invocation',
                        false,
                        DisableModelInvocation),
    invocation_policy(DisableModelInvocation, Invocation),
    file_directory_name(SkillFile, SkillDir),
    relative_path(RootSpec.path, SkillDir, RelativeDir),
    skill_category(RelativeDir, Category),
    skill_resource_metadata(RootSpec.path,
                            SkillDir,
                            Resources),
    size_file(SkillFile, SkillBytes),
    bytes_tokens(SkillBytes, SkillTokens),
    resource_token_sum(Resources, ResourceTokens),
    Estimate is SkillTokens+ResourceTokens,
    Skill = skill{
                name:Name,
                description:Description,
                invocation:Invocation,
                source:RootSpec.source,
                root:RootSpec.path,
                directory:SkillDir,
                relative_directory:RelativeDir,
                category:Category,
                instruction_file:SkillFile,
                resources:Resources,
                estimated_tokens:Estimate
            }.

invocation_policy(true, explicit_user).
invocation_policy(false, automatic).

skill_resource_metadata(Root, SkillDir, Resources) :-
    directory_files(SkillDir, Entries0),
    exclude(dot_entry, Entries0, Entries),
    findall(Resource,
            ( member(Entry, Entries),
              Entry \== 'SKILL.md',
              directory_file_path(SkillDir, Entry, Candidate0),
              canonical_under_root(Root, Candidate0, Candidate),
              exists_file(Candidate),
              text_resource_extension(Candidate),
              size_file(Candidate, Bytes),
              bytes_tokens(Bytes, Tokens),
              Resource = skill_resource{
                             name:Entry,
                             path:Candidate,
                             estimated_tokens:Tokens
                         }
            ),
            Resources0),
    sort(Resources0, Resources).

text_resource_extension(Path) :-
    file_name_extension(_, Ext0, Path),
    downcase_atom(Ext0, Ext),
    memberchk(Ext, [md, txt]).

resource_token_sum(Resources, Tokens) :-
    findall(TokenCount,
            ( member(Resource, Resources),
              TokenCount = Resource.estimated_tokens
            ),
            Counts),
    sum_list(Counts, Tokens).

bytes_tokens(Bytes, Tokens) :-
    Tokens is max(1, (Bytes+3)//4).

relative_path(Root, Path, Relative) :-
    (   Path == Root
    ->  Relative = '.'
    ;   atom_concat(Root, '/', Prefix),
        atom_concat(Prefix, Relative, Path)
    ).

skill_category('.', root) :- !.
skill_category(RelativeDir, Category) :-
    atomic_list_concat(Parts, '/', RelativeDir),
    Parts = [Category|_],
    !.

read_skill_frontmatter(Path, Frontmatter) :-
    setup_call_cleanup(
        open(Path, read, Stream, [encoding(utf8)]),
        read_frontmatter_stream(Stream, Path, Frontmatter),
        close(Stream)).

read_frontmatter_stream(Stream, Path, Frontmatter) :-
    read_line_to_string(Stream, First0),
    trim_string(First0, First),
    (   First == "---"
    ->  read_frontmatter_lines(Stream, Path, [], Lines)
    ;   throw(skill_fault(missing_frontmatter(Path)))
    ),
    maplist(frontmatter_line_pair, Lines, Pairs0),
    exclude(=(none), Pairs0, Pairs),
    Frontmatter = Pairs.

read_frontmatter_lines(Stream, Path, Acc, Lines) :-
    read_line_to_string(Stream, Line0),
    (   Line0 == end_of_file
    ->  throw(skill_fault(unterminated_frontmatter(Path)))
    ;   trim_string(Line0, Line),
        (   Line == "---"
        ->  reverse(Acc, Lines)
        ;   read_frontmatter_lines(Stream,
                                   Path,
                                   [Line0|Acc],
                                   Lines)
        )
    ).

frontmatter_line_pair(Line0, Pair) :-
    trim_string(Line0, Line),
    (   Line == ""
    ->  Pair = none
    ;   sub_string(Line, Before, 1, After, ":")
    ->  sub_string(Line, 0, Before, _, Key0),
        Start is Before+1,
        sub_string(Line, Start, After, 0, Value0),
        trim_string(Key0, KeyString),
        trim_string(Value0, RawValue),
        atom_string(Key, KeyString),
        yaml_scalar(RawValue, Value),
        Pair = Key-Value
    ;   Pair = none
    ),
    !.

yaml_scalar(Raw, Value) :-
    string_length(Raw, Length),
    Length >= 2,
    sub_string(Raw, 0, 1, _, Quote),
    memberchk(Quote, ["\"", "'"]),
    Last is Length-1,
    sub_string(Raw, Last, 1, 0, Quote),
    !,
    InnerLength is Length-2,
    sub_string(Raw, 1, InnerLength, 1, Value).
yaml_scalar(Raw, Raw).

require_frontmatter_text(Frontmatter, Key, Value) :-
    (   memberchk(Key-Raw, Frontmatter),
        nonempty_text(Raw)
    ->  text_string(Raw, Value)
    ;   throw(skill_fault(missing_frontmatter_field(Key)))
    ).

frontmatter_boolean(Frontmatter, Key, Default, Value) :-
    (   memberchk(Key-Raw, Frontmatter)
    ->  parse_boolean(Raw, Key, Value)
    ;   Value = Default
    ).

parse_boolean(true, _, true) :- !.
parse_boolean(false, _, false) :- !.
parse_boolean(Raw0, _, Value) :-
    text_string(Raw0, Raw),
    string_lower(Raw, Lower),
    (   Lower == "true"
    ->  Value = true
    ;   Lower == "false"
    ->  Value = false
    ;   throw(skill_fault(invalid_boolean(Raw0)))
    ).

sort_skills(Skills0, Skills) :-
    findall(Name-Skill,
            ( member(Skill, Skills0),
              Name = Skill.name
            ),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Skills).

pairs_values([], []).
pairs_values([_-Value|Pairs], [Value|Values]) :-
    pairs_values(Pairs, Values).

require_unique_skill_names(Skills) :-
    findall(Name,
            ( select(SkillA, Skills, Rest),
              member(SkillB, Rest),
              SkillA.name == SkillB.name,
              Name = SkillA.name
            ),
            Duplicates0),
    sort(Duplicates0, Duplicates),
    (   Duplicates == []
    ->  true
    ;   throw(skill_fault(duplicate_skill_names(Duplicates)))
    ).

roots_and_skills([], [], []).
roots_and_skills([Scan|Scans], [Scan.root|Roots], Skills) :-
    roots_and_skills(Scans, Roots, Rest),
    append(Scan.skills, Rest, Skills).

catalog_fingerprint(Roots, Skills, Fingerprint) :-
    findall(Source,
            ( member(Root, Roots), Source = Root.source ),
            Sources0),
    sort(Sources0, Sources),
    findall(skill(Name,
                  Description,
                  Invocation,
                  Source,
                  Relative,
                  Estimate),
            ( member(Skill, Skills),
              Name = Skill.name,
              Description = Skill.description,
              Invocation = Skill.invocation,
              Source = Skill.source,
              Relative = Skill.relative_directory,
              Estimate = Skill.estimated_tokens
            ),
            StableSkills),
    term_hash(skill_catalog(Sources, StableSkills), Hash),
    format(atom(Fingerprint), 'skill_catalog_~16r', [Hash]).

input_features(Input,
               input_features{lower:Lower,
                              tokens:Tokens}) :-
    string_lower(Input, Lower),
    text_tokens(Lower, Tokens0),
    sort(Tokens0, Tokens).

skill_decision(Features,
               Explicit,
               Disabled,
               Rules,
               MinScore,
               Skill,
               Decision) :-
    Name = Skill.name,
    (   memberchk(Name, Disabled)
    ->  Decision = rejected(Name, disabled_by_host)
    ;   memberchk(Name, Explicit)
    ->  rule_priority(Name, Rules, Priority),
        Score is 10000+Priority,
        Decision = candidate(Name,
                             Score,
                             [explicit_user_selection])
    ;   Skill.invocation == explicit_user
    ->  Decision = rejected(Name, explicit_user_only)
    ;   rule_aliases(Name, Rules, Aliases),
        (   skill_negated(Features.lower, Skill, Aliases)
        ->  Decision = rejected(Name, negated_by_input)
        ;   automatic_score(Features,
                            Skill,
                            Aliases,
                            Rules,
                            Score0,
                            Reasons0),
            rule_priority(Name, Rules, Priority),
            Score is Score0+Priority,
            (   Score >= MinScore
            ->  Decision = candidate(Name, Score, Reasons0)
            ;   Decision = rejected(Name,
                                    below_threshold(Score, MinScore))
            )
        )
    ).

automatic_score(Features,
                Skill,
                Aliases,
                Rules,
                Score,
                Reasons) :-
    skill_name_phrase(Skill.name, NamePhrase),
    phrase_match_score(Features.lower,
                       NamePhrase,
                       120,
                       NameScore,
                       NameReasons),
    alias_score(Features.lower,
                Aliases,
                AliasScore,
                AliasReasons),
    trigger_score(Features.lower,
                  Skill.name,
                  Rules,
                  TriggerScore,
                  TriggerReasons),
    skill_terms(Skill, Terms),
    intersection_count(Features.tokens, Terms, Shared),
    LexicalScore is Shared*20,
    (   Shared > 0
    ->  LexicalReasons = [shared_terms(Shared)]
    ;   LexicalReasons = []
    ),
    Score is NameScore+AliasScore+TriggerScore+LexicalScore,
    append([NameReasons,
            AliasReasons,
            TriggerReasons,
            LexicalReasons],
           Reasons0),
    sort(Reasons0, Reasons).

phrase_match_score(Text, Phrase, Weight, Weight, [name_phrase(Phrase)]) :-
    nonempty_text(Phrase),
    string_lower(Phrase, Lower),
    sub_string(Text, _, _, _, Lower),
    !.
phrase_match_score(_, _, _, 0, []).

alias_score(_, [], 0, []).
alias_score(Text, [Alias|Aliases], Score, Reasons) :-
    alias_score(Text, Aliases, RestScore, RestReasons),
    string_lower(Alias, Lower),
    (   sub_string(Text, _, _, _, Lower)
    ->  Score is RestScore+80,
        Reasons = [alias_phrase(Alias)|RestReasons]
    ;   Score = RestScore,
        Reasons = RestReasons
    ).

trigger_score(Text, Name, Rules, Score, Reasons) :-
    findall(Weight-trigger(Phrase, Weight),
            ( member(trigger(RawName, Phrase0, Weight), Rules),
              skill_name_atom(RawName, RuleName),
              RuleName == Name,
              text_string(Phrase0, Phrase),
              string_lower(Phrase, Lower),
              sub_string(Text, _, _, _, Lower)
            ),
            Matches),
    findall(W, member(W-_, Matches), Weights),
    sum_list(Weights, Score),
    findall(Reason, member(_-Reason, Matches), Reasons).

rule_aliases(Name, Rules, Aliases) :-
    findall(Alias,
            ( member(alias(RawName, Alias0), Rules),
              skill_name_atom(RawName, RuleName),
              RuleName == Name,
              text_string(Alias0, Alias)
            ),
            Aliases).

rule_priority(Name, Rules, Priority) :-
    findall(P,
            ( member(priority(RawName, P), Rules),
              skill_name_atom(RawName, RuleName),
              RuleName == Name
            ),
            Priorities),
    sum_list(Priorities, Priority).

skill_name_phrase(Name, Phrase) :-
    atom_string(Name, Raw),
    split_string(Raw, "-_", "", Parts),
    atomics_to_string(Parts, " ", Phrase).

skill_terms(Skill, Terms) :-
    skill_name_phrase(Skill.name, NamePhrase),
    string_concat(NamePhrase, " ", Prefix),
    string_concat(Prefix, Skill.description, Text),
    text_tokens(Text, Terms0),
    sort(Terms0, Terms).

text_tokens(Text0, Tokens) :-
    text_string(Text0, Text),
    string_lower(Text, Lower),
    split_string(Lower,
                 " \t\r\n.,;:!?()[]{}<>\"'`/\\|+-_=*&#@~",
                 "",
                 Raw),
    findall(Stem,
            ( member(Token0, Raw),
              significant_token(Token0),
              stem_token(Token0, Stem),
              significant_token(Stem)
            ),
            Tokens).

significant_token(Token) :-
    string_length(Token, Length),
    Length >= 3,
    \+ stopword(Token).

stopword("the").
stopword("and").
stopword("for").
stopword("with").
stopword("that").
stopword("this").
stopword("from").
stopword("into").
stopword("when").
stopword("where").
stopword("which").
stopword("while").
stopword("user").
stopword("users").
stopword("use").
stopword("using").
stopword("skill").
stopword("skills").
stopword("want").
stopword("wants").
stopword("work").
stopword("working").
stopword("current").
stopword("agent").
stopword("agents").
stopword("code").
stopword("project").
stopword("file").
stopword("files").
stopword("make").
stopword("have").
stopword("has").
stopword("are").
stopword("was").
stopword("were").
stopword("you").
stopword("your").
stopword("they").
stopword("their").
stopword("about").
stopword("only").
stopword("than").
stopword("then").
stopword("also").

stem_token(Token0, Stem) :-
    (   string_length(Token0, Length),
        Length > 5,
        sub_string(Token0, _, 3, 0, "ing")
    ->  Keep is Length-3,
        sub_string(Token0, 0, Keep, _, Stem)
    ;   string_length(Token0, Length),
        Length > 4,
        sub_string(Token0, _, 2, 0, "ed")
    ->  Keep is Length-2,
        sub_string(Token0, 0, Keep, _, Stem)
    ;   string_length(Token0, Length),
        Length > 4,
        sub_string(Token0, _, 1, 0, "s")
    ->  Keep is Length-1,
        sub_string(Token0, 0, Keep, _, Stem)
    ;   Stem = Token0
    ).

intersection_count(A, B, Count) :-
    findall(Token,
            ( member(Token, A),
              memberchk(Token, B)
            ),
            Shared0),
    sort(Shared0, Shared),
    length(Shared, Count).

skill_negated(LowerInput, Skill, Aliases) :-
    skill_name_phrase(Skill.name, NamePhrase),
    member(Phrase, [NamePhrase|Aliases]),
    string_lower(Phrase, LowerPhrase),
    negation_prefix(Prefix),
    string_concat(Prefix, LowerPhrase, Needle),
    sub_string(LowerInput, _, _, _, Needle),
    !.

negation_prefix("do not use ").
negation_prefix("don't use ").
negation_prefix("do not activate ").
negation_prefix("without ").
negation_prefix("no ").

partition_candidate_decisions([], [], []).
partition_candidate_decisions([candidate(Name, Score, Reasons)|Rest],
                              [candidate(Name, Score, Reasons)|Candidates],
                              Rejected) :-
    !,
    partition_candidate_decisions(Rest, Candidates, Rejected).
partition_candidate_decisions([rejected(Name, Reason)|Rest],
                              Candidates,
                              [skill_rejection{name:Name,
                                               reason:Reason}|Rejected]) :-
    partition_candidate_decisions(Rest, Candidates, Rejected).

sort_candidates(Candidates0, Candidates) :-
    findall(Key-Candidate,
            ( member(Candidate, Candidates0),
              Candidate = candidate(Name, Score, _),
              NegScore is -Score,
              Key = NegScore-Name
            ),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Candidates).

admit_candidates([], _, _, _, _, Selected, Reasons,
                 Selected, Rejected, Rejected, Reasons) :-
    !.
admit_candidates([candidate(Name, Score, CandidateReasons)|Candidates],
                 Catalog,
                 Explicit,
                 Disabled,
                 Config,
                 Selected0,
                 Reasons0,
                 Selected,
                 Rejected0,
                 Rejected,
                 Reasons) :-
    (   memberchk(Name, Selected0)
    ->  admit_candidates(Candidates,
                         Catalog,
                         Explicit,
                         Disabled,
                         Config,
                         Selected0,
                         Reasons0,
                         Selected,
                         Rejected0,
                         Rejected,
                         Reasons)
    ;   dependency_closure(Name,
                           Catalog,
                           Explicit,
                           Disabled,
                           Config.rules,
                           Selected0,
                           Closure,
                           DependencyReasons),
        candidate_bundle(Closure, Selected0, Bundle),
        tentative_names(Selected0, Bundle, Tentative),
        selection_cost(Tentative, Catalog, Count, Tokens),
        candidate_conflict(Tentative, Config.rules, Conflict),
        (   Conflict \== none
        ->  Rejected1 = [skill_rejection{
                              name:Name,
                              reason:conflict(Conflict)
                          }|Rejected0],
            Selected1 = Selected0,
            Reasons1 = Reasons0
        ;   Count > Config.max_skills
        ->  Rejected1 = [skill_rejection{
                              name:Name,
                              reason:max_skill_count(
                                         Count,
                                         Config.max_skills)
                          }|Rejected0],
            Selected1 = Selected0,
            Reasons1 = Reasons0
        ;   Tokens > Config.max_skill_tokens
        ->  (   memberchk(Name, Explicit)
            ->  throw(skill_fault(
                         explicit_skill_budget_exceeded(
                             Name,
                             Tokens,
                             Config.max_skill_tokens)))
            ;   Rejected1 = [skill_rejection{
                                  name:Name,
                                  reason:skill_token_budget(
                                             Tokens,
                                             Config.max_skill_tokens)
                              }|Rejected0],
                Selected1 = Selected0,
                Reasons1 = Reasons0
            )
        ;   append(Selected0, Bundle, Selected1),
            add_reason(Name,
                       [score(Score)|CandidateReasons],
                       Reasons0,
                       ReasonsA),
            add_dependency_reasons(DependencyReasons,
                                   ReasonsA,
                                   Reasons1),
            Rejected1 = Rejected0
        ),
        admit_candidates(Candidates,
                         Catalog,
                         Explicit,
                         Disabled,
                         Config,
                         Selected1,
                         Reasons1,
                         Selected,
                         Rejected1,
                         Rejected,
                         Reasons)
    ).

dependency_closure(Name,
                   Catalog,
                   Explicit,
                   Disabled,
                   Rules,
                   AlreadySelected,
                   Closure,
                   Reasons) :-
    dependency_closure_([Name],
                        Catalog,
                        Explicit,
                        Disabled,
                        Rules,
                        AlreadySelected,
                        [],
                        Closure0,
                        [],
                        Reasons),
    sort(Closure0, Closure).

dependency_closure_([], _, _, _, _, _, Closure, Closure,
                    Reasons, Reasons).
dependency_closure_([Name|Queue],
                    Catalog,
                    Explicit,
                    Disabled,
                    Rules,
                    AlreadySelected,
                    Closure0,
                    Closure,
                    Reasons0,
                    Reasons) :-
    (   memberchk(Name, AlreadySelected)
    ;   memberchk(Name, Closure0)
    ),
    !,
    dependency_closure_(Queue,
                        Catalog,
                        Explicit,
                        Disabled,
                        Rules,
                        AlreadySelected,
                        Closure0,
                        Closure,
                        Reasons0,
                        Reasons).
dependency_closure_([Name|Queue],
                    Catalog,
                    Explicit,
                    Disabled,
                    Rules,
                    AlreadySelected,
                    Closure0,
                    Closure,
                    Reasons0,
                    Reasons) :-
    (   skill_catalog_skill(Catalog, Name, Skill)
    ->  true
    ;   throw(skill_fault(missing_skill_dependency(Name)))
    ),
    (   memberchk(Name, Disabled)
    ->  throw(skill_fault(disabled_required_skill(Name)))
    ;   Skill.invocation == explicit_user,
        \+ memberchk(Name, Explicit)
    ->  throw(skill_fault(explicit_required_skill(Name)))
    ;   true
    ),
    rule_dependencies(Name, Rules, Dependencies),
    validate_known_names(Dependencies, Catalog, dependency),
    findall(dep_reason(Dependency,
                       [required_by(Name)]),
            member(Dependency, Dependencies),
            DependencyReasons),
    append(Queue, Dependencies, Queue1),
    append(Reasons0, DependencyReasons, Reasons1),
    dependency_closure_(Queue1,
                        Catalog,
                        Explicit,
                        Disabled,
                        Rules,
                        AlreadySelected,
                        [Name|Closure0],
                        Closure,
                        Reasons1,
                        Reasons).

rule_dependencies(Name, Rules, Dependencies) :-
    findall(Dependency,
            ( member(requires(RawName, RawDependency), Rules),
              skill_name_atom(RawName, RuleName),
              RuleName == Name,
              skill_name_atom(RawDependency, Dependency)
            ),
            Dependencies0),
    sort(Dependencies0, Dependencies).

candidate_bundle(Closure, Selected, Bundle) :-
    findall(Name,
            ( member(Name, Closure),
              \+ memberchk(Name, Selected)
            ),
            Bundle0),
    sort(Bundle0, Bundle).

tentative_names(Selected, Bundle, Tentative) :-
    append(Selected, Bundle, Names0),
    sort(Names0, Tentative).

selection_cost(Names, Catalog, Count, Tokens) :-
    length(Names, Count),
    findall(Estimate,
            ( member(Name, Names),
              skill_catalog_skill(Catalog, Name, Skill),
              Estimate = Skill.estimated_tokens
            ),
            Estimates),
    sum_list(Estimates, Tokens).

candidate_conflict(Names, Rules, Conflict) :-
    (   member(conflicts(RawA, RawB), Rules),
        skill_name_atom(RawA, A),
        skill_name_atom(RawB, B),
        memberchk(A, Names),
        memberchk(B, Names)
    ->  Conflict = A-B
    ;   Conflict = none
    ).

add_reason(Name, Reason, Reasons0, Reasons) :-
    select(Name-Existing, Reasons0, Rest),
    !,
    append(Existing, Reason, Combined0),
    sort(Combined0, Combined),
    Reasons = [Name-Combined|Rest].
add_reason(Name, Reason, Reasons, [Name-Reason|Reasons]).

add_dependency_reasons([], Reasons, Reasons).
add_dependency_reasons([dep_reason(Name, Reason)|Rest],
                       Reasons0,
                       Reasons) :-
    add_reason(Name, Reason, Reasons0, Reasons1),
    add_dependency_reasons(Rest, Reasons1, Reasons).

selected_skill_records(Names,
                       Catalog,
                       ReasonsByName,
                       Selected,
                       EstimatedTokens) :-
    maplist(selected_skill_record(Catalog, ReasonsByName),
            Names,
            Selected),
    findall(Tokens,
            ( member(Record, Selected),
              Tokens = Record.estimated_tokens
            ),
            TokenCounts),
    sum_list(TokenCounts, EstimatedTokens).

selected_skill_record(Catalog,
                      ReasonsByName,
                      Name,
                      Selection) :-
    skill_catalog_skill(Catalog, Name, Skill),
    (   memberchk(Name-Reasons0, ReasonsByName)
    ->  sort(Reasons0, Reasons)
    ;   Reasons = [dependency_closure]
    ),
    read_skill_bundle(Skill, Instructions, ResourceBodies),
    Selection = skill_selection{
                    name:Name,
                    description:Skill.description,
                    source:Skill.source,
                    category:Skill.category,
                    invocation:Skill.invocation,
                    estimated_tokens:Skill.estimated_tokens,
                    reasons:Reasons,
                    instructions:Instructions,
                    resources:ResourceBodies
                }.

read_skill_bundle(Skill, Instructions, ResourceBodies) :-
    read_file_to_string(Skill.instruction_file,
                        Raw,
                        [encoding(utf8)]),
    strip_frontmatter(Raw, Instructions),
    maplist(read_skill_resource_body,
            Skill.resources,
            ResourceBodies).

read_skill_resource_body(Resource,
                         skill_resource_body{
                             name:Resource.name,
                             content:Content,
                             estimated_tokens:Resource.estimated_tokens}) :-
    read_file_to_string(Resource.path,
                        Content,
                        [encoding(utf8)]).

strip_frontmatter(Raw, Body) :-
    split_string(Raw, "\n", "", Lines),
    strip_frontmatter_lines(Lines, BodyLines0),
    drop_leading_blank_lines(BodyLines0, BodyLines),
    atomics_to_string(BodyLines, "\n", Body).

drop_leading_blank_lines([""|Lines], BodyLines) :-
    !,
    drop_leading_blank_lines(Lines, BodyLines).
drop_leading_blank_lines(Lines, Lines).

strip_frontmatter_lines(["---"|Lines], BodyLines) :-
    !,
    drop_until_frontmatter_end(Lines, BodyLines).
strip_frontmatter_lines(Lines, Lines).

drop_until_frontmatter_end([], []).
drop_until_frontmatter_end(["---"|Lines], Lines) :- !.
drop_until_frontmatter_end([_|Lines], BodyLines) :-
    drop_until_frontmatter_end(Lines, BodyLines).

sort_rejections(Rejected0, Rejected) :-
    findall(Name-Item,
            ( member(Item, Rejected0),
              Name = Item.name
            ),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Rejected).

compile_fingerprint(CatalogFingerprint,
                    Input,
                    Config,
                    Selected,
                    Rejected,
                    Fingerprint) :-
    term_hash(skill_compile(CatalogFingerprint,
                            Input,
                            Config,
                            Selected,
                            Rejected),
              Hash),
    format(atom(Fingerprint), 'skill_compile_~16r', [Hash]).

skill_prompt_fragment(Compiled, Prompt) :-
    require_compiled(Compiled),
    (   Compiled.selected == []
    ->  Prompt = ""
    ;   maplist(render_skill_selection,
                Compiled.selected,
                Blocks),
        atomics_to_string(
            ["The following instructions were selected automatically by the Prolog prompt compiler. The model must follow them but must not select, request, load, or grant skills. Any legacy references inside a skill to a `Skill` tool are inert text; Prolog owns activation.",
             "Active skills:"|Blocks],
            "\n\n",
            Prompt)
    ).

render_skill_selection(Selection, Block) :-
    format(string(Header),
           "## Skill: ~w\nSource: ~w / ~w\nActivation reasons: ~q\n\n~s",
           [ Selection.name,
             Selection.source,
             Selection.category,
             Selection.reasons,
             Selection.instructions
           ]),
    render_resource_blocks(Selection.resources, ResourceText),
    string_concat(Header, ResourceText, Block).

render_resource_blocks([], "").
render_resource_blocks(Resources, Text) :-
    maplist(render_resource_block, Resources, Blocks),
    atomics_to_string(Blocks, "\n\n", Joined),
    string_concat("\n\n### Skill resources\n\n", Joined, Text).

render_resource_block(Resource, Block) :-
    format(string(Block),
           "#### ~s\n\n~s",
           [Resource.name, Resource.content]).

skill_read_resource(Skill, Relative0, Outcome) :-
    catch(skill_read_resource_(Skill, Relative0, Outcome),
          Exception,
          skill_exception(resource, Exception, Outcome)).

skill_read_resource_(Skill, Relative0, ok(Content)) :-
    require_skill(Skill),
    path_atom(Relative0, Relative),
    (   is_absolute_file_name(Relative)
    ->  throw(skill_fault(absolute_resource_path(Relative)))
    ;   true
    ),
    directory_file_path(Skill.directory, Relative, Candidate0),
    (   absolute_file_name(Candidate0,
                           Candidate,
                           [ file_type(file),
                             access(read),
                             file_errors(fail),
                             solutions(first)
                           ])
    ->  true
    ;   throw(skill_fault(resource_not_found(Relative)))
    ),
    (   path_within(Skill.directory, Candidate)
    ->  read_file_to_string(Candidate,
                            Content,
                            [encoding(utf8)])
    ;   throw(skill_fault(resource_path_escape(Relative)))
    ).

normalize_requested_names(Raw, Names) :-
    maplist(skill_name_atom, Raw, Names0),
    sort(Names0, Names).

validate_known_names([], _, _).
validate_known_names([Name|Names], Catalog, Kind) :-
    (   skill_catalog_skill(Catalog, Name, _)
    ->  true
    ;   throw(skill_fault(unknown_skill(Kind, Name)))
    ),
    validate_known_names(Names, Catalog, Kind).

skill_name_atom(Name, Name) :-
    atom(Name),
    valid_skill_name(Name),
    !.
skill_name_atom(Name0, Name) :-
    string(Name0),
    atom_string(Name, Name0),
    valid_skill_name(Name),
    !.
skill_name_atom(Name, _) :-
    throw(skill_fault(invalid_skill_name(Name))).

valid_skill_name(Name) :-
    atom_chars(Name, [First|Rest]),
    skill_name_first_char(First),
    maplist(skill_name_char, Rest).

skill_name_first_char(Char) :-
    char_type(Char, alnum).

skill_name_char(Char) :-
    char_type(Char, alnum),
    !.
skill_name_char('-').
skill_name_char('_').

require_catalog(Catalog) :-
    (   is_dict(Catalog, skill_catalog),
        get_dict(skills, Catalog, Skills),
        is_list(Skills),
        get_dict(roots, Catalog, Roots),
        is_list(Roots),
        get_dict(fingerprint, Catalog, _)
    ->  true
    ;   throw(skill_fault(invalid_skill_catalog(Catalog)))
    ).

require_compiled(Compiled) :-
    (   is_dict(Compiled, compiled_skills),
        get_dict(selected, Compiled, Selected),
        is_list(Selected)
    ->  true
    ;   throw(skill_fault(invalid_compiled_skills(Compiled)))
    ).

require_skill(Skill) :-
    (   is_dict(Skill, skill),
        get_dict(directory, Skill, Directory),
        atom(Directory)
    ->  true
    ;   throw(skill_fault(invalid_skill(Skill)))
    ).

require_boolean(true, _).
require_boolean(false, _).
require_boolean(Value, Name) :-
    throw(skill_fault(invalid_option(Name, Value))).

require_member(Value, Allowed, Name) :-
    (   memberchk(Value, Allowed)
    ->  true
    ;   throw(skill_fault(invalid_option(Name, Value)))
    ).

require_list(Value, _) :-
    is_list(Value),
    !.
require_list(Value, Name) :-
    throw(skill_fault(invalid_option(Name, Value))).

require_ground(Value, _) :-
    ground(Value),
    !.
require_ground(Value, Name) :-
    throw(skill_fault(non_ground(Name, Value))).

require_nonnegative_integer(Value, _) :-
    integer(Value),
    Value >= 0,
    !.
require_nonnegative_integer(Value, Name) :-
    throw(skill_fault(invalid_option(Name, Value))).

require_positive_integer(Value, _) :-
    integer(Value),
    Value > 0,
    !.
require_positive_integer(Value, Name) :-
    throw(skill_fault(invalid_option(Name, Value))).

nonempty_text(Value) :-
    text_string(Value, Text),
    Text \== "".

text_string(Value, Value) :-
    string(Value),
    !.
text_string(Value, Text) :-
    atom(Value),
    !,
    atom_string(Value, Text).
text_string(Value, _) :-
    throw(skill_fault(expected_text(Value))).

trim_string(end_of_file, "") :- !.
trim_string(Text0, Text) :-
    text_string(Text0, Raw),
    normalize_space(string(Text), Raw).

path_atom(Path, Path) :-
    atom(Path),
    !.
path_atom(Path0, Path) :-
    string(Path0),
    !,
    atom_string(Path, Path0).
path_atom(Path, _) :-
    throw(skill_fault(invalid_path(Path))).

option_value(Name, Options, Default, Value) :-
    (   member(Option, Options),
        nonvar(Option),
        Option =.. [Name, Found]
    ->  Value = Found
    ;   Value = Default
    ).

skill_exception(Phase, skill_fault(Detail),
                error(skill_error{kind:skill_fault,
                                  phase:Phase,
                                  detail:Detail,
                                  message:"skill operation rejected"})) :-
    !.
skill_exception(Phase, Exception,
                error(skill_error{kind:exception,
                                  phase:Phase,
                                  exception:Safe,
                                  message:"skill operation failed"})) :-
    safe_exception(Exception, Safe).

safe_exception(Exception, Safe) :-
    catch(term_string(Exception,
                      Safe,
                      [ quoted(true),
                        numbervars(true),
                        max_depth(8)
                      ]),
          _,
          Safe = "<unprintable exception>").
