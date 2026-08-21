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
    absolute_file_name(PackRoot0,
                       PackRoot,
                       [ file_type(directory),
                         solutions(first),
                         file_errors(fail)
                       ]),
    make_directory_path(PackRoot),
    atom_concat('file://', Source, SourceUrl),
    pack_install(SourceUrl,
                 [ pack_directory(PackRoot),
                   interactive(false),
                   silent(true),
                   test(false),
                   link(false),
                   register(false)
                 ]),
    pack_property(prolog_rlm, directory(Installed)),
    format('installed_pack=~w~n', [Installed]),
    halt(0).
main(Args) :-
    format(user_error,
           'usage: pack_install_smoke.pl SOURCE_DIR PACK_ROOT; got ~q~n',
           [Args]),
    halt(2).
