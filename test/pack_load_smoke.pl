:- initialization(main, main).

:- use_module(library(prolog_pack)).

main([PackRoot]) :-
    !,
    attach_packs(PackRoot, [replace(true)]),
    use_module(library(rlm)),
    rlm:rlm_ready,
    rlm:rlm_version(Version),
    rlm:skill_default_catalog_reset,
    rlm:skill_default_catalog(ok(SkillCatalog)),
    rlm:skill_catalog_skills(SkillCatalog, Skills),
    findall(Name, (member(Skill, Skills), Name = Skill.name), Names0),
    sort(Names0, ['rlm-constraints','rlm-facts','rlm-operate','rlm-recurse']),
    format('installed_rlm_version=~w~n', [Version]),
    halt(0).
main(Args) :-
    format(user_error,
           'usage: pack_load_smoke.pl PACK_ROOT; got ~q~n',
           [Args]),
    halt(2).
