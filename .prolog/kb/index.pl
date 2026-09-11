/* Durable project knowledge loader. Consult this file to load the KB. */
:- dynamic kb_loaded_file/1.

kb_file(File) :-
    prolog_load_context(directory, Dir),
    atomic_list_concat([Dir, '/', File], Path),
    (   kb_loaded_file(Path)
    ->  true
    ;   assertz(kb_loaded_file(File)),
        consult(Path)
    ).

:- initialization(( kb_file('tree-sitter-ffi.pl'),
                    kb_file('project-knowledge-pipeline.pl'),
                    kb_file('debugging-recipes.pl'),
                    true ), now).