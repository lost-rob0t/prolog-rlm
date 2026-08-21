:- initialization(main, main).

:- use_module(library(filesex)).
:- use_module(library(prolog_pack)).

main([Source0, PackRoot0]) :-
    !,
    absolute_file_name(Source0,
                       Source,
                       [ file_type(directory),
                         access(read)
                       ]),
    make_directory_path(PackRoot0),
    absolute_file_name(PackRoot0,
                       PackRoot,
                       [ file_type(directory),
                         access(write)
                       ]),
    atom_concat('file://', Source, SourceUrl),
    pack_directory_option(PackRoot, DirectoryOption),
    pack_install(SourceUrl,
                 [ DirectoryOption,
                   interactive(false),
                   silent(true),
                   test(false),
                   link(false),
                   register(false)
                 ]),
    attach_packs(PackRoot, [replace(true)]),
    pack_property(prolog_rlm, directory(Installed)),
    directory_file_path(PackRoot, prolog_rlm, Expected),
    same_file(Installed, Expected),
    format('installed_pack=~w~n', [Installed]),
    halt(0).
main(Args) :-
    format(user_error,
           'usage: pack_install_smoke.pl SOURCE_DIR PACK_ROOT; got ~q~n',
           [Args]),
    halt(2).

pack_directory_option(PackRoot, Option) :-
    current_prolog_flag(version_data, swi(Major, Minor, _, _)),
    (   Major > 9
    ;   Major =:= 9,
        Minor >= 1
    ),
    !,
    Option = pack_directory(PackRoot).
pack_directory_option(PackRoot, package_directory(PackRoot)).
