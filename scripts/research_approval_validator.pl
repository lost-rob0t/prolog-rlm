:- module(research_approval_validator,
          [ canonical_approval_fields/1,
            research_approval_errors/2,
            tracked_research_files/2,
            validate_repository/1
          ]).

:- use_module(library(apply), [maplist/3]).
:- use_module(library(lists), [append/2, member/2]).
:- use_module(library(pcre), [re_match/3, re_matchsub/4]).
:- use_module(library(process), [process_create/3, process_wait/2]).
:- use_module(library(readutil), [read_file_to_string/3]).
:- use_module(library(filesex), [directory_file_path/3]).

canonical_approval_fields(
    [ field(approval_schema, "prolog-rlm.research-approval.v1"),
      field(approval_state, _),
      field(approval_actor, _),
      field(approval_evidence, _),
      field(approval_base_commit, _),
      field(approval_base_blob, _),
      field(approval_decided_at, _)
    ]).

approval_field(approval_schema, "prolog-rlm.research-approval.v1").
approval_field(approval_state, _).
approval_field(approval_actor, _).
approval_field(approval_evidence, _).
approval_field(approval_base_commit, _).
approval_field(approval_base_blob, _).
approval_field(approval_decided_at, _).

research_approval_errors(Root, Errors) :-
    (   tracked_research_files(Root, Files)
    ->  maplist(validate_research_file(Root), Files, Results),
        results_errors(Results, FileErrors, IdEntries),
        duplicate_id_errors(IdEntries, DuplicateErrors),
        append([FileErrors, DuplicateErrors], Unsorted),
        sort(Unsorted, Errors)
    ;   Errors = [error("", 1,
                       "cannot enumerate tracked research/*.org files")]
    ),
    !.

tracked_research_files(Root, Files) :-
    run_git(Root, ['ls-files', '-z', '--', 'research/*.org'], 0, Output),
    split_string(Output, "\0", "", RawFiles),
    exclude_empty(RawFiles, Nonempty),
    sort(Nonempty, Files),
    !.

validate_repository(Root) :-
    research_approval_errors(Root, Errors),
    (   Errors == []
    ->  tracked_research_files(Root, Files),
        length(Files, Count),
        format("research approval validation: PASS (~d tracked files)~n",
               [Count])
    ;   forall(member(error(File, Line, Reason), Errors),
               format(user_error, "~s:~d: ERROR: ~s~n",
                      [File, Line, Reason])),
        fail
    ).

validate_research_file(Root, Path, result(Errors, IdEntries)) :-
    directory_file_path(Root, Path, File),
    (   read_file_to_string(File, Content, [encoding(utf8)])
    ->  split_string(Content, "\n", "", Lines),
        numbered_lines(Lines, 1, Numbered),
        structural_errors(Path, Numbered, StructuralErrors),
        approval_errors(Root, Path, Numbered, ApprovalErrors),
        id_entries(Path, Numbered, IdEntries),
        append([StructuralErrors, ApprovalErrors], Errors)
    ;   Errors = [error(Path, 1, "cannot read research record")],
        IdEntries = []
    ),
    !.

structural_errors(Path, Lines, Errors) :-
    findall(Line, keyword_occurrence(Lines, "title", Line), Titles),
    findall(Line, keyword_occurrence(Lines, "status", Line), Statuses),
    cardinality_error(Path, Titles, "#+title", TitleErrors),
    cardinality_error(Path, Statuses, "#+status", StatusErrors),
    header_order_errors(Path, Titles, Statuses, OrderErrors),
    lifecycle_status_errors(Path, Lines, LifecycleErrors),
    noncanonical_layout_errors(Path, Lines, LayoutErrors),
    checked_box_errors(Path, Lines, BoxErrors),
    append([TitleErrors, StatusErrors, OrderErrors, LifecycleErrors,
            LayoutErrors, BoxErrors], Errors).

cardinality_error(_, Values, _, []) :-
    length(Values, 1),
    !.
cardinality_error(Path, Values, Keyword, [error(Path, Line, Reason)]) :-
    first_or_default(Values, 1, Line),
    length(Values, Count),
    format(string(Reason),
           "expected exactly one ~s keyword, found ~d",
           [Keyword, Count]).

header_order_errors(_, [Title], [Status], []) :-
    Title < Status,
    !.
header_order_errors(Path, Titles, Statuses,
                    [error(Path, Line,
                           "#+title must precede lifecycle #+status")]) :-
    append(Titles, Statuses, Positions),
    first_or_default(Positions, 1, Line).

lifecycle_status_errors(_, Lines, []) :-
    keyword_value_at(Lines, "status", _, _),
    keyword_value_at(Lines, "status", Value, _),
    string_upper(Value, Upper),
    \+ member(Upper, ["APPROVED", "REJECTED"]),
    !.
lifecycle_status_errors(Path, Lines,
                        [error(Path, Line,
                               "lifecycle status cannot be APPROVED or REJECTED; use #+approval_state")]) :-
    keyword_value_at(Lines, "status", _, Line).

noncanonical_layout_errors(Path, Lines, Errors) :-
    findall(error(Path, Line, Reason),
            noncanonical_approval_line(Lines, Line, Reason),
            Errors).

noncanonical_approval_line(Lines, Line, Reason) :-
    member(line(Line, Text), Lines),
    keyword_line(Text, Name, Value),
    (   approval_keyword_name(Name),
        \+ canonical_line(Text, _, _)
    ->  format(string(Reason),
               "noncanonical approval keyword #+~s",
               [Name])
    ;   string_lower(Name, "property"),
        string_lower(Value, LowerValue),
        sub_string(LowerValue, _, _, _, "approval")
    ->  Reason = "noncanonical approval property"
    ;   property_approval_line(Text)
    ->  Reason = "noncanonical approval property"
    ).

checked_box_errors(Path, Lines, Errors) :-
    findall(error(Path, Line, "checked approval box is not authoritative; use #+approval_state"),
            ( member(line(Line, Text), Lines),
              re_match("(?i)^[ \\t]*(?:[-+*][ \\t]+)?\\[[xX]\\][ \\t]+(?:APPROVE[D]?|REJECT[ED]?)(?:[ \\t]|$)",
                       Text, [])
            ),
            Errors).

approval_errors(Root, Path, Lines, Errors) :-
    findall(Line, keyword_occurrence(Lines, "status", Line), Statuses),
    (   Statuses = [StatusLine]
    ->  canonical_block_errors(Path, StatusLine, Lines, BlockErrors),
        state_dependent_errors(Root, Path, Lines, StateErrors),
        append(BlockErrors, StateErrors, Errors)
    ;   Errors = []
    ).

canonical_block_errors(Path, StatusLine, Lines, Errors) :-
    canonical_approval_fields(Fields),
    expected_block_errors(Path, StatusLine, Lines, Fields, 1, ExpectedErrors),
    field_occurrence_errors(Path, Lines, Fields, OccurrenceErrors),
    append(ExpectedErrors, OccurrenceErrors, Errors).

expected_block_errors(_, _, _, [], _, []).
expected_block_errors(Path, StatusLine, Lines,
                      [field(Name, _)|Fields], Offset, Errors) :-
    ExpectedLine is StatusLine + Offset,
    (   line_text(Lines, ExpectedLine, Actual),
        canonical_line(Actual, Name, _)
    ->  Head = []
    ;   format(string(Reason),
               "canonical approval block expected #+~s immediately after #+status",
               [Name]),
        Head = [error(Path, ExpectedLine, Reason)]
    ),
    NextOffset is Offset + 1,
    expected_block_errors(Path, StatusLine, Lines, Fields, NextOffset, Tail),
    append(Head, Tail, Errors).

field_occurrence_errors(_, _, [], []).
field_occurrence_errors(Path, Lines, [field(Name, _)|Fields], Errors) :-
    findall(Line, canonical_field_occurrence(Lines, Name, Line), Occurrences),
    (   Occurrences = [_]
    ->  Head = []
    ;   first_or_default(Occurrences, 1, Line),
        length(Occurrences, Count),
        format(string(Reason),
               "approval field #+~s must occur exactly once, found ~d",
               [Name, Count]),
        Head = [error(Path, Line, Reason)]
    ),
    field_occurrence_errors(Path, Lines, Fields, Tail),
    append(Head, Tail, Errors).

state_dependent_errors(Root, Path, Lines, Errors) :-
    (   canonical_field_value(Lines, approval_state, State, StateLine)
    ->  string_upper(State, UpperState),
        state_errors(Root, Path, Lines, UpperState, StateLine, Errors)
    ;   Errors = []
    ).

state_errors(_, Path, _, State, Line,
             [error(Path, Line,
                    "approval_state must be exactly PENDING, APPROVED, or REJECTED")]) :-
    \+ member(State, ["PENDING", "APPROVED", "REJECTED"]),
    !.
state_errors(_, Path, Lines, "PENDING", _, Errors) :-
    pending_field_errors(Path, Lines, Errors).
state_errors(Root, Path, Lines, State, _, Errors) :-
    member(State, ["APPROVED", "REJECTED"]),
    decided_field_errors(Root, Path, Lines, Errors).

pending_field_errors(Path, Lines, Errors) :-
    findall(error(Path, Line, Reason),
            pending_non_none(Lines, _Name, Line, Reason),
            Errors).

pending_non_none(Lines, Name, Line, Reason) :-
    member(Name, [approval_actor, approval_evidence, approval_base_commit,
                  approval_base_blob, approval_decided_at]),
    canonical_field_value(Lines, Name, Value, Line),
    Value \= "NONE",
    format(string(Reason),
           "PENDING ~s must be NONE",
           [Name]).

decided_field_errors(Root, Path, Lines, Errors) :-
    decided_required_value(Path, Lines, approval_actor, ActorErrors),
    decided_required_value(Path, Lines, approval_evidence, EvidenceErrors),
    decided_id_errors(Root, Path, Lines, CommitErrors),
    decided_timestamp_errors(Path, Lines, TimestampErrors),
    append([ActorErrors, EvidenceErrors, CommitErrors, TimestampErrors], Errors).

decided_required_value(Path, Lines, Name, Errors) :-
    (   canonical_field_value(Lines, Name, Value, Line)
    ->  (   Value \= "", Value \= "NONE"
        ->  Errors = []
        ;   decided_required_reason(Name, Reason),
            Errors = [error(Path, Line, Reason)]
        )
    ;   first_field_line(Lines, Name, Line),
        decided_required_reason(Name, Reason),
        Errors = [error(Path, Line, Reason)]
    ).

decided_required_reason(approval_actor,
                        "decided approval_actor must identify a human decision-maker and cannot be NONE").
decided_required_reason(approval_evidence,
                        "decided approval_evidence must identify durable evidence and cannot be NONE").

decided_id_errors(Root, Path, Lines, Errors) :-
    decided_id_error(Root, Path, Lines, approval_base_commit,
                     "approval_base_commit", CommitErrors),
    decided_id_error(Root, Path, Lines, approval_base_blob,
                     "approval_base_blob", BlobErrors),
    append(CommitErrors, BlobErrors, Errors).

decided_id_error(Root, Path, Lines, Name, Label, Errors) :-
    (   first_field_value(Lines, Name, Value, Line)
    ->  (   valid_object_id(Value)
        ->  binding_errors(Root, Path, Lines, Name, Value, Errors)
        ;   format(string(Reason),
                   "~s must be a 40-character object ID",
                   [Label]),
            Errors = [error(Path, Line, Reason)]
        )
    ;   first_field_line(Lines, Name, Line),
        format(string(Reason),
               "~s must be a 40-character object ID",
               [Label]),
        Errors = [error(Path, Line, Reason)]
    ).

binding_errors(Root, Path, Lines, approval_base_commit, Commit, Errors) :-
    first_field_value(Lines, approval_base_commit, _, CommitLine),
    format(string(CommitSpec), "~s^{commit}", [Commit]),
    (   run_git(Root, ['cat-file', '-e', CommitSpec], 0, _)
    ->  Errors = []
    ;   Errors = [error(Path, CommitLine,
                        "approval_base_commit does not resolve to a commit")]
    ).
binding_errors(Root, Path, Lines, approval_base_blob, Blob, Errors) :-
    first_field_value(Lines, approval_base_commit, Commit, _CommitLine),
    first_field_value(Lines, approval_base_blob, _, BlobLine),
    format(string(ObjectSpec), "~s:~s", [Commit, Path]),
    (   run_git(Root, ['cat-file', '-t', ObjectSpec], 0, "blob"),
        run_git(Root, ['rev-parse', '--verify', ObjectSpec], 0, Resolved),
        same_object_id(Resolved, Blob)
    ->  Errors = []
    ;   Errors = [error(Path, BlobLine,
                        "BASE_COMMIT:path does not resolve to approval_base_blob")]
    ).

decided_timestamp_errors(Path, Lines, Errors) :-
    (   first_field_value(Lines, approval_decided_at, Value, Line)
    ->  (   valid_rfc3339(Value)
        ->  Errors = []
        ;   Errors = [error(Path, Line,
                            "approval_decided_at must be RFC 3339")]
        )
    ;   Errors = [error(Path, 1,
                        "approval_decided_at must be RFC 3339")]
    ).

valid_object_id(Value) :-
    re_match("^[0-9a-fA-F]{40}$", Value, []).

same_object_id(Left, Right) :-
    string_lower(Left, LeftLower),
    string_lower(Right, RightLower),
    LeftLower = RightLower.

valid_rfc3339(Value) :-
    re_match("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$",
             Value, []),
    catch(parse_time(Value, iso_8601, _), _, fail).

id_entries(Path, Lines, Entries) :-
    filename_id_entries(Path, FilenameEntries),
    findall(id(Path, Line, Id),
            ( member(line(Line, Text), Lines), research_id_line(Text, Id) ),
            PropertyEntries),
    append(FilenameEntries, PropertyEntries, Entries).

filename_id_entries(Path, [id(Path, 1, Id)]) :-
    re_matchsub("^research/(?<id>RLM-RESEARCH-[0-9]+)-[^/]+\\.org$",
                Path, Match, []),
    get_dict(id, Match, Id),
    !.
filename_id_entries(_, []).

research_id_line(Text, Id) :-
    re_matchsub("(?i)^[ \\t]*:ID:[ \\t]+(?<id>[^ \\t]+)[ \\t]*$",
                Text, Match, []),
    get_dict(id, Match, Id).

duplicate_id_errors(Entries, Errors) :-
    findall(Id, member(id(_, _, Id), Entries), RawIds),
    sort(RawIds, Ids),
    duplicate_id_errors(Ids, Entries, Errors).

duplicate_id_errors([], _, []).
duplicate_id_errors([Id|Ids], Entries, Errors) :-
    findall(id(Path, Line, Id), member(id(Path, Line, Id), Entries), Occurrences),
    (   Occurrences = [_]
    ->  Head = []
    ;   maplist(duplicate_id_error(Id), Occurrences, Head)
    ),
    duplicate_id_errors(Ids, Entries, Tail),
    append(Head, Tail, Errors).

duplicate_id_error(Id, id(Path, Line, Id),
                   error(Path, Line, Reason)) :-
    format(string(Reason),
           "duplicate research ID ~s in current checkout",
           [Id]).

keyword_occurrence(Lines, Keyword, Line) :-
    keyword_value_at(Lines, Keyword, _, Line).

keyword_value_at(Lines, Keyword, Value, Line) :-
    member(line(Line, Text), Lines),
    keyword_line(Text, Keyword, Value).

keyword_line(Text, Name, Value) :-
    re_matchsub("(?i)^#\\+(?<name>[a-z][a-z0-9_-]*):[ \\t]*(?<value>.*)$",
                Text, Match, []),
    get_dict(name, Match, Name0),
    get_dict(value, Match, Value0),
    string_lower(Name0, Name),
    normalize_space(string(Value), Value0).

canonical_line(Text, Name, Value) :-
    approval_field(Name, ExpectedValue),
    atom_string(Name, NameString),
    format(string(Prefix), "#+~s: ", [NameString]),
    string_concat(Prefix, Value, Text),
    string(Value),
    (   nonvar(ExpectedValue)
    ->  Value = ExpectedValue
    ;   true
    ).

canonical_field_occurrence(Lines, Name, Line) :-
    member(line(Line, Text), Lines),
    canonical_line(Text, Name, _).

canonical_field_value(Lines, Name, Value, Line) :-
    member(line(Line, Text), Lines),
    canonical_line(Text, Name, Value).

first_field_value(Lines, Name, Value, Line) :-
    canonical_field_value(Lines, Name, Value, Line),
    !.

first_field_line(Lines, Name, Line) :-
    (   canonical_field_value(Lines, Name, _, Line)
    ->  true
    ;   Line = 1
    ).

approval_keyword_name(Name) :-
    sub_string(Name, _, _, _, "approval").
approval_keyword_name(Name) :-
    sub_string(Name, _, _, _, "approved").
approval_keyword_name(Name) :-
    sub_string(Name, _, _, _, "approve").
approval_keyword_name(Name) :-
    sub_string(Name, _, _, _, "reject").

property_approval_line(Text) :-
    re_match("(?i)^[ \\t]*:[^: \\t]*(?:approval|approve|reject)[^:]*:", Text, []).

line_text(Lines, Number, Text) :-
    member(line(Number, Text), Lines).

numbered_lines([], _, []).
numbered_lines([Line|Lines], Number, [line(Number, Line)|Numbered]) :-
    Next is Number + 1,
    numbered_lines(Lines, Next, Numbered).

results_errors([], [], []).
results_errors([result(Errors, IdEntries)|Results], AllErrors, AllIds) :-
    results_errors(Results, MoreErrors, MoreIds),
    append(Errors, MoreErrors, AllErrors),
    append(IdEntries, MoreIds, AllIds).

first_or_default([Value|_], _, Value) :- !.
first_or_default([], Default, Default).

exclude_empty([], []).
exclude_empty([""|Values], Rest) :-
    !,
    exclude_empty(Values, Rest).
exclude_empty([Value|Values], [Value|Rest]) :-
    exclude_empty(Values, Rest).

run_git(Root, Arguments, ExpectedCode, Output) :-
    process_create(path(git), Arguments,
                   [ cwd(Root), stdin(null), stdout(pipe(Stream)),
                     stderr(null), process(PID) ]),
    read_string(Stream, _, RawOutput),
    close(Stream),
    process_wait(PID, exit(Code)),
    normalize_space(string(Output), RawOutput),
    Code =:= ExpectedCode.
