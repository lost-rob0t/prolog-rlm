:- module(rlm_skill,
          [ rlm_skill_ready/0,
            skill_catalog_empty/1,
            skill_catalog_load/3,
            skill_catalog_merge/3,
            skill_catalog_skills/2,
            skill_catalog_skill/3,
            skill_default_catalog/1,
            skill_default_catalog_reset/0,
            skill_prompt_unit/3,
            skill_catalog_prompt_units/3,
            skill_read_resource/3
          ]).

/** <module> Confined, inert Agent Skills package loader

This module discovers bounded SKILL.md packages and converts them to the
canonical prompt_unit input consumed by rlm_prompt_compiler. It does not
select, score, pack, execute, or grant authority. Bodies are read only during
explicit prompt-unit conversion; indexed resources are read only through
skill_read_resource/3.
*/

:- use_module(library(crypto)).
:- use_module(library(filesex)).
:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(library(readutil)).

:- dynamic default_catalog_cache/1.

frontmatter_max_bytes(65536).
skill_body_max_bytes(32768).
skill_file_max_bytes(102400).
resource_file_max_bytes(524288).
skill_roots_max(16).
skills_per_root_max(256).
skills_per_catalog_max(512).
skill_descendant_depth_max(16).
directory_entries_max(4096).
skill_resources_max(128).
skill_resource_aggregate_max_bytes(4194304).

rlm_skill_ready :- skill_catalog_empty(_).

skill_catalog_empty(skill_catalog{roots:[], skills:[],
                                  fingerprint:skill_catalog_0}).

skill_catalog_load(Roots0, Options, Outcome) :-
    catch(skill_catalog_load_(Roots0, Options, Outcome), E,
          skill_exception(load, E, Outcome)), !.

skill_catalog_load_(Roots0, Options, ok(Catalog)) :-
    require_list(Options, options),
    normalize_roots(Roots0, Roots),
    option_value(include_deprecated, Options, false, IncludeDeprecated),
    require_boolean(IncludeDeprecated, include_deprecated),
    maplist(scan_root(IncludeDeprecated), Roots, Scans),
    findall(Root, (member(Scan, Scans), Root=Scan.root), RootInfos),
    findall(Skill,
            (member(Scan, Scans), Skills=Scan.skills, member(Skill, Skills)),
            Skills0),
    sort_skills(Skills0, Skills),
    require_skill_count(catalog, Skills),
    require_unique_names(Skills),
    catalog_fingerprint(RootInfos, Skills, Fingerprint),
    Catalog = skill_catalog{roots:RootInfos, skills:Skills,
                            fingerprint:Fingerprint}.

skill_catalog_merge(A, B, Outcome) :-
    catch(skill_catalog_merge_(A, B, Outcome), E,
          skill_exception(merge, E, Outcome)), !.

skill_catalog_merge_(A, B, ok(Catalog)) :-
    require_catalog(A), require_catalog(B),
    append(A.roots, B.roots, Roots0), sort(Roots0, Roots),
    append(A.skills, B.skills, Skills0), sort_skills(Skills0, Skills),
    require_skill_count(catalog, Skills),
    require_unique_names(Skills),
    catalog_fingerprint(Roots, Skills, Fingerprint),
    Catalog = skill_catalog{roots:Roots, skills:Skills,
                            fingerprint:Fingerprint}.

skill_catalog_skills(Catalog, Skills) :-
    require_catalog(Catalog), Skills = Catalog.skills.

skill_catalog_skill(Catalog, Name0, Skill) :-
    require_catalog(Catalog), skill_name_atom(Name0, Name),
    member(Skill, Catalog.skills), Skill.name == Name, !.

skill_default_catalog(Outcome) :-
    catch(with_mutex(rlm_skill_default_catalog,
                     default_catalog_locked(Outcome)),
          E, skill_exception(default_catalog, E, Outcome)).

default_catalog_locked(ok(Catalog)) :- default_catalog_cache(Catalog), !.
default_catalog_locked(ok(Catalog)) :-
    default_skill_root(Root),
    ( exists_directory(Root)
    -> skill_catalog_load_([skill_root(prolog_rlm_core, Root)], [], ok(Catalog))
    ; skill_catalog_empty(Catalog)
    ),
    assertz(default_catalog_cache(Catalog)).

skill_default_catalog_reset :-
    with_mutex(rlm_skill_default_catalog,
               retractall(default_catalog_cache(_))).

default_skill_root(Root) :-
    source_file(rlm_skill:default_skill_root(_), Source),
    file_directory_name(Source, PrologDir),
    file_directory_name(PrologDir, RepoRoot),
    directory_file_path(RepoRoot, 'skills/core', Root).

normalize_roots(Roots0, Roots) :-
    (is_list(Roots0) -> Raw=Roots0 ; Raw=[Roots0]),
    require_root_count(Raw),
    maplist(normalize_root, Raw, Roots).

require_root_count(Roots) :-
    length(Roots, Count), skill_roots_max(Max),
    ( Count =< Max -> true
    ; throw(skill_fault(too_many_skill_roots(Count, Max))) ).

normalize_root(skill_root(Source0, Path0),
               skill_root{source:Source, path:Path}) :- !,
    require_ground(Source0, skill_source), normalize_source(Source0, Source),
    canonical_directory(Path0, Path).
normalize_root(Path0, skill_root{source:external, path:Path}) :-
    canonical_directory(Path0, Path).

normalize_source(Source, Source) :- atom(Source), !.
normalize_source(Source0, Source) :- string(Source0), !,
    atom_string(Source, Source0).
normalize_source(Source, _) :- throw(skill_fault(invalid_skill_source(Source))).

canonical_directory(Path0, Path) :-
    path_atom(Path0, Raw),
    absolute_file_name(Raw, Path,
                       [file_type(directory), access(read), file_errors(fail),
                        solutions(first)]), !.
canonical_directory(Path, _) :- throw(skill_fault(skill_root_unavailable(Path))).

scan_root(IncludeDeprecated, RootSpec,
          root_scan{root:RootInfo, skills:Skills}) :-
    skills_per_root_max(Max),
    directory_entries_max(EntryMax),
    scan_directory(RootSpec.path, RootSpec.path, IncludeDeprecated, 0,
                    Max, _, EntryMax, _, [], FilesRev),
    reverse(FilesRev, Files0),
    sort(Files0, Files), maplist(load_skill(RootSpec), Files, Skills),
    RootInfo = skill_root{source:RootSpec.source, path:RootSpec.path}.

scan_directory(Root, Dir, _, Depth, Remaining0, Remaining,
               EntryRemaining, EntryRemaining, Files0, Files) :-
    directory_file_path(Dir, 'SKILL.md', RawSkill),
    exists_file(RawSkill), !,
    require_scan_depth(Dir, Depth),
    secure_descendant(Root, RawSkill, SkillFile),
    admit_skill_file(Root, SkillFile, Remaining0, Remaining, Files0, Files).
scan_directory(Root, Dir, IncludeDeprecated, Depth,
                Remaining0, Remaining, EntryRemaining0, EntryRemaining,
                Files0, Files) :-
    require_scan_depth(Dir, Depth),
    directory_entries(Dir, Entries),
    scan_directory_entries(Entries, Root, Dir, IncludeDeprecated, Depth,
                            Remaining0, Remaining,
                            EntryRemaining0, EntryRemaining, Files0, Files).

scan_directory_entries([], _, _, _, _, Remaining, Remaining,
                       EntryRemaining, EntryRemaining, Files, Files).
scan_directory_entries([Entry|Entries], Root, Dir, IncludeDeprecated, Depth,
                        Remaining0, Remaining,
                        EntryRemaining0, EntryRemaining, Files0, Files) :-
    visit_directory_entry(root, Root, EntryRemaining0, EntryRemaining1),
    ( allowed_entry(Entry, IncludeDeprecated)
    -> directory_file_path(Dir, Entry, Raw),
       secure_descendant(Root, Raw, Path),
       scan_entry(Root, Path, IncludeDeprecated, Depth,
                   Remaining0, Remaining1,
                   EntryRemaining1, EntryRemaining2, Files0, Files1)
    ; Remaining1=Remaining0, Files1=Files0,
      EntryRemaining2=EntryRemaining1
    ),
    scan_directory_entries(Entries, Root, Dir, IncludeDeprecated, Depth,
                            Remaining1, Remaining,
                            EntryRemaining2, EntryRemaining, Files1, Files).

scan_entry(Root, Path, IncludeDeprecated, Depth,
           Remaining0, Remaining, EntryRemaining0, EntryRemaining,
           Files0, Files) :-
    exists_directory(Path), !,
    NextDepth is Depth+1,
    scan_directory(Root, Path, IncludeDeprecated, NextDepth,
                   Remaining0, Remaining, EntryRemaining0, EntryRemaining,
                   Files0, Files).
scan_entry(_, _, _, _, Remaining, Remaining, EntryRemaining, EntryRemaining,
           Files, Files).

directory_entries(Dir, Entries) :-
    directory_files(Dir, Entries0), exclude(dot_entry, Entries0, Entries1),
    sort(Entries1, Entries).

dot_entry('.').
dot_entry('..').

visit_directory_entry(Scope, Base, Remaining0, Remaining) :-
    ( Remaining0 > 0 -> Remaining is Remaining0-1
    ; directory_entries_max(Max), Actual is Max+1,
      throw(skill_fault(too_many_directory_entries(Scope, Base, Actual, Max)))
    ).

admit_skill_file(_, SkillFile, Remaining0, Remaining, Files0, Files) :-
    ( Remaining0 > 0
    -> Remaining is Remaining0-1, Files=[SkillFile|Files0]
    ; skills_per_root_max(Max),
      Actual is Max+1,
      throw(skill_fault(too_many_skills(root, Actual, Max)))
    ).

require_scan_depth(Path, Depth) :-
    skill_descendant_depth_max(Max),
    ( Depth =< Max -> true
    ; throw(skill_fault(skill_directory_too_deep(Path, Depth, Max))) ).

allowed_entry('.git', _) :- !, fail.
allowed_entry(deprecated, false) :- !, fail.
allowed_entry('in-progress', false) :- !, fail.
allowed_entry(_, _).

secure_descendant(Root, Raw, Path) :-
    lexical_within(Root, Raw), reject_symlink_descendant(Root, Raw),
    canonical_path(Raw, Path), path_within(Root, Path), !.
secure_descendant(_, Path, _) :- throw(skill_fault(path_escape(Path))).

canonical_path(Raw, Path) :-
    (exists_directory(Raw) -> Type=directory ; Type=regular),
    absolute_file_name(Raw, Path,
                       [file_type(Type), access(read), file_errors(fail),
                        solutions(first)]).

lexical_within(Root, Path) :- Path == Root, !.
lexical_within(Root, Path) :- directory_prefix(Root, Prefix),
    atom_concat(Prefix, _, Path).
path_within(Root, Path) :- lexical_within(Root, Path).

directory_prefix(Directory, Prefix) :-
    (sub_atom(Directory, _, 1, 0, '/') -> Prefix=Directory
    ; atom_concat(Directory, '/', Prefix)).

reject_symlink_descendant(Root, Path) :-
    relative_segments(Root, Path, Segments),
    reject_symlink_segments(Root, Segments).

relative_segments(Root, Root, []) :- !.
relative_segments(Root, Path, Segments) :-
    directory_prefix(Root, Prefix), atom_concat(Prefix, Relative, Path),
    atomic_list_concat(Segments0, '/', Relative),
    \+ memberchk('..', Segments0),
    exclude(empty_segment, Segments0, Segments), !.
relative_segments(Root, Path, _) :- throw(skill_fault(path_escape(Path, Root))).

empty_segment(''). empty_segment('.').
reject_symlink_segments(_, []).
reject_symlink_segments(Base, [Segment|Segments]) :-
    directory_file_path(Base, Segment, Path),
    (path_is_symlink(Path) -> throw(skill_fault(symlink_descendant(Path)))
    ; true),
    reject_symlink_segments(Path, Segments).
path_is_symlink(Path) :- catch(read_link(Path, _, _), _, fail).

admit_instruction_file(Root, SkillFile, Bytes, Hash, Content) :-
    skill_file_max_bytes(Max),
    require_file_size(SkillFile, Max, skill_file_too_large),
    read_bounded_file(SkillFile, Max, skill_file_too_large,
                      Bytes, Content, Hash),
    secure_descendant(Root, SkillFile, SkillFile).

read_bounded_file(Path, Max, Fault, Bytes, Content, Hash) :-
    require_file_size(Path, Max, Fault),
    Limit is Max+1,
    setup_call_cleanup(
        open(Path, read, Stream, [type(binary)]),
        read_string(Stream, Limit, Octets),
        close(Stream)),
    string_codes(Octets, ByteCodes),
    length(ByteCodes, Bytes),
    ( Bytes =< Max -> true
    ; throw_size_fault(Fault, Path, Bytes, Max) ),
    catch(string_bytes(Content, ByteCodes, utf8), _,
          throw(skill_fault(invalid_utf8(Path)))),
    crypto_data_hash(ByteCodes, Hash,
                     [algorithm(sha256),encoding(octet)]).

require_file_size(Path, Max, Fault) :-
    size_file(Path, Bytes),
    ( Bytes =< Max -> true
    ; throw_size_fault(Fault, Path, Bytes, Max) ).

throw_size_fault(Fault, Path, Bytes, Max) :-
    Detail =.. [Fault,Path,Bytes,Max],
    throw(skill_fault(Detail)).

load_skill(RootSpec, SkillFile, Skill) :-
    admit_instruction_file(RootSpec.path, SkillFile, InstructionBytes,
                           BodyHash, RawInstruction),
    read_frontmatter(RawInstruction, SkillFile, Frontmatter, Extension0),
    require_frontmatter_text(Frontmatter, name, NameText),
    skill_name_atom(NameText, Name),
    require_frontmatter_text(Frontmatter, description, Description0),
    standard_description(Description0, Description),
    frontmatter_boolean(Frontmatter, 'disable-model-invocation', false,
                        Disabled),
    normalize_extension(Extension0, Extension),
    automatic_policy(Disabled, Extension.automatic, Automatic),
    file_directory_name(SkillFile, SkillDir),
    relative_path(RootSpec.path, SkillDir, RelativeDir),
    skill_category(RelativeDir, PathCategory),
    (Extension.category == default -> Category=PathCategory
    ; Category=Extension.category),
    resource_index(RootSpec.path, SkillDir, Resources),
    bytes_tokens(InstructionBytes, SkillTokens),
    resource_token_sum(Resources, ResourceTokens),
    Estimate is SkillTokens+ResourceTokens,
    findall(resource(Name, ResourceBytes, ResourceFingerprint),
            (member(R, Resources), Name=R.name, ResourceBytes=R.bytes,
             ResourceFingerprint=R.fingerprint),
            ResourceFacts),
    stable_hash(skill_package(RootSpec.source, RelativeDir, BodyHash,
                              ResourceFacts), Hash),
    atom_concat(skill_, Hash, Fingerprint),
    Skill = skill{name:Name, description:Description,
                  invocation:Automatic, source:RootSpec.source,
                   root:RootSpec.path, directory:SkillDir,
                   relative_directory:RelativeDir, category:Category,
                   instruction_file:SkillFile,
                   instruction_sha256:BodyHash, resources:Resources,
                  aliases:Extension.aliases, triggers:Extension.triggers,
                  requires:Extension.requires, suggests:Extension.suggests,
                  conflicts:Extension.conflicts,
                  supersedes:Extension.supersedes,
                  requires_capability:Extension.requires_capability,
                  priority:Extension.priority, fingerprint:Fingerprint,
                  estimated_tokens:Estimate}.

automatic_policy(true, _, explicit_user) :- !.
automatic_policy(_, false, explicit_user) :- !.
automatic_policy(_, true, automatic).

resource_index(Root, SkillDir, Resources) :-
    skill_resources_max(MaxResources),
    skill_resource_aggregate_max_bytes(MaxBytes),
    directory_entries_max(EntryMax),
    scan_resources(Root, SkillDir, SkillDir, 0,
                   MaxResources, _, MaxBytes, _, EntryMax, _,
                   [], ResourcesRev),
    reverse(ResourcesRev, Resources0),
    sort_resources(Resources0, Resources).

scan_resources(Root, SkillDir, Dir, Depth,
               Count0, Count, Bytes0, Bytes,
               EntryRemaining0, EntryRemaining, Resources0, Resources) :-
    require_scan_depth(Dir, Depth),
    directory_entries(Dir, Entries),
    scan_resource_entries(Entries, Root, SkillDir, Dir, Depth,
                          Count0, Count, Bytes0, Bytes,
                          EntryRemaining0, EntryRemaining,
                          Resources0, Resources).

scan_resource_entries([], _, _, _, _, Count, Count, Bytes, Bytes,
                      EntryRemaining, EntryRemaining, Resources, Resources).
scan_resource_entries([Entry|Entries], Root, SkillDir, Dir, Depth,
                      Count0, Count, Bytes0, Bytes,
                      EntryRemaining0, EntryRemaining, Resources0, Resources) :-
    visit_directory_entry(skill, SkillDir,
                          EntryRemaining0, EntryRemaining1),
    ( memberchk(Entry, ['.git', 'SKILL.md'])
    -> directory_file_path(Dir, Entry, Instruction),
       ( Entry == 'SKILL.md' -> secure_descendant(Root, Instruction, _)
       ; true
       ),
       Count1=Count0, Bytes1=Bytes0, Resources1=Resources0
    ; directory_file_path(Dir, Entry, Raw),
      secure_descendant(SkillDir, Raw, Path),
      secure_descendant(Root, Path, _),
      resource_entry(Root, SkillDir, Path, Depth,
                     Count0, Count1, Bytes0, Bytes1,
                     EntryRemaining1, EntryRemaining2,
                     Resources0, Resources1)
    ),
    ( memberchk(Entry, ['.git', 'SKILL.md'])
    -> EntryRemaining2=EntryRemaining1
    ; true
    ),
    scan_resource_entries(Entries, Root, SkillDir, Dir, Depth,
                          Count1, Count, Bytes1, Bytes,
                          EntryRemaining2, EntryRemaining,
                          Resources1, Resources).

resource_entry(Root, SkillDir, Path, _, Count, Count, Bytes, Bytes,
               EntryRemaining, EntryRemaining, Resources, Resources) :-
    exists_directory(Path), directory_file_path(Path, 'SKILL.md', Nested),
    exists_file(Nested), Path \== SkillDir, !,
    secure_descendant(Root, Nested, _).
resource_entry(Root, SkillDir, Path, Depth,
               Count0, Count, Bytes0, Bytes,
               EntryRemaining0, EntryRemaining, Resources0, Resources) :-
    exists_directory(Path), !,
    NextDepth is Depth+1,
    scan_resources(Root, SkillDir, Path, NextDepth,
                   Count0, Count, Bytes0, Bytes,
                   EntryRemaining0, EntryRemaining, Resources0, Resources).
resource_entry(Root, SkillDir, Path, _,
               Count0, Count, Bytes0, Bytes,
               EntryRemaining, EntryRemaining, Resources0, Resources) :-
    exists_file(Path), text_resource(Path), !,
    require_resource_slot(SkillDir, Count0, Count),
    resource_file_max_bytes(Max),
    read_bounded_file(Path, Max, resource_too_large, ContentBytes, _, Hash),
    secure_descendant(SkillDir, Path, Path),
    secure_descendant(Root, Path, Path),
    resource_aggregate_bytes(SkillDir, Bytes0, ContentBytes, Bytes),
    relative_path(SkillDir, Path, Name), bytes_tokens(ContentBytes, Tokens),
    atom_concat(skill_resource_, Hash, Fingerprint),
    Resource = skill_resource{name:Name, path:Path, bytes:ContentBytes,
                              fingerprint:Fingerprint,
                              estimated_tokens:Tokens},
    Resources=[Resource|Resources0].
resource_entry(_, _, _, _, Count, Count, Bytes, Bytes,
               EntryRemaining, EntryRemaining, Resources, Resources).

require_resource_slot(SkillDir, Count0, Count) :-
    ( Count0 > 0 -> Count is Count0-1
    ; skill_resources_max(Max),
      Actual is Max+1,
      throw(skill_fault(too_many_skill_resources(SkillDir, Actual, Max))) ).

resource_aggregate_bytes(SkillDir, Remaining0, Used, Remaining) :-
    ( Used =< Remaining0 -> Remaining is Remaining0-Used
    ; skill_resource_aggregate_max_bytes(Max),
      Actual is Max-Remaining0+Used,
      throw(skill_fault(skill_resource_aggregate_too_large(
                            SkillDir, Actual, Max))) ).

sort_resources(Resources0, Resources) :-
    findall(Name-R, (member(R, Resources0), Name=R.name), Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Resources).
sort_skills(Skills0, Skills) :-
    findall(Name-S, (member(S, Skills0), Name=S.name), Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Skills).
pairs_values([], []).
pairs_values([_-V|Pairs], [V|Values]) :- pairs_values(Pairs, Values).

require_unique_names(Skills) :-
    findall(Name, (select(A, Skills, Rest), member(B, Rest),
                   A.name == B.name, Name=A.name), Names0),
    sort(Names0, Names),
    (Names == [] -> true ; throw(skill_fault(duplicate_skill_names(Names)))).

catalog_fingerprint(Roots, Skills, Fingerprint) :-
    findall(root(Source), (member(R, Roots), Source=R.source), RootFacts),
    findall(skill(Name, SkillFingerprint),
            (member(S, Skills), Name=S.name, SkillFingerprint=S.fingerprint),
            SkillFacts),
    stable_hash(skill_catalog(RootFacts, SkillFacts), Hash),
    atom_concat(skill_catalog_, Hash, Fingerprint).

read_frontmatter(Raw, Path, Frontmatter, Extension) :-
    setup_call_cleanup(open_string(Raw, Stream),
                       read_frontmatter_stream(Stream, Path, Frontmatter, Extension),
                       close(Stream)).

read_frontmatter_stream(Stream, Path, Frontmatter, Extension) :-
    read_line_to_string(Stream, First0), trim_string(First0, First),
    (First == "---" -> read_frontmatter_lines(Stream, Path, 0, [], Lines)
    ; throw(skill_fault(missing_frontmatter(Path)))),
    maplist(frontmatter_pair, Lines, Pairs0), exclude(=(none), Pairs0, Frontmatter),
    (metadata_json_lines(Lines, JsonLines)
    -> atomics_to_string(JsonLines, "\n", JsonText),
       catch(atom_json_dict(JsonText, Extension, []), _,
             throw(skill_fault(invalid_prolog_rlm_metadata(json))))
    ; Extension=none).

read_frontmatter_lines(Stream, Path, Bytes0, Acc, Lines) :-
    read_line_to_string(Stream, Line0),
    (Line0 == end_of_file -> throw(skill_fault(unterminated_frontmatter(Path)))
    ; string_bytes(Line0, LineBytes, utf8), length(LineBytes, Length),
      Bytes is Bytes0+Length+1,
      frontmatter_max_bytes(Max),
      (Bytes =< Max -> true ; throw(skill_fault(frontmatter_too_large(Path)))),
      trim_string(Line0, Line),
      (Line == "---" -> reverse(Acc, Lines)
      ; read_frontmatter_lines(Stream, Path, Bytes, [Line0|Acc], Lines))).

frontmatter_pair(Line0, Pair) :-
    ( line_indent(Line0, 0)
    -> trim_string(Line0, Line),
       ( Line == "" -> Pair=none
       ; sub_string(Line, 0, 1, _, "#") -> Pair=none
       ; sub_string(Line, Before, 1, After, ":")
       -> sub_string(Line, 0, Before, _, Key0), Start is Before+1,
          sub_string(Line, Start, After, 0, Value0),
          trim_string(Key0, KeyText), trim_string(Value0, Raw),
          atom_string(Key, KeyText), yaml_scalar(Raw, Value), Pair=Key-Value
       ; Pair=none
       )
    ; Pair=none
    ), !.

yaml_scalar(Raw, Value) :-
    string_length(Raw, Length), Length >= 2,
    sub_string(Raw, 0, 1, _, Quote), memberchk(Quote, ["\"", "'"]),
    Last is Length-1, sub_string(Raw, Last, 1, 0, Quote), !,
    Inner is Length-2, sub_string(Raw, 1, Inner, 1, Value).
yaml_scalar(Raw, Raw).

metadata_json_lines(Lines, JsonLines) :-
    append(_, [Metadata|AfterMetadata], Lines),
    line_indent(Metadata, 0), trim_string(Metadata, "metadata:"),
    take_top_level_map_lines(AfterMetadata, MetadataLines),
    append(_, [Header|After], MetadataLines),
    line_indent(Header, 2),
    trim_string(Header, HeaderText),
    memberchk(HeaderText, ["prolog-rlm: |", "prolog-rlm: |-",
                           "prolog-rlm: |+"]),
    take_json_lines(After, JsonLines), JsonLines \== [], !.

take_top_level_map_lines([], []).
take_top_level_map_lines([Line|Lines], MapLines) :-
    ( trim_string(Line, "")
    -> MapLines=[Line|Rest], take_top_level_map_lines(Lines, Rest)
    ; line_indent(Line, Indent), Indent > 0
    -> MapLines=[Line|Rest], take_top_level_map_lines(Lines, Rest)
    ; MapLines=[]
    ).

take_json_lines([], []).
take_json_lines([Line|Lines], JsonLines) :-
    (trim_string(Line, "") -> JsonLines=[""|Rest], take_json_lines(Lines, Rest)
    ; line_indent(Line, Indent), Indent >= 4
    -> sub_string(Line, 4, _, 0, Text), JsonLines=[Text|Rest],
       take_json_lines(Lines, Rest)
    ; JsonLines=[]).

line_indent(Line, Indent) :- string_codes(Line, Codes),
    leading_spaces(Codes, 0, Indent).
leading_spaces([0' |Codes], N0, N) :- !, N1 is N0+1,
    leading_spaces(Codes, N1, N).
leading_spaces(_, N, N).

normalize_extension(none,
    skill_extension{category:default, aliases:[], triggers:[], requires:[],
                    suggests:[], conflicts:[], supersedes:[],
                    requires_capability:none, priority:100,
                    automatic:true}) :- !.
normalize_extension(Raw, Extension) :-
    (is_dict(Raw) -> true
    ; throw(skill_fault(invalid_prolog_rlm_metadata(expected_object)))),
    dict_pairs(Raw, _, Pairs), pairs_keys(Pairs, Keys),
    Allowed=[activation,aliases,category,conflicts,priority,requires,
             requires_capability,schema,suggests,supersedes,triggers],
    subtract(Keys, Allowed, Unknown),
    (Unknown == [] -> true
    ; throw(skill_fault(unsupported_prolog_rlm_metadata(unknown_keys(Unknown))))),
    (get_dict(schema, Raw, 1) -> true
    ; throw(skill_fault(unsupported_prolog_rlm_metadata(schema))), fail),
    extension_category(Raw, Category), extension_aliases(Raw, Aliases),
    extension_triggers(Raw, Triggers),
    extension_relations(Raw, requires, Requires),
    extension_relations(Raw, suggests, Suggests),
    extension_relations(Raw, conflicts, Conflicts),
    extension_relations(Raw, supersedes, Supersedes),
    extension_capability(Raw, Capability), extension_priority(Raw, Priority),
    extension_automatic(Raw, Automatic),
    Extension=skill_extension{category:Category, aliases:Aliases,
                              triggers:Triggers, requires:Requires,
                              suggests:Suggests, conflicts:Conflicts,
                              supersedes:Supersedes,
                              requires_capability:Capability,
                              priority:Priority, automatic:Automatic}.

extension_category(Raw, Category) :-
    (get_dict(category, Raw, V) -> bounded_identifier(V, Category)
    ; Category=default).
extension_aliases(Raw, Aliases) :-
    (get_dict(aliases, Raw, V) -> bounded_list(V, aliases, 32),
                                  maplist(bounded_text, V, Aliases)
    ; Aliases=[]).
extension_triggers(Raw, Triggers) :-
    (get_dict(triggers, Raw, V) -> bounded_list(V, triggers, 32),
                                   maplist(extension_trigger, V, Triggers)
    ; Triggers=[]).
extension_trigger(V, trigger(Signal, Weight)) :-
    is_dict(V), get_dict(kind, V, K0), bounded_identifier(K0, K),
    memberchk(K, [phrase,keyword,verb,object,need,signal]),
    get_dict(value, V, T0), bounded_text(T0, T),
    get_dict(weight, V, Weight), integer(Weight), between(0,100000,Weight),
    trigger_signal(K, T, Signal), !.
extension_trigger(V, _) :-
    throw(skill_fault(unsupported_prolog_rlm_metadata(trigger(V)))).
trigger_signal(phrase,T,phrase(T)). trigger_signal(keyword,T,keyword(T)).
trigger_signal(verb,T,verb(A)) :- atom_string(A,T).
trigger_signal(object,T,object(A)) :- atom_string(A,T).
trigger_signal(need,T,need(A)) :- atom_string(A,T).
trigger_signal(signal,T,signal(A)) :- atom_string(A,T).

extension_relations(Raw, Key, Units) :-
    (get_dict(Key, Raw, V) -> bounded_list(V, Key, 64),
                              maplist(extension_unit, V, Units)
    ; Units=[]).
extension_unit(V, Unit) :-
    is_dict(V), get_dict(kind,V,K0), get_dict(name,V,N0),
    bounded_identifier(K0,K), bounded_identifier(N0,N),
    extension_unit_kind(K,N,Unit), !.
extension_unit(V, _) :-
    throw(skill_fault(unsupported_prolog_rlm_metadata(unit(V)))).
extension_unit_kind(skill,N,skill(N)).
extension_unit_kind(tool,N,tool(N)).
extension_unit_kind(resource,N,resource(N)).

extension_capability(Raw, Capability) :-
    (get_dict(requires_capability, Raw, null) -> Capability=none
    ; get_dict(requires_capability, Raw, V)
    -> throw(skill_fault(unsupported_prolog_rlm_metadata(requires_capability(V))))
    ; Capability=none).
extension_priority(Raw, Priority) :-
    (get_dict(priority,Raw,V) -> integer(V),between(0,100000,V),Priority=V
    ; Priority=100), !.
extension_priority(Raw, _) :-
    throw(skill_fault(unsupported_prolog_rlm_metadata(priority(Raw.priority)))).
extension_automatic(Raw, Automatic) :-
    (get_dict(activation,Raw,A) -> valid_extension_activation(A),
                                  get_dict(automatic,A,Automatic),
                                  require_boolean(Automatic,automatic)
    ; Automatic=true), !.
extension_automatic(Raw, _) :-
    throw(skill_fault(unsupported_prolog_rlm_metadata(activation(Raw.activation)))).

valid_extension_activation(Activation) :-
    is_dict(Activation),
    dict_pairs(Activation,_,Pairs),
    pairs_keys(Pairs,[automatic]), !.
valid_extension_activation(Activation) :-
    throw(skill_fault(unsupported_prolog_rlm_metadata(
                          activation(Activation)))).

skill_prompt_unit(Skill, Options, Outcome) :-
    catch(skill_prompt_unit_(Skill, Options, Outcome), E,
          skill_exception(prompt_unit, E, Outcome)), !.

skill_prompt_unit_(Skill, Options, ok(Unit)) :-
    require_skill(Skill), require_list(Options, options),
    option_value(load_content, Options, true, LoadContent),
    require_boolean(LoadContent, load_content),
    prompt_unit_content(LoadContent, Skill, Content),
    prompt_policy(Skill, Options, Policy),
    format(string(Provenance), "skill(~w,~w)",
           [Skill.source,Skill.fingerprint]),
    Unit=prompt_unit{unit:skill(Skill.name), name:Skill.name, kind:skill,
                     category:Policy.category, description:Skill.description,
                     available:Policy.available,
                     activation:Policy.activation,
                     aliases:Skill.aliases,
                     triggers:Skill.triggers, requires:Skill.requires,
                     suggests:Skill.suggests, conflicts:Skill.conflicts,
                     supersedes:Skill.supersedes,
                     requires_capability:Policy.requires_capability,
                     priority:Policy.priority,
                     provider_visible:Policy.provider_visible,
                     mandatory_context:Policy.mandatory_context,
                     schema:none, content:Content, representations:[],
                     provenance:Provenance}.

prompt_unit_content(false, _, none) :- !.
prompt_unit_content(true, Skill, Body) :-
    secure_instruction_path(Skill, InstructionFile),
    skill_file_max_bytes(FileMax),
    read_bounded_file(InstructionFile, FileMax, skill_file_too_large,
                      _, Raw, Hash),
    secure_instruction_path(Skill, InstructionFile),
    ( Hash == Skill.instruction_sha256 -> true
    ; throw(skill_fault(instruction_fingerprint_mismatch(Skill.name))) ),
    strip_frontmatter(Raw, Body),
    string_bytes(Body, BodyBytes, utf8), length(BodyBytes, Bytes),
    skill_body_max_bytes(Max),
    ( Bytes =< Max -> true
    ; throw(skill_fault(skill_body_too_large(InstructionFile,Bytes,Max))) ).

skill_catalog_prompt_units(Catalog, Options, Outcome) :-
    catch((require_catalog(Catalog), require_list(Options,options),
           maplist(prompt_unit_value(Options), Catalog.skills, Units),
           Outcome=ok(Units)), E, skill_exception(prompt_units,E,Outcome)), !.
prompt_unit_value(Options, Skill, Unit) :-
    skill_prompt_unit_(Skill, Options, ok(Unit)).

prompt_policy(Skill, Options,
              skill_policy{category:Category,available:Available,
                           activation:Activation,
                           requires_capability:Capability,priority:Priority,
                           provider_visible:Visible,
                           mandatory_context:Mandatory}) :-
    option_value(category,Options,Skill.category,C0),
    bounded_identifier(C0,Category),
    default_availability(Skill,DefaultAvailable),
    option_value(available,Options,DefaultAvailable,Available),
    require_boolean(Available,available),
    option_value(activation,Options,relevant,Activation0),
    normalize_activation(Activation0,Activation),
    option_value(requires_capability,Options,Skill.requires_capability,Capability),
    require_ground(Capability,requires_capability),
    option_value(priority,Options,Skill.priority,Priority),
    require_nonnegative_integer(Priority,priority),
    option_value(provider_visible,Options,true,Visible),
    require_boolean(Visible,provider_visible),
    option_value(mandatory_context,Options,false,Mandatory),
    require_boolean(Mandatory,mandatory_context).
default_availability(Skill,true) :- Skill.invocation == automatic, !.
default_availability(_,false).

normalize_activation(relevant,relevant) :- !.
normalize_activation(always,always) :- !.
normalize_activation(Value,_) :-
    throw(skill_fault(invalid_option(activation,Value))).

secure_instruction_path(Skill, Path) :-
    directory_file_path(Skill.directory, 'SKILL.md', Raw),
    secure_descendant(Skill.root, Raw, Path), exists_file(Path), !.
secure_instruction_path(Skill, _) :-
    throw(skill_fault(skill_instruction_missing(Skill.name))).

strip_frontmatter(Raw, Body) :-
    split_string(Raw,"\n","",Lines),
    (Lines=["---"|Rest] -> drop_frontmatter(Rest,BodyLines0)
    ; BodyLines0=Lines),
    drop_blank(BodyLines0,BodyLines), atomics_to_string(BodyLines,"\n",Body).
drop_frontmatter([], []).
drop_frontmatter(["---"|Lines], Lines) :- !.
drop_frontmatter([_|Lines], Body) :- drop_frontmatter(Lines, Body).
drop_blank([""|Lines], Rest) :- !, drop_blank(Lines,Rest).
drop_blank(Lines,Lines).

skill_read_resource(Skill, Relative0, Outcome) :-
    catch((require_skill(Skill), admitted_resource(Skill, Relative0, Resource),
           secure_resource_path(Skill,Resource.name,Path),
           (text_resource(Path) -> true
           ; throw(skill_fault(non_text_resource(Relative0)))),
           resource_file_max_bytes(Max),
           read_bounded_file(Path, Max, resource_too_large, _, Content, Hash),
           secure_resource_path(Skill,Resource.name,Path),
           atom_concat(skill_resource_, Hash, Fingerprint),
           ( Fingerprint == Resource.fingerprint -> true
           ; throw(skill_fault(resource_fingerprint_mismatch(Resource.name))) ),
           Outcome=ok(Content)),
          E, skill_exception(resource,E,Outcome)), !.

admitted_resource(Skill, Relative0, Resource) :-
    path_atom(Relative0, Relative), safe_relative_resource(Relative),
    ( member(Resource, Skill.resources), Resource.name == Relative -> true
    ; throw(skill_fault(resource_not_admitted(Relative))) ).

secure_resource_path(Skill, Relative0, Path) :-
    path_atom(Relative0,Relative), safe_relative_resource(Relative),
    directory_file_path(Skill.directory,Relative,Raw),
    secure_descendant(Skill.root, Raw, Path0),
    path_within(Skill.directory,Path0), !,
    Path=Path0.
secure_resource_path(_, Relative, _) :-
    throw(skill_fault(resource_path_escape(Relative))).

safe_relative_resource(Relative) :-
    Relative \== '', \+ is_absolute_file_name(Relative),
    atomic_list_concat(Segments,'/',Relative), \+ memberchk('..',Segments), !.
safe_relative_resource(Relative) :-
    throw(skill_fault(invalid_resource_path(Relative))).

text_resource(Path) :- file_base_name(Path,Base),
    memberchk(Base,['Makefile','Dockerfile']), !.
text_resource(Path) :- file_name_extension(_,Ext0,Path), downcase_atom(Ext0,Ext),
    memberchk(Ext,[md,txt,sh,bash,zsh,fish,json,yaml,yml,toml,ini,cfg,org,
                   html,css,js,jsx,ts,tsx,py,pl,el,lisp,cl,scm,nim,rs,c,h,
                   cc,cpp,hpp,java,go,rb]).

resource_token_sum(Resources,Tokens) :-
    findall(T, (member(R,Resources),T=R.estimated_tokens), Ts), sum_list(Ts,Tokens).
bytes_tokens(Bytes,Tokens) :- Tokens is max(1,(Bytes+3)//4).

require_skill_count(catalog, Skills) :-
    skills_per_catalog_max(Max), require_skill_count_(catalog, Skills, Max).
require_skill_count_(Scope, Skills, Max) :-
    length(Skills, Count),
    ( Count =< Max -> true
    ; throw(skill_fault(too_many_skills(Scope, Count, Max))) ).

relative_path(Root,Path,Relative) :-
    (Path==Root -> Relative='.'
    ; directory_prefix(Root,Prefix),atom_concat(Prefix,Relative,Path)).
skill_category('.',root) :- !.
skill_category(Relative,Category) :- atomic_list_concat([Category|_],'/',Relative).

require_frontmatter_text(Pairs,Key,Value) :-
    (memberchk(Key-Raw,Pairs),nonempty_text(Raw) -> text_string(Raw,Value)
    ; throw(skill_fault(missing_frontmatter_field(Key)))).
frontmatter_boolean(Pairs,Key,Default,Value) :-
    (memberchk(Key-Raw,Pairs) -> parse_boolean(Raw,Value) ; Value=Default).
parse_boolean(Raw0,Value) :- text_string(Raw0,Raw),string_lower(Raw,Lower),
    (Lower=="true" -> Value=true ; Lower=="false" -> Value=false
    ; throw(skill_fault(invalid_boolean(Raw0)))).

bounded_identifier(Value,Atom) :- text_string(Value,Text),
    string_length(Text,L),L>0,L=<128,atom_string(Atom,Text),valid_skill_name(Atom),!.
bounded_identifier(Value,_) :-
    throw(skill_fault(unsupported_prolog_rlm_metadata(identifier(Value)))).
bounded_text(Value,Text) :- text_string(Value,Text),
    string_length(Text,L),L>0,L=<128,!.
bounded_text(Value,_) :-
    throw(skill_fault(unsupported_prolog_rlm_metadata(text(Value)))).
bounded_list(V,_,Max) :- is_list(V),length(V,N),N=<Max,!.
bounded_list(V,Field,_) :-
    throw(skill_fault(unsupported_prolog_rlm_metadata(list(Field,V)))).

skill_name_atom(Name,Name) :- atom(Name),standard_skill_name(Name),!.
skill_name_atom(Name0,Name) :- string(Name0),atom_string(Name,Name0),
    standard_skill_name(Name),!.
skill_name_atom(Name,_) :- throw(skill_fault(invalid_skill_name(Name))).
standard_skill_name(Name) :-
    atom_length(Name, Length), Length >= 1, Length =< 64,
    atom_chars(Name, Chars), Chars=[First|_], last(Chars, Last),
    standard_skill_name_edge(First), standard_skill_name_edge(Last),
    maplist(standard_skill_name_char, Chars),
    \+ sub_atom(Name, _, 2, _, '--').
standard_skill_name_char(C) :- char_type(C, lower), !.
standard_skill_name_char(C) :- char_type(C, digit), !.
standard_skill_name_char('-').
standard_skill_name_edge(C) :- char_type(C, lower), !.
standard_skill_name_edge(C) :- char_type(C, digit).
valid_skill_name(Name) :- atom_chars(Name,[First|Rest]),char_type(First,alnum),
    maplist(skill_name_char,Rest).
skill_name_char(C) :- char_type(C,alnum),!.
skill_name_char('-'). skill_name_char('_').

standard_description(Description, Description) :-
    string_length(Description, Length), Length >= 1, Length =< 1024, !.
standard_description(Description, _) :-
    throw(skill_fault(invalid_skill_description(Description))).

stable_hash(Term,Hash) :- term_string(Term,Text,
    [quoted(true),numbervars(true),ignore_ops(true)]),
    crypto_data_hash(Text,Hash,[algorithm(sha256),encoding(utf8)]).

require_catalog(C) :- is_dict(C,skill_catalog),is_list(C.skills),
    is_list(C.roots),get_dict(fingerprint,C,_),!.
require_catalog(C) :- throw(skill_fault(invalid_skill_catalog(C))).
require_skill(S) :- is_dict(S,skill),atom(S.directory),atom(S.root),!.
require_skill(S) :- throw(skill_fault(invalid_skill(S))).
require_boolean(true,_). require_boolean(false,_).
require_boolean(V,N) :- throw(skill_fault(invalid_option(N,V))).
require_list(V,_) :- is_list(V),!.
require_list(V,N) :- throw(skill_fault(invalid_option(N,V))).
require_ground(V,_) :- ground(V),!.
require_ground(V,N) :- throw(skill_fault(non_ground(N,V))).
require_nonnegative_integer(V,_) :- integer(V),V>=0,!.
require_nonnegative_integer(V,N) :- throw(skill_fault(invalid_option(N,V))).
nonempty_text(V) :- text_string(V,T),T\=="".
text_string(V,V) :- string(V),!.
text_string(V,T) :- atom(V),!,atom_string(V,T).
text_string(V,_) :- throw(skill_fault(expected_text(V))).
trim_string(end_of_file,"") :- !.
trim_string(T0,T) :- text_string(T0,Raw),normalize_space(string(T),Raw).
path_atom(P,P) :- atom(P),!.
path_atom(P0,P) :- string(P0),!,atom_string(P,P0).
path_atom(P,_) :- throw(skill_fault(invalid_path(P))).
option_value(Name,Options,Default,Value) :-
    (member(O,Options),nonvar(O),O=..[Name,Found] -> Value=Found ; Value=Default).

skill_exception(Phase,skill_fault(Detail),
    error(skill_error{kind:skill_fault,phase:Phase,detail:Detail,
                      message:"skill operation rejected"})) :- !.
skill_exception(Phase,E,
    error(skill_error{kind:exception,phase:Phase,exception:Safe,
                      message:"skill operation failed"})) :-
    catch(term_string(E,Safe,[quoted(true),numbervars(true),max_depth(8)]),_,
          Safe="<unprintable exception>").
