:- module(rlm_research_approval_test, []).

:- use_module(library(apply)).
:- use_module(library(filesex)).
:- use_module(library(lists)).
:- use_module(library(plunit)).
:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module('../scripts/research_approval_validator').

:- begin_tests(research_approval).

test(canonical_pending_record_is_valid) :-
    with_repository(
        [ record('research/example.org',
                 pending_record('prolog-rlm-research-example'))
        ],
        Errors,
        []),
    assertion(Errors == []).

test(approval_fields_must_follow_status_and_have_canonical_order) :-
    with_repository(
        [ record('research/example.org',
                 "#+title: Example\n#+status: RESEARCHED\n#+approval_state: PENDING\n#+approval_schema: prolog-rlm.research-approval.v1\n#+approval_actor: NONE\n#+approval_evidence: NONE\n#+approval_base_commit: NONE\n#+approval_base_blob: NONE\n#+approval_decided_at: NONE\n")
        ],
        Errors,
        []),
    assertion(has_reason(Errors, 'canonical approval block')),
    assertion(has_line(Errors, "research/example.org", 3)).

test(schema_keyword_and_value_are_canonical) :-
    with_repository(
        [ record('research/example.org',
                 "#+title: Example\n#+status: RESEARCHED\n#+approval_schema: other.schema\n#+approval_state: PENDING\n#+approval_actor: NONE\n#+approval_evidence: NONE\n#+approval_base_commit: NONE\n#+approval_base_blob: NONE\n#+approval_decided_at: NONE\n")
        ],
        Errors,
        []),
    assertion(has_reason(Errors, 'approval_schema')),
    assertion(has_reason(Errors, 'noncanonical approval keyword')).

test(duplicate_canonical_fields_are_rejected) :-
    with_repository(
        [ record('research/example.org',
                 "#+title: Example\n#+status: RESEARCHED\n#+approval_schema: prolog-rlm.research-approval.v1\n#+approval_state: PENDING\n#+approval_actor: NONE\n#+approval_evidence: NONE\n#+approval_base_commit: NONE\n#+approval_base_blob: NONE\n#+approval_decided_at: NONE\n#+approval_state: PENDING\n")
        ],
        Errors,
        []),
    assertion(has_reason(Errors, 'approval field #+approval_state must occur exactly once')).

test(legacy_keywords_and_checked_approval_boxes_are_rejected) :-
    with_repository(
        [ record('research/example.org',
                 "#+title: Example\n#+status: DONE\n#+approval: APPROVED\n#+approval_schema: prolog-rlm.research-approval.v1\n#+approval_state: PENDING\n#+approval_actor: NONE\n#+approval_evidence: NONE\n#+approval_base_commit: NONE\n#+approval_base_blob: NONE\n#+approval_decided_at: NONE\n- [X] APPROVE\n")
        ],
        Errors,
        []),
    assertion(has_reason(Errors, 'noncanonical approval keyword')),
    assertion(has_reason(Errors, 'checked approval box')).

test(pending_record_must_use_none_for_all_other_fields) :-
    with_repository(
        [ record('research/example.org',
                 "#+title: Example\n#+status: RESEARCHED\n#+approval_schema: prolog-rlm.research-approval.v1\n#+approval_state: PENDING\n#+approval_actor: Alice\n#+approval_evidence: github:issue/1\n#+approval_base_commit: NONE\n#+approval_base_blob: NONE\n#+approval_decided_at: NONE\n")
        ],
        Errors,
        []),
    assertion(has_reason(Errors, 'PENDING approval_actor must be NONE')),
    assertion(has_reason(Errors, 'PENDING approval_evidence must be NONE')).

test(decided_record_requires_human_evidence_and_valid_rfc3339) :-
    with_repository(
        [ record('research/example.org',
                 "#+title: Example\n#+status: VERIFIED\n#+approval_schema: prolog-rlm.research-approval.v1\n#+approval_state: APPROVED\n#+approval_actor: NONE\n#+approval_evidence: NONE\n#+approval_base_commit: not-a-commit\n#+approval_base_blob: not-a-blob\n#+approval_decided_at: 2026-99-99 12:00\n")
        ],
        Errors,
        []),
    assertion(has_reason(Errors, 'decided approval_actor must identify a human')),
    assertion(has_reason(Errors, 'decided approval_evidence must identify durable evidence')),
    assertion(has_reason(Errors, 'approval_base_commit must be a 40-character object ID')),
    assertion(has_reason(Errors, 'approval_base_blob must be a 40-character object ID')),
    assertion(has_reason(Errors, 'approval_decided_at must be RFC 3339')).

test(lifecycle_status_does_not_approve_pending_record) :-
    with_repository(
        [ record('research/example.org',
                 pending_record('prolog-rlm-research-example'))
        ],
        Errors,
        []),
    assertion(Errors == []).

test(lifecycle_status_cannot_be_used_as_approval_state) :-
    with_repository(
        [ record('research/example.org',
                 "#+title: Example\n#+status: APPROVED\n#+approval_schema: prolog-rlm.research-approval.v1\n#+approval_state: PENDING\n#+approval_actor: NONE\n#+approval_evidence: NONE\n#+approval_base_commit: NONE\n#+approval_base_blob: NONE\n#+approval_decided_at: NONE\n")
        ],
        Errors,
        []),
    assertion(has_reason(Errors, 'lifecycle status cannot be APPROVED or REJECTED')).

test(decided_record_must_bind_commit_to_exact_file_blob) :-
    setup_decided_repository(Root, _ApprovedContent, _BaseCommit, _BaseBlob),
    research_approval_errors(Root, Errors),
    cleanup_repository(Root),
    assertion(Errors == []).

test(decided_record_rejects_blob_mismatch) :-
    setup_decided_repository(Root, ApprovedContent, _BaseCommit, _BaseBlob),
    replace_text(ApprovedContent, '#+approval_base_blob: ',
                 '#+approval_base_blob: 0000000000000000000000000000000000000000',
                 Mismatched),
    write_record(Root, 'research/example.org', Mismatched),
    research_approval_errors(Root, Errors),
    cleanup_repository(Root),
    assertion(has_reason(Errors, 'does not resolve to approval_base_blob')).

test(duplicate_research_ids_are_reported_with_locations) :-
    with_repository(
        [ record('research/RLM-RESEARCH-010-one.org',
                 pending_record('id-one')),
          record('research/RLM-RESEARCH-010-two.org',
                 pending_record('id-two'))
        ],
        Errors,
        []),
    assertion(has_reason(Errors, 'duplicate research ID RLM-RESEARCH-010')),
    assertion(has_line(Errors, "research/RLM-RESEARCH-010-one.org", 1)),
    assertion(has_line(Errors, "research/RLM-RESEARCH-010-two.org", 1)).

test(repository_validator_enumerates_tracked_research_files) :-
    with_repository(
        [ record('research/example.org',
                 pending_record('prolog-rlm-research-example')),
          untracked('research/untracked.org',
                    pending_record('untracked-id'))
        ],
        Errors,
        []),
    assertion(Errors == []).

:- end_tests(research_approval).

pending_record(Id, Content) :-
    format(string(Content),
           ":PROPERTIES:\n:ID:       ~w\n:END:\n#+title: Example\n#+status: RESEARCHED\n#+approval_schema: prolog-rlm.research-approval.v1\n#+approval_state: PENDING\n#+approval_actor: NONE\n#+approval_evidence: NONE\n#+approval_base_commit: NONE\n#+approval_base_blob: NONE\n#+approval_decided_at: NONE\n",
           [Id]).

setup_decided_repository(Root, Content, Commit, Blob) :-
    pending_record('prolog-rlm-research-example', Pending),
    setup_repository(Root),
    write_record(Root, 'research/example.org', Pending),
    git(Root, ['add', '--', 'research/example.org']),
    git(Root, ['commit', '-q', '-m', 'fixture']),
    git_output(Root, ['rev-parse', 'HEAD'], Commit),
    git_output(Root, ['rev-parse', 'HEAD:research/example.org'], Blob),
    format(string(Content),
           ":PROPERTIES:\n:ID:       prolog-rlm-research-example\n:END:\n#+title: Example\n#+status: RESEARCHED\n#+approval_schema: prolog-rlm.research-approval.v1\n#+approval_state: APPROVED\n#+approval_actor: Alice Example\n#+approval_evidence: github:issue/1/comment/2\n#+approval_base_commit: ~w\n#+approval_base_blob: ~w\n#+approval_decided_at: 2026-08-27T12:00:00Z\n",
           [Commit, Blob]),
    write_record(Root, 'research/example.org', Content).

with_repository(Records, Errors, _) :-
    setup_repository(Root),
    maplist(write_record_spec(Root), Records),
    record_paths(Records, Paths),
    git(Root, ['add', '--'|Paths]),
    git(Root, ['commit', '-q', '-m', 'fixture']),
    research_approval_errors(Root, Errors),
    cleanup_repository(Root).

record_paths(Records, Paths) :-
    findall(Path, member(record(Path, _), Records), Paths).

write_record_spec(Root, record(Path, pending_record(Id))) :-
    !,
    pending_record(Id, Content),
    write_record(Root, Path, Content).
write_record_spec(Root, record(Path, Content)) :-
    write_record(Root, Path, Content).
write_record_spec(Root, untracked(Path, Content)) :-
    write_record(Root, Path, Content).

setup_repository(Root) :-
    tmp_file_stream(text, Root, Stream),
    close(Stream),
    delete_file(Root),
    make_directory(Root),
    directory_file_path(Root, 'research', ResearchDirectory),
    make_directory_path(ResearchDirectory),
    git(Root, ['init', '-q', '-b', 'topic']),
    git(Root, ['config', 'user.name', 'Research Test']),
    git(Root, ['config', 'user.email', 'test@example.invalid']).

write_record(Root, Relative, Content) :-
    directory_file_path(Root, Relative, File),
    file_directory_name(File, Directory),
    make_directory_path(Directory),
    setup_call_cleanup(
        open(File, write, Stream, [encoding(utf8)]),
        write(Stream, Content),
        close(Stream)).

cleanup_repository(Root) :-
    delete_directory_and_contents(Root).

git(Root, Arguments) :-
    process_create(path(git), Arguments,
                   [ cwd(Root), stdin(null), stdout(null), stderr(null),
                     process(PID) ]),
    process_wait(PID, exit(0)).

git_output(Root, Arguments, Output) :-
    process_create(path(git), Arguments,
                   [ cwd(Root), stdin(null), stdout(pipe(Stream)),
                     stderr(null), process(PID) ]),
    read_string(Stream, _, Output0),
    close(Stream),
    process_wait(PID, exit(0)),
    normalize_space(string(Output), Output0).

replace_text(Content, Prefix, Replacement, Result) :-
    split_string(Content, "\n", "", Lines),
    maplist(replace_line(Prefix, Replacement), Lines, Updated),
    atomics_to_string(Updated, "\n", Result).

replace_line(Prefix, Replacement, Line, Replacement) :-
    sub_string(Line, 0, _, _, Prefix),
    !.
replace_line(_, _, Line, Line).

has_reason(Errors, Fragment) :-
    member(error(_, _, Reason), Errors),
    sub_string(Reason, _, _, _, Fragment),
    !.

has_line(Errors, File, Line) :-
    member(error(File, Line, _), Errors),
    !.
