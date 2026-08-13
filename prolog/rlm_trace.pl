:- module(rlm_trace,
          [ rlm_trace_ready/0,
            trace_envelope/3,
            trace_json/2,
            trace_jsonl/2,
            trace_write/5,
            trace_read/3,
            trace_view/2,
            trace_view_file/3,
            trace_encode/2
          ]).

/** <module> Portable trace export and inspection

Arbitrary Prolog runtime terms are converted into a stable JSON-safe
representation. Dict/list structure is preserved. Non-dict compound terms are
encoded explicitly as `{"$term": Functor, "args": [...]}` so consumers do not
have to parse `write_term/3` output to recover trajectory structure.
*/

:- use_module(library(http/json)).
:- use_module(library(readutil)).
:- use_module(library(lists)).

rlm_trace_ready.

trace_envelope(Name0, Payload0, Envelope) :-
    normalize_name(Name0, Name),
    trace_encode(Payload0, Payload),
    get_time(Now),
    format_time(string(GeneratedAt), '%FT%T%z', Now),
    Envelope = trace_envelope{
                   schema:"prolog-rlm.trace.v1",
                   name:Name,
                   generated_at:GeneratedAt,
                   payload:Payload
               }.

trace_json(Envelope0, Json) :-
    ensure_envelope(Envelope0, Envelope),
    with_output_to(string(Json),
                   json_write_dict(current_output,
                                   Envelope,
                                   [width(0)])).

trace_jsonl(Envelope0, Jsonl) :-
    ensure_envelope(Envelope0, Envelope),
    Payload = Envelope.payload,
    jsonl_records(Envelope, Payload, Records),
    maplist(json_record_string, Records, Lines),
    atomics_to_string(Lines, "\n", Body),
    string_concat(Body, "\n", Jsonl).

trace_write(Path0, Format, Name, Payload, Outcome) :-
    catch(trace_write_(Path0, Format, Name, Payload, Outcome),
          Exception,
          trace_exception(write, Exception, Outcome)).

trace_write_(Path0, Format, Name, Payload, ok(Result)) :-
    normalize_path(Path0, Path),
    trace_envelope(Name, Payload, Envelope),
    trace_serialized(Format, Envelope, Text),
    setup_call_cleanup(
        open(Path, write, Stream, [encoding(utf8)]),
        format(Stream, '~s', [Text]),
        close(Stream)),
    string_codes(Text, Codes),
    length(Codes, Bytes),
    Result = trace_write_result{path:Path,
                                format:Format,
                                bytes:Bytes,
                                schema:Envelope.schema}.

trace_read(Path0, Format, Outcome) :-
    catch(trace_read_(Path0, Format, Outcome),
          Exception,
          trace_exception(read, Exception, Outcome)).

trace_read_(Path0, json, ok(Envelope)) :-
    normalize_path(Path0, Path),
    setup_call_cleanup(
        open(Path, read, Stream, [encoding(utf8)]),
        json_read_dict(Stream, Envelope),
        close(Stream)),
    validate_envelope(Envelope).
trace_read_(Path0, jsonl, ok(Records)) :-
    normalize_path(Path0, Path),
    setup_call_cleanup(
        open(Path, read, Stream, [encoding(utf8)]),
        read_jsonl_records(Stream, Records),
        close(Stream)).
trace_read_(_, Format, _) :-
    throw(trace_fault(unsupported_format(Format))).

trace_view(Payload, Text) :-
    trace_encode(Payload, Encoded),
    view_lines(Encoded, 0, root, Lines),
    atomics_to_string(Lines, "\n", Body),
    string_concat(Body, "\n", Text).

trace_view_file(Path, Format, Outcome) :-
    trace_read(Path, Format, ReadOutcome),
    (   ReadOutcome = ok(Value)
    ->  trace_view(Value, Text),
        Outcome = ok(Text)
    ;   ReadOutcome = error(Error),
        Outcome = error(Error)
    ).

/* Encoding -------------------------------------------------------------- */

trace_encode(Value, Encoded) :-
    (   var(Value)
    ->  Encoded = trace_var{'$var':"_"}
    ;   number(Value)
    ->  Encoded = Value
    ;   string(Value)
    ->  Encoded = Value
    ;   Value == true
    ->  Encoded = true
    ;   Value == false
    ->  Encoded = false
    ;   Value == null
    ->  Encoded = null
    ;   atom(Value)
    ->  atom_string(Value, Encoded)
    ;   is_list(Value)
    ->  maplist(trace_encode, Value, Encoded)
    ;   is_dict(Value)
    ->  dict_pairs(Value, _, Pairs0),
        maplist(encode_pair, Pairs0, Pairs),
        dict_pairs(Encoded, trace_dict, Pairs)
    ;   compound(Value)
    ->  Value =.. [Functor|Args0],
        atom_string(Functor, FunctorString),
        maplist(trace_encode, Args0, Args),
        Encoded = trace_term{'$term':FunctorString,
                             args:Args}
    ;   term_string(Value, Encoded,
                    [quoted(true), numbervars(true)])
    ).

encode_pair(Key-Value0, Key-Value) :-
    trace_encode(Value0, Value).

ensure_envelope(Envelope, Envelope) :-
    is_dict(Envelope),
    get_dict(schema, Envelope, "prolog-rlm.trace.v1"),
    get_dict(payload, Envelope, _),
    !.
ensure_envelope(Payload, Envelope) :-
    trace_envelope(trace, Payload, Envelope).

validate_envelope(Envelope) :-
    (   is_dict(Envelope),
        get_dict(schema, Envelope, "prolog-rlm.trace.v1"),
        get_dict(payload, Envelope, _)
    ->  true
    ;   throw(trace_fault(invalid_envelope))
    ).

/* JSONL ----------------------------------------------------------------- */

jsonl_records(Envelope, Payload, Records) :-
    (   is_list(Payload)
    ->  enumerate_payload(Payload, 1, Envelope, Records)
    ;   Records = [trace_record{
                       schema:"prolog-rlm.trace.v1",
                       name:Envelope.name,
                       generated_at:Envelope.generated_at,
                       sequence:1,
                       payload:Payload
                   }]
    ).

enumerate_payload([], _, _, []).
enumerate_payload([Payload|Rest], N, Envelope, [Record|Records]) :-
    Record = trace_record{
                 schema:"prolog-rlm.trace.v1",
                 name:Envelope.name,
                 generated_at:Envelope.generated_at,
                 sequence:N,
                 payload:Payload
             },
    N1 is N+1,
    enumerate_payload(Rest, N1, Envelope, Records).

json_record_string(Record, String) :-
    with_output_to(string(String),
                   json_write_dict(current_output,
                                   Record,
                                   [width(0)])).

read_jsonl_records(Stream, Records) :-
    read_line_to_string(Stream, Line),
    read_jsonl_line(Line, Stream, Records).

read_jsonl_line(end_of_file, _, []) :- !.
read_jsonl_line("", Stream, Records) :-
    !,
    read_jsonl_records(Stream, Records).
read_jsonl_line(Line, Stream, [Record|Records]) :-
    atom_string(Atom, Line),
    atom_json_dict(Atom, Record, []),
    read_jsonl_records(Stream, Records).

trace_serialized(json, Envelope, Text) :-
    !,
    trace_json(Envelope, Json),
    string_concat(Json, "\n", Text).
trace_serialized(jsonl, Envelope, Text) :-
    !,
    trace_jsonl(Envelope, Text).
trace_serialized(Format, _, _) :-
    throw(trace_fault(unsupported_format(Format))).

/* Text viewer ----------------------------------------------------------- */

view_lines(Value, Indent, Label, Lines) :-
    indent_string(Indent, Prefix),
    view_value(Value, Indent, Label, Prefix, Lines).

view_value(Value, _, Label, Prefix, [Line]) :-
    atomic_json_value(Value),
    !,
    format(string(Line), '~s~w = ~w', [Prefix, Label, Value]).
view_value(Value, Indent, Label, Prefix, [Header|Lines]) :-
    is_list(Value),
    !,
    length(Value, Count),
    format(string(Header), '~s~w [~d]', [Prefix, Label, Count]),
    Next is Indent+2,
    view_list_lines(Value, 1, Next, Lines).
view_value(Value, Indent, Label, Prefix, [Header|Lines]) :-
    is_dict(Value),
    !,
    format(string(Header), '~s~w', [Prefix, Label]),
    dict_pairs(Value, _, Pairs),
    Next is Indent+2,
    view_pair_lines(Pairs, Next, Lines).
view_value(Value, _, Label, Prefix, [Line]) :-
    format(string(Line), '~s~w = ~q', [Prefix, Label, Value]).

atomic_json_value(Value) :- number(Value), !.
atomic_json_value(Value) :- string(Value), !.
atomic_json_value(true).
atomic_json_value(false).
atomic_json_value(null).

view_list_lines([], _, _, []).
view_list_lines([Value|Rest], Index, Indent, Lines) :-
    format(atom(Label), '[~d]', [Index]),
    view_lines(Value, Indent, Label, HeadLines),
    Index1 is Index+1,
    view_list_lines(Rest, Index1, Indent, TailLines),
    append(HeadLines, TailLines, Lines).

view_pair_lines([], _, []).
view_pair_lines([Key-Value|Rest], Indent, Lines) :-
    view_lines(Value, Indent, Key, HeadLines),
    view_pair_lines(Rest, Indent, TailLines),
    append(HeadLines, TailLines, Lines).

indent_string(Indent, Prefix) :-
    length(Codes, Indent),
    maplist(=(0' ), Codes),
    string_codes(Prefix, Codes).

/* Validation and errors ------------------------------------------------- */

normalize_name(Name, Name) :- string(Name), !.
normalize_name(Name, String) :- atom(Name), !, atom_string(Name, String).
normalize_name(Name, String) :-
    ground(Name),
    !,
    term_string(Name,
                String,
                [quoted(true), numbervars(true), max_depth(8)]).
normalize_name(Name, _) :- throw(trace_fault(invalid_name(Name))).

normalize_path(Path, Path) :- atom(Path), !.
normalize_path(Path, Atom) :- string(Path), !, atom_string(Path, Atom).
normalize_path(Path, _) :- throw(trace_fault(invalid_path(Path))).

trace_exception(Phase, trace_fault(Detail), error(Error)) :-
    !,
    Error = trace_error{phase:Phase,
                        kind:trace_error,
                        detail:Detail,
                        message:"trace operation rejected the request"}.
trace_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = trace_error{phase:Phase,
                        kind:exception,
                        exception:Safe,
                        message:"trace operation raised an exception"}.
