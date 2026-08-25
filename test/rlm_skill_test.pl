:- begin_tests(rlm_skill).

:- use_module('../prolog/rlm_skill').
:- use_module('../prolog/rlm_prompt_compiler').
:- use_module(library(filesex)).

:- dynamic skill_test_directory/1.
:- prolog_load_context(directory, TestDirectory),
   assertz(skill_test_directory(TestDirectory)).

fixture_root(Root) :-
    skill_test_directory(TestDir),
    directory_file_path(TestDir, 'fixtures/skills', Root).

fixture_catalog(Catalog) :-
    fixture_root(Root),
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)).

test(loader_keeps_body_and_resources_inert) :-
    fixture_catalog(Catalog),
    skill_catalog_skill(Catalog, tdd, Skill),
    assertion(Skill.invocation == automatic),
    assertion(atomic(Skill.fingerprint)),
    assertion(\+ get_dict(content, Skill, _)),
    once(member(Resource, Skill.resources)),
    assertion(Resource.name == 'tests.md'),
    assertion(\+ get_dict(content, Resource, _)).

test(metadata_only_prompt_unit_does_not_reopen_instruction,
     [setup(single_skill_fixture(Root, SkillFile, "ORIGINAL_BODY\n")),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)),
    skill_catalog_skill(Catalog, bounded, Skill),
    delete_file(SkillFile),
    skill_prompt_unit(Skill, [load_content(false)], ok(Unit)),
    assertion(Unit.content == none),
    assertion(Unit.unit == skill(bounded)),
    assertion(Unit.description == Skill.description),
    assertion(Unit.category == root),
    assertion(Unit.aliases == Skill.aliases),
    assertion(Unit.triggers == Skill.triggers),
    assertion(Unit.requires == Skill.requires),
    assertion(Unit.priority == Skill.priority).

test(load_content_defaults_true) :-
    fixture_catalog(Catalog),
    skill_catalog_skill(Catalog, tdd, Skill),
    skill_prompt_unit(Skill, [], ok(Unit)),
    assertion(sub_string(Unit.content, _, _, _, "TDD_SKILL_MARKER")).

test(instruction_mutation_after_admission_is_rejected,
     [setup(single_skill_fixture(Root, SkillFile, "ADMITTED_BODY\n")),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)),
    skill_catalog_skill(Catalog, bounded, Skill),
    get_dict(instruction_sha256, Skill, InstructionHash),
    assertion(atom(InstructionHash)),
    write_text_file(SkillFile,
                    "---\nname: bounded\ndescription: Bounded fixture.\n---\nMUTATED_BODY\n"),
    skill_prompt_unit(Skill, [], Outcome),
    Outcome = error(Error),
    assertion(Error.phase == prompt_unit),
    get_dict(detail, Error, Detail),
    assertion(Detail = instruction_fingerprint_mismatch(_)).

test(claude_disable_model_invocation_disables_default_availability) :-
    fixture_catalog(Catalog),
    skill_catalog_skill(Catalog, 'grill-me', Skill),
    assertion(Skill.invocation == explicit_user),
    skill_prompt_unit(Skill, [], ok(Unit)),
    assertion(Unit.available == false),
    setup_call_cleanup(
        prompt_catalog_create(PromptCatalog),
        ( prompt_catalog_register(PromptCatalog, Unit, ok(_)),
          prompt_compile(PromptCatalog, "grill me", [pack(false)], ok(Compiled)),
          assertion(\+ memberchk(skill('grill-me'), Compiled.active_units))
        ),
        prompt_catalog_destroy(PromptCatalog)).

test(strict_standard_skill_converts_to_canonical_prompt_unit) :-
    fixture_catalog(Catalog),
    skill_catalog_skill(Catalog, tdd, Skill),
    skill_prompt_unit(Skill,
                      [provider_visible(true), mandatory_context(false)],
                      ok(Unit)),
    assertion(Unit.unit == skill(tdd)),
    assertion(Unit.kind == skill),
    assertion(Unit.description == Skill.description),
    assertion(Unit.category == engineering),
    assertion(Unit.activation == relevant),
    assertion(Unit.provider_visible == true),
    assertion(Unit.mandatory_context == false),
    assertion(sub_string(Unit.content, _, _, _, "TDD_SKILL_MARKER")),
    assertion(\+ sub_string(Unit.content, _, _, _, "TDD_RESOURCE_MARKER")),
    assertion(\+ get_dict(resources, Unit, _)),
    setup_call_cleanup(
        prompt_catalog_create(PromptCatalog),
        prompt_catalog_register(PromptCatalog, Unit, ok(Registration)),
        prompt_catalog_destroy(PromptCatalog)),
    assertion(Registration.unit == skill(tdd)).

test(host_can_pin_skill_activation_always) :-
    fixture_catalog(Catalog),
    skill_catalog_skill(Catalog, tdd, Skill),
    skill_prompt_unit(Skill, [activation(always)], ok(Unit)),
    assertion(Unit.activation == always).

test(invalid_host_activation_is_rejected) :-
    fixture_catalog(Catalog),
    skill_catalog_skill(Catalog, tdd, Skill),
    skill_prompt_unit(Skill, [activation(package)], Outcome),
    Outcome = error(Error),
    assertion(get_dict(phase, Error, prompt_unit)),
    assertion(get_dict(detail, Error,
                       invalid_option(activation, package))).

test(skill_metadata_cannot_self_promote_to_always,
     [setup(self_promoting_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], Outcome),
    Outcome = error(Error),
    assertion(Error.phase == load),
    assertion(Error.kind == skill_fault),
    assertion(Error.detail = unsupported_prolog_rlm_metadata(_)).

test(catalog_conversion_returns_one_prompt_unit_per_skill) :-
    fixture_catalog(Catalog),
    skill_catalog_prompt_units(Catalog, [], ok(Units)),
    length(Catalog.skills, Count),
    length(Units, Count),
    forall(member(Unit, Units), assertion(Unit.kind == skill)).

test(enriched_metadata_maps_closed_routing_fields) :-
    fixture_catalog(Catalog),
    skill_catalog_skill(Catalog, enriched, Skill),
    assertion(Skill.category == review),
    assertion(Skill.aliases == ["pr review"]),
    assertion(Skill.triggers == [trigger(phrase("review pull request"),80)]),
    assertion(Skill.requires == [tool(git_diff)]),
    assertion(Skill.suggests == [skill(tdd)]),
    assertion(Skill.priority == 200),
    assertion(Skill.invocation == explicit_user),
    skill_prompt_unit(Skill, [], ok(Unit)),
    assertion(Unit.available == false),
    assertion(Unit.requires == [tool(git_diff)]),
    assertion(sub_string(Unit.content, _, _, _, "ENRICHED_SKILL_MARKER")).

test(host_policy_not_skill_file_controls_prompt_visibility) :-
    fixture_catalog(Catalog),
    skill_catalog_skill(Catalog, tdd, Skill),
    skill_prompt_unit(Skill,
                      [ available(false),
                        provider_visible(false),
                        mandatory_context(true),
                        priority(7),
                        requires_capability(skill(tdd))
                      ],
                      ok(Unit)),
    assertion(Unit.available == false),
    assertion(Unit.provider_visible == false),
    assertion(Unit.mandatory_context == true),
    assertion(Unit.priority == 7),
    assertion(Unit.requires_capability == skill(tdd)).

test(resource_body_is_loaded_only_by_explicit_safe_read) :-
    fixture_catalog(Catalog),
    skill_catalog_skill(Catalog, tdd, Skill),
    skill_prompt_unit(Skill, [], ok(Unit)),
    assertion(\+ sub_string(Unit.content, _, _, _, "TDD_RESOURCE_MARKER")),
    skill_read_resource(Skill, "tests.md", ok(Content)),
    assertion(sub_string(Content, _, _, _, "TDD_RESOURCE_MARKER")),
    skill_read_resource(Skill, "../../../outside.txt", error(Error)),
    assertion(Error.phase == resource),
    assertion(Error.kind == skill_fault).

test(resource_mutation_after_admission_is_rejected,
     [setup(resource_fixture(Root, ResourceFile)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)),
    skill_catalog_skill(Catalog, bounded, Skill),
    write_text_file(ResourceFile, "MUTATED_RESOURCE\n"),
    skill_read_resource(Skill, "resource.md", error(Error)),
    assertion(Error.phase == resource),
    assertion(Error.detail = resource_fingerprint_mismatch('resource.md')).

test(resource_read_rejects_files_not_admitted_to_index,
     [setup(resource_fixture(Root, _)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)),
    skill_catalog_skill(Catalog, bounded, Skill),
    directory_file_path(Skill.directory, 'late.md', Late),
    write_text_file(Late, "LATE_RESOURCE\n"),
    skill_read_resource(Skill, "late.md", error(LateError)),
    assertion(LateError.detail == resource_not_admitted('late.md')),
    skill_read_resource(Skill, "SKILL.md", error(SkillError)),
    assertion(SkillError.detail == resource_not_admitted('SKILL.md')).

test(skill_file_total_size_is_bounded_before_frontmatter_read,
     [setup(oversized_instruction_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], Outcome),
    Outcome = error(Error),
    assertion(Error.phase == load),
    get_dict(detail, Error, Detail),
    assertion(Detail = skill_file_too_large(_, _, _)).

test(stripped_body_byte_limit_is_enforced,
     [setup(body_limit_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)),
    skill_catalog_skill(Catalog, bounded, Skill),
    skill_prompt_unit(Skill, [], Outcome),
    Outcome = error(Error),
    get_dict(detail, Error, Detail),
    assertion(Detail = skill_body_too_large(_, 32769, 32768)).

test(stripped_body_at_byte_limit_is_accepted,
     [setup(body_size_fixture(32768, Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)),
    skill_catalog_skill(Catalog, bounded, Skill),
    skill_prompt_unit(Skill, [], ok(Unit)),
    string_bytes(Unit.content, BodyBytes, utf8),
    length(BodyBytes, 32768).

test(catalog_rejects_too_many_skills_per_root,
    [setup(too_many_skills_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], Outcome),
    Outcome = error(Error),
    get_dict(detail, Error, Detail),
    assertion(Detail = too_many_skills(root, _, _)).

test(catalog_rejects_too_many_configured_roots,
     [setup(too_many_roots_fixture(Parent, Roots)),
      cleanup(delete_directory_and_contents(Parent))]) :-
    skill_catalog_load(Roots, [], Outcome),
    Outcome = error(Error),
    assertion(Error.detail == too_many_skill_roots(17, 16)).

test(catalog_root_counts_ignored_and_non_text_directory_entries,
     [setup(too_many_root_entries_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load(Root, [], Outcome),
    Outcome = error(Error),
    get_dict(detail, Error, Detail),
    assertion(Detail = too_many_directory_entries(root, Root, 4097, 4096)).

test(skill_package_counts_ignored_non_text_resources,
     [setup(too_many_package_entries_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load(Root, [], Outcome),
    Outcome = error(Error),
    get_dict(detail, Error, Detail),
    assertion(Detail = too_many_directory_entries(skill, Root, 4097, 4096)).

test(catalog_merge_rejects_too_many_skills) :-
    oversized_catalog(Catalog),
    skill_catalog_empty(Empty),
    skill_catalog_merge(Catalog, Empty, Outcome),
    Outcome = error(Error),
    get_dict(detail, Error, Detail),
    assertion(Detail = too_many_skills(catalog, 513, 512)).

test(catalog_rejects_excessive_descendant_depth,
    [setup(deep_skill_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], Outcome),
    Outcome = error(Error),
    get_dict(detail, Error, Detail),
    assertion(Detail = skill_directory_too_deep(_, _, _)).

test(catalog_rejects_too_many_resources,
    [setup(too_many_resources_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], Outcome),
    Outcome = error(Error),
    get_dict(detail, Error, Detail),
    assertion(Detail = too_many_skill_resources(_, _, _)).

test(catalog_rejects_excessive_aggregate_resource_bytes,
     [setup(aggregate_resource_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], Outcome),
    Outcome = error(Error),
    get_dict(detail, Error, Detail),
    assertion(Detail = skill_resource_aggregate_too_large(_, _, 4194304)).

test(prolog_rlm_metadata_allows_prior_string_siblings,
     [setup(later_metadata_header_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)),
    skill_catalog_skill(Catalog, bounded, Skill),
    assertion(Skill.aliases == ["evil"]),
    assertion(Skill.category == evil).

test(prolog_rlm_metadata_stops_at_next_top_level_key,
     [setup(out_of_scope_metadata_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load(Root, [], ok(Catalog)),
    skill_catalog_skill(Catalog, bounded, Skill),
    assertion(Skill.aliases == []),
    assertion(Skill.category == root).

test(nested_frontmatter_identity_is_not_top_level_identity,
     [setup(nested_identity_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load(Root, [], Outcome),
    Outcome = error(Error),
    assertion(Error.detail == missing_frontmatter_field(name)).

test(nested_resource_is_indexed_but_not_bulk_loaded,
     [setup(nested_resource_fixture(Root)),
      cleanup(delete_directory_and_contents(Root))]) :-
    skill_catalog_load([skill_root(test, Root)], [], ok(Catalog)),
    skill_catalog_skill(Catalog, 'script-skill', Skill),
    once(member(Resource, Skill.resources)),
    assertion(Resource.name == 'scripts/template.sh'),
    skill_prompt_unit(Skill, [], ok(Unit)),
    assertion(\+ sub_string(Unit.content, _, _, _,
                            "NESTED_SCRIPT_RESOURCE_MARKER")),
    skill_read_resource(Skill, Resource.name, ok(ResourceBody)),
    assertion(sub_string(ResourceBody, _, _, _,
                         "NESTED_SCRIPT_RESOURCE_MARKER")).

nested_resource_fixture(Root) :-
    tmp_file(skill_nested_resource, Root), make_directory(Root),
    directory_file_path(Root, 'script-skill', SkillDir), make_directory(SkillDir),
    directory_file_path(SkillDir, 'SKILL.md', SkillFile),
    write_text_file(SkillFile,
        "---\nname: script-skill\ndescription: Script fixture.\n---\nSCRIPT_BODY\n"),
    directory_file_path(SkillDir, scripts, Scripts), make_directory(Scripts),
    directory_file_path(Scripts, 'template.sh', Script),
    write_text_file(Script, "#!/bin/sh\n# NESTED_SCRIPT_RESOURCE_MARKER\n").

self_promoting_fixture(Root) :-
    tmp_file(skill_self_promoting, Root), make_directory(Root),
    directory_file_path(Root, malicious, SkillDir), make_directory(SkillDir),
    directory_file_path(SkillDir, 'SKILL.md', SkillFile),
    write_text_file(SkillFile,
        "---\nname: malicious\ndescription: Attempts to self-promote.\nmetadata:\n  prolog-rlm: |-\n    {\"schema\":1,\"activation\":{\"automatic\":true,\"mode\":\"always\"}}\n---\nMALICIOUS_BODY\n").

single_skill_fixture(Root, SkillFile, Body) :-
    tmp_file(skill_bounded, Root), make_directory(Root),
    directory_file_path(Root, 'SKILL.md', SkillFile),
    string_concat("---\nname: bounded\ndescription: Bounded fixture.\n---\n",
                  Body, Text),
    write_text_file(SkillFile, Text).

resource_fixture(Root, ResourceFile) :-
    single_skill_fixture(Root, _, "BODY\n"),
    directory_file_path(Root, 'resource.md', ResourceFile),
    write_text_file(ResourceFile, "ADMITTED_RESOURCE\n").

oversized_instruction_fixture(Root) :-
    tmp_file(skill_oversized, Root), make_directory(Root),
    directory_file_path(Root, 'SKILL.md', SkillFile),
    rlm_skill:skill_file_max_bytes(Max),
    Count is Max+1,
    write_repeated_byte_file(SkillFile, 0'a, Count).

body_limit_fixture(Root) :-
    body_size_fixture(32769, Root).

body_size_fixture(BodyBytes, Root) :-
    tmp_file(skill_body_limit, Root), make_directory(Root),
    directory_file_path(Root, 'SKILL.md', SkillFile),
    Header = "---\nname: bounded\ndescription: Bounded fixture.\n---\n",
    setup_call_cleanup(
        open(SkillFile, write, Stream, [type(binary)]),
        ( string_codes(Header, HeaderCodes), maplist(put_byte(Stream), HeaderCodes),
          forall(between(1, BodyBytes, _), put_byte(Stream, 0'a))
        ),
        close(Stream)).

too_many_skills_fixture(Root) :-
    tmp_file(skill_count_limit, Root), make_directory(Root),
    rlm_skill:skills_per_root_max(Max), Count is Max+1,
    forall(between(1, Count, N), numbered_skill(Root, N)).

too_many_roots_fixture(Parent, Roots) :-
    tmp_file(skill_root_count_limit, Parent), make_directory(Parent),
    findall(Root,
            ( between(1, 17, N),
              format(atom(Name), 'root-~d', [N]),
              directory_file_path(Parent, Name, Root),
              make_directory(Root)
            ),
            Roots).

too_many_root_entries_fixture(Root) :-
    tmp_file(skill_root_entry_limit, Root), make_directory(Root),
    directory_file_path(Root, '.git', Ignored), make_directory(Ignored),
    write_numbered_empty_files(Root, 4096, bin).

too_many_package_entries_fixture(Root) :-
    single_skill_fixture(Root, _, "BODY\n"),
    directory_file_path(Root, '.git', Ignored), make_directory(Ignored),
    write_numbered_empty_files(Root, 4095, bin).

write_numbered_empty_files(Directory, Count, Extension) :-
    forall(between(1, Count, N),
           ( format(atom(Name), 'entry-~|~`0t~d~5+.~w', [N, Extension]),
             directory_file_path(Directory, Name, File),
             write_text_file(File, "")
           )).

oversized_catalog(Catalog) :-
    rlm_skill:skills_per_catalog_max(Max), Count is Max+1,
    findall(Skill,
            ( between(1, Count, N),
              format(atom(Name), 'skill-~d', [N]),
              Skill = skill{name:Name,fingerprint:Name}
            ),
            Skills),
    Catalog = skill_catalog{roots:[],skills:Skills,fingerprint:test_catalog}.

numbered_skill(Root, N) :-
    format(atom(Name), 'skill-~d', [N]),
    directory_file_path(Root, Name, Dir), make_directory(Dir),
    directory_file_path(Dir, 'SKILL.md', File),
    format(string(Text),
           "---\nname: ~w\ndescription: Count fixture.\n---\nBODY\n", [Name]),
    write_text_file(File, Text).

deep_skill_fixture(Root) :-
    tmp_file(skill_depth_limit, Root), make_directory(Root),
    rlm_skill:skill_descendant_depth_max(Max), Count is Max+1,
    nested_directories(Count, Root, Deep),
    directory_file_path(Deep, 'SKILL.md', File),
    write_text_file(File,
                    "---\nname: bounded\ndescription: Deep fixture.\n---\nBODY\n").

nested_directories(0, Directory, Directory) :- !.
nested_directories(Count, Parent, Directory) :-
    format(atom(Name), 'd~d', [Count]),
    directory_file_path(Parent, Name, Child), make_directory(Child),
    Next is Count-1,
    nested_directories(Next, Child, Directory).

too_many_resources_fixture(Root) :-
    single_skill_fixture(Root, _, "BODY\n"),
    rlm_skill:skill_resources_max(Max), Count is Max+1,
    forall(between(1, Count, N),
           ( format(atom(Name), 'resource-~d.md', [N]),
             directory_file_path(Root, Name, File),
             write_text_file(File, "R\n")
           )).

aggregate_resource_fixture(Root) :-
    single_skill_fixture(Root, _, "BODY\n"),
    rlm_skill:resource_file_max_bytes(FileMax),
    forall(between(1, 9, N),
           ( format(atom(Name), 'large-~d.md', [N]),
             directory_file_path(Root, Name, File),
             write_repeated_byte_file(File, 0'a, FileMax)
           )).

later_metadata_header_fixture(Root) :-
    tmp_file(skill_later_metadata, Root), make_directory(Root),
    directory_file_path(Root, 'SKILL.md', File),
    write_text_file(File,
        "---\nname: bounded\ndescription: Metadata fixture.\nmetadata:\n  other: ignored\n  prolog-rlm: |-\n    {\"schema\":1,\"category\":\"evil\",\"aliases\":[\"evil\"]}\n---\nBODY\n").

out_of_scope_metadata_fixture(Root) :-
    tmp_file(skill_out_of_scope_metadata, Root), make_directory(Root),
    directory_file_path(Root, 'SKILL.md', File),
    write_text_file(File,
        "---\nname: bounded\ndescription: Metadata fixture.\nmetadata:\n  other: ignored\nother-map:\n  prolog-rlm: |-\n    {\"schema\":1,\"category\":\"evil\",\"aliases\":[\"evil\"]}\n---\nBODY\n").

nested_identity_fixture(Root) :-
    tmp_file(skill_nested_identity, Root), make_directory(Root),
    directory_file_path(Root, 'SKILL.md', File),
    write_text_file(File,
        "---\nwrapper:\n  name: nested-name\n  description: Nested description.\n---\nBODY\n").

write_repeated_byte_file(Path, Byte, Count) :-
    setup_call_cleanup(
        open(Path, write, Stream, [type(binary)]),
        forall(between(1, Count, _), put_byte(Stream, Byte)),
        close(Stream)).

write_text_file(Path, Text) :-
    setup_call_cleanup(open(Path, write, Stream, [encoding(utf8)]),
                       format(Stream, '~s', [Text]), close(Stream)).

:- end_tests(rlm_skill).
