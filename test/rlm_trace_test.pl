:- begin_tests(rlm_trace).

:- use_module('../prolog/rlm_trace').
:- use_module(library(http/json)).

test(compound_terms_are_structured_not_flat_strings) :-
    Payload = event(route(recursive_rlm),
                    _{depth:1, flags:[ok,done]}),
    trace_encode(Payload, Encoded),
    get_dict('$term', Encoded, EventFunctor),
    assertion(EventFunctor == "event"),
    Encoded.args = [Route, Dict],
    get_dict('$term', Route, RouteFunctor),
    assertion(RouteFunctor == "route"),
    assertion(Route.args == ["recursive_rlm"]),
    assertion(Dict.depth =:= 1),
    assertion(Dict.flags == ["ok","done"]).

test(json_envelope_has_version_name_and_payload) :-
    trace_envelope(demo, _{status:ok}, Envelope),
    trace_json(Envelope, Json),
    atom_string(JsonAtom, Json),
    atom_json_dict(JsonAtom, Parsed, []),
    assertion(Parsed.schema == "prolog-rlm.trace.v1"),
    assertion(Parsed.name == "demo"),
    assertion(Parsed.payload.status == "ok").

test(jsonl_enumerates_top_level_list) :-
    trace_envelope(events, [alpha,beta,gamma], Envelope),
    trace_jsonl(Envelope, Jsonl),
    split_string(Jsonl, "\n", "", RawLines),
    exclude(=(""), RawLines, Lines),
    assertion(length(Lines, 3)),
    Lines = [FirstLine|_],
    atom_string(FirstAtom, FirstLine),
    atom_json_dict(FirstAtom, First, []),
    assertion(First.sequence =:= 1),
    assertion(First.payload == "alpha").

test(write_read_and_view_json_roundtrip) :-
    tmp_file_stream(text, Path, Stream),
    close(Stream),
    setup_call_cleanup(
        true,
        ( trace_write(Path,
                      json,
                      sample,
                      _{events:[event(a),event(b)], count:2},
                      ok(Write)),
          assertion(Write.bytes > 0),
          trace_read(Path, json, ok(Envelope)),
          assertion(Envelope.schema == "prolog-rlm.trace.v1"),
          trace_view_file(Path, json, ok(View)),
          assertion(sub_string(View, _, _, _, "payload")),
          assertion(sub_string(View, _, _, _, "events")),
          assertion(sub_string(View, _, _, _, "$term"))
        ),
        delete_file(Path)).

test(write_read_jsonl_roundtrip) :-
    tmp_file_stream(text, Path, Stream),
    close(Stream),
    setup_call_cleanup(
        true,
        ( trace_write(Path, jsonl, events, [a,b], ok(_)),
          trace_read(Path, jsonl, ok(Records)),
          assertion(length(Records, 2)),
          Records = [First,Second],
          assertion(First.sequence =:= 1),
          assertion(Second.sequence =:= 2)
        ),
        delete_file(Path)).

:- end_tests(rlm_trace).
