:- begin_tests(rlm_literate_org).

:- use_module('../prolog/rlm_literate_org').
:- use_module(library(filesex)).

test(render_preserves_block_order_for_one_target) :-
    Source = "#+title: demo\n#+begin_src prolog :tangle prolog/demo.pl\na(1).\n#+end_src\nText.\n#+begin_src prolog :tangle prolog/demo.pl\nb(2).\n#+end_src\n",
    org_tangle_render(Source, ok([Output])),
    assertion(Output.target == "prolog/demo.pl"),
    assertion(Output.blocks == 2),
    assertion(Output.content == "a(1).\nb(2).\n").

test(documentation_only_block_does_not_tangle) :-
    Source = "#+begin_src prolog\nexample_only.\n#+end_src\n",
    org_tangle_render(Source, ok([])).

test(tangle_no_does_not_tangle) :-
    Source = "#+begin_src prolog :tangle no\nexample_only.\n#+end_src\n",
    org_tangle_render(Source, ok([])).

test(rejects_parent_directory_escape) :-
    Source = "#+begin_src prolog :tangle ../escape.pl\nbad.\n#+end_src\n",
    org_tangle_render(Source, error(Error)),
    assertion(Error.phase == render),
    assertion(Error.detail == unsafe_tangle_target("../escape.pl")).

test(rejects_unterminated_block) :-
    Source = "#+begin_src prolog :tangle prolog/demo.pl\na(1).\n",
    org_tangle_render(Source, error(Error)),
    assertion(Error.phase == parse),
    assertion(Error.detail == unterminated_src_block(1)).

test(tangle_and_check_round_trip) :-
    Source = "#+begin_src prolog :tangle generated/demo.pl\ndemo(ok).\n#+end_src\n",
    tmp_file(rlm_literate_org, Root),
    make_directory(Root),
    directory_file_path(Root, 'source.org', OrgPath),
    setup_call_cleanup(
        true,
        ( setup_call_cleanup(open(OrgPath, write, Stream, [encoding(utf8)]),
                             format(Stream, '~s', [Source]),
                             close(Stream)),
          org_tangle_file(OrgPath, Root, ok(_)),
          org_tangle_check(OrgPath, Root, ok(Check)),
          assertion(Check.status == current)
        ),
        delete_directory_and_contents(Root)
    ).

:- end_tests(rlm_literate_org).
