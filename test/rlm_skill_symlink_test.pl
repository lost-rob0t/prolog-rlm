:- begin_tests(rlm_skill_symlink_confinement).

:- use_module('../prolog/rlm_skill').
:- use_module(library(filesex)).


test(catalog_rejects_symlinked_skill_directory) :-
    setup_call_cleanup(
        symlink_catalog_fixture(Root, Outside, Link),
        ( rlm_skill:skill_catalog_load(Root, [], Outcome),
          assertion(Outcome = error(_))
        ),
        cleanup_symlink_fixture(Root, Outside, Link)).


test(resource_read_rejects_symlinked_subdirectory) :-
    setup_call_cleanup(
        symlink_resource_fixture(Catalog, Root, Outside, Link),
        ( rlm_skill:skill_catalog_skill(Catalog, selected, Skill),
          rlm_skill:skill_read_resource(Skill, 'escape/secret.md', Outcome),
          assertion(Outcome = error(_))
        ),
        cleanup_symlink_fixture(Root, Outside, Link)).


symlink_catalog_fixture(Root, Outside, Link) :-
    fresh_directory(skill_catalog_root, Root),
    fresh_directory(skill_catalog_outside, Outside),
    directory_file_path(Outside, 'SKILL.md', SkillFile),
    setup_call_cleanup(
        open(SkillFile, write, Stream, [encoding(utf8)]),
        format(Stream,
               '---~nname: escaped-skill~ndescription: outside skill~n---~noutside~n',
               []),
        close(Stream)),
    directory_file_path(Root, escaped, Link),
    link_file(Outside, Link, symbolic).


symlink_resource_fixture(Catalog, Root, Outside, Link) :-
    fresh_directory(skill_resource_root, Root),
    directory_file_path(Root, selected, SkillDir),
    make_directory(SkillDir),
    directory_file_path(SkillDir, 'SKILL.md', SkillFile),
    write_file(SkillFile,
               '---~nname: selected~ndescription: selected skill~n---~nbody~n'),
    directory_file_path(SkillDir, escape, AdmittedDir),
    make_directory(AdmittedDir),
    directory_file_path(AdmittedDir, 'secret.md', AdmittedSecret),
    write_file(AdmittedSecret, 'admitted secret~n'),
    rlm_skill:skill_catalog_load(Root, [], ok(Catalog)),
    delete_directory_and_contents(AdmittedDir),
    fresh_directory(skill_resource_outside, Outside),
    directory_file_path(Outside, 'secret.md', Secret),
    setup_call_cleanup(
        open(Secret, write, Stream, [encoding(utf8)]),
        format(Stream, 'outside secret~n', []),
        close(Stream)),
    directory_file_path(SkillDir, escape, Link),
    link_file(Outside, Link, symbolic).


write_file(Path, Format) :-
    setup_call_cleanup(
        open(Path, write, Stream, [encoding(utf8)]),
        format(Stream, Format, []),
        close(Stream)).


fresh_directory(Prefix, Directory) :-
    tmp_file(Prefix, Directory),
    make_directory(Directory).


cleanup_symlink_fixture(Root, Outside, Link) :-
    catch(delete_file(Link), _, true),
    catch(delete_directory_and_contents(Root), _, true),
    catch(delete_directory_and_contents(Outside), _, true).


:- end_tests(rlm_skill_symlink_confinement).
