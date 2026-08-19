:- module(skill_test_support,
          [ fixture_open/2,
            fixture_close/1,
            capture_skill_planner/3,
            capture_no_skill_planner/2
          ]).

:- use_module(library(filesex)).
:- use_module('../../prolog/rlm_skill').

fixture_open(Root, Catalog) :-
    tmp_file_stream(text, Root, Stream),
    close(Stream),
    delete_file(Root),
    make_directory(Root),
    write_skill(Root,
                'code-review',
                "---\nname: code-review\ndescription: Review a code diff or pull request.\nkeywords: [review, diff]\npriority: 20\n---\n\nREVIEW_BODY_SENTINEL\nReview the change against the stated requirements.\n"),
    write_resource(Root,
                   'code-review',
                   'guide.md',
                   "RESOURCE_SENTINEL\n"),
    write_skill(Root,
                implement,
                "---\nname: implement\ndescription: Implement a requested change from a spec.\ndisable-model-invocation: true\n---\n\nIMPLEMENT_BODY_SENTINEL\nImplement the requested work.\n"),
    write_skill(Root,
                tdd,
                "---\nname: tdd\ndescription: Write tests first for behavior changes.\nkeywords: [tests, tdd]\n---\n\nTDD_BODY_SENTINEL\nStart with a failing behavioral test.\n"),
    write_skill(Root,
                diagnose,
                "---\nname: diagnose\ndescription: Diagnose a reproducible software bug.\nphrases: [diagnose bug]\nrequires: [tdd]\n---\n\nDIAGNOSE_BODY_SENTINEL\nTrace the bug to its first incorrect state.\n"),
    skill_catalog_load(Root, [], ok(Catalog)).

fixture_close(Root) :-
    ( exists_directory(Root) -> delete_directory_and_contents(Root) ; true ).

write_skill(Root, Name, Content) :-
    directory_file_path(Root, Name, Directory),
    make_directory_path(Directory),
    directory_file_path(Directory, 'SKILL.md', Path),
    write_text(Path, Content).

write_resource(Root, Name, Relative, Content) :-
    directory_file_path(Root, Name, Directory),
    directory_file_path(Directory, Relative, Path),
    write_text(Path, Content).

write_text(Path, Content) :-
    setup_call_cleanup(
        open(Path, write, Stream, [encoding(utf8)]),
        format(Stream, '~s', [Content]),
        close(Stream)).

capture_skill_planner(Sentinel, Request, ok(Output)) :-
    Request.messages = [Message|_],
    Prompt = Message.content,
    sub_string(Prompt, _, _, _, Sentinel),
    Plan = plan([final(literal("skill-ok"))]),
    Output = planner_output{plan:Plan,
                            usage:_{prompt_tokens:1,
                                    completion_tokens:1,
                                    total_tokens:2,
                                    cost:0.0}}.

capture_no_skill_planner(Request, ok(Output)) :-
    Request.messages = [Message|_],
    Prompt = Message.content,
    \+ sub_string(Prompt, _, _, _, "BODY_SENTINEL"),
    Plan = plan([final(literal("no-skill-ok"))]),
    Output = planner_output{plan:Plan,
                            usage:_{prompt_tokens:1,
                                    completion_tokens:1,
                                    total_tokens:2,
                                    cost:0.0}}.
