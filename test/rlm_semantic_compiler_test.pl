:- begin_tests(rlm_semantic_compiler).

:- use_module('../prolog/rlm_semantic_compiler').
:- use_module(library(http/json)).

source("Use ZMQ. Remember to add timeout tests.").

candidate(Candidate) :-
    semantic_schema(Schema),
    Candidate = _{schema:Schema,
      records:[_{id:"r1", kind:"decision", predicate:"transport",
        arguments:["zmq"], statement:"Use ZMQ.", polarity:"positive",
        modality:"requested", attribution:"", context:"",
        evidence:_{start:0, end:8, quote:"Use ZMQ."}, depends_on:[]},
       _{id:"r2", kind:"todo", predicate:"add_tests",
        arguments:["timeout"], statement:"Add timeout tests.", polarity:"positive",
        modality:"requested", attribution:"", context:"",
        evidence:_{start:9, end:39, quote:"Remember to add timeout tests."},
        depends_on:["r1"]}], gaps:[]}.

% Provider seam only: production llm_query and its scheduler/accounting still run.
model(_Request, ok(Response)) :-
    candidate(Candidate),
    atom_json_dict(Atom, Candidate, []), atom_string(Atom, Text),
    response(Text, Response).

bad_model(_Request, ok(Response)) :- response("not JSON", Response).

response(Text, model_response{provider:fixture, requested_model:fixture,
    selected_model:fixture, text:Text, reasoning:"", tool_calls:[],
    finish_reason:stop,
    usage:usage{present:true, prompt_tokens:10, completion_tokens:20,
                total_tokens:30, cost:0.0},
    metadata:metadata{http_status:200, response_received:true}}).

request(Request) :-
    source(Text),
    semantic_request(Text,
      [source_id("mem-test"), request_id("compile-1"),
       project("project-test"), requested_by("caller"), run_id("run-1")], Request).

test(english_goes_through_real_runtime_provider_seam) :-
    request(Request),
    semantic_compile_request(Request,
      [model_handler(plunit_rlm_semantic_compiler:model)], Outcome),
    Outcome = ok(Compilation),
    assertion(Compilation.receipt.usage.model_calls == 1),
    assertion(Compilation.receipt.interpretation_trust == model_inferred),
    assertion(Compilation.receipt.semantic_fidelity == unverified),
    Compilation.package.records = [Decision, Todo],
    assertion(Decision.predicate == "transport"),
    assertion(Todo.kind == "todo"),
    assertion(Todo.depends_on == ["r1"]),
    assertion(Compilation.request_id == "compile-1"),
    atom_json_dict(_, Compilation, []).

test(malformed_model_output_preserves_usage) :-
    request(Request),
    semantic_compile_request(Request,
      [model_handler(plunit_rlm_semantic_compiler:bad_model)], Outcome),
    Outcome = error(Error),
    assertion(Error.kind == invalid_candidate),
    assertion(Error.usage.model_calls == 1).

test(exact_span_is_required) :-
    source(Text), candidate(C0), C0.records = [First, Second],
    put_dict(evidence, First, _{start:0, end:8, quote:"Use HTTP"}, Bad),
    put_dict(records, C0, [Bad, Second], Candidate),
    semantic_validate(Candidate, Text, Outcome),
    assertion(Outcome = error(_)).

test(unknown_fields_fail_instead_of_losing_meaning) :-
    source(Text), candidate(C0), put_dict(unknown_quantifier, C0, all, C),
    semantic_validate(C, Text, Outcome), assertion(Outcome = error(_)).

test(duplicate_record_ids_fail) :-
    source(Text), candidate(C0), C0.records = [A, B0], put_dict(id, B0, "r1", B),
    put_dict(records, C0, [A, B], C),
    semantic_validate(C, Text, Outcome), assertion(Outcome = error(_)).

test(dangling_dependencies_fail) :-
    source(Text), candidate(C0), C0.records = [A, B0],
    put_dict(depends_on, B0, ["missing"], B), put_dict(records, C0, [A, B], C),
    semantic_validate(C, Text, Outcome), assertion(Outcome = error(_)).

test(compound_arguments_never_become_calls) :-
    source(Text), candidate(C0), C0.records = [A0, B],
    put_dict(arguments, A0, [assertz(user:unexpected_semantic_execution)], A),
    put_dict(records, C0, [A, B], C),
    semantic_validate(C, Text, Outcome), assertion(Outcome = error(_)),
    assertion(\+ current_predicate(user:unexpected_semantic_execution/0)).

test(attribution_and_uncertainty_remain_explicit) :-
    Text = "Alice says the service might be offline.",
    string_length(Text, End), semantic_schema(Schema),
    C = _{schema:Schema, records:[_{id:"a", kind:"claim", predicate:"offline",
      arguments:["service"], statement:Text, polarity:"positive",
      modality:"possible", attribution:"Alice", context:"",
      evidence:_{start:0, end:End, quote:Text}, depends_on:[]}], gaps:[]},
    semantic_validate(C, Text, ok(Valid)), Valid.records = [Claim],
    assertion(Claim.modality == "possible"),
    assertion(Claim.attribution == "Alice").

test(explicit_negative_is_not_unknown) :-
    source(Text), candidate(C0), C0.records = [A0, B],
    put_dict(polarity, A0, "negative", A), put_dict(records, C0, [A, B], C),
    semantic_validate(C, Text, ok(Valid)), Valid.records = [Negative, _],
    assertion(Negative.polarity == "negative").

test(anonymous_dict_tags_do_not_change_fingerprints) :-
    source(Text), candidate(A), candidate(B),
    semantic_validate(A, Text, ok(VA)), semantic_validate(B, Text, ok(VB)),
    assertion(VA == VB), assertion(ground(VA)).

test(non_ground_values_are_rejected_not_bound) :-
    source(Text), candidate(C0), C0.records = [A0, B],
    put_dict(arguments, A0, [_Unknown], A), put_dict(records, C0, [A, B], C),
    semantic_validate(C, Text, Outcome), assertion(Outcome = error(_)).

test(unique_quote_gets_deterministic_unicode_offsets) :-
    Text = "λ. Use ZMQ.", semantic_schema(Schema),
    Candidate = _{schema:Schema, records:[_{id:"a", kind:"decision",
      predicate:"transport", arguments:["zmq"], statement:"Use ZMQ.",
      polarity:"positive", modality:"requested", attribution:"", context:"",
      evidence:_{quote:"Use ZMQ."}, depends_on:[]}], gaps:[]},
    semantic_validate(Candidate, Text, ok(Valid)), Valid.records = [Record],
    assertion(Record.evidence.start == 3), assertion(Record.evidence.end == 11).

test(repeated_quote_is_not_silently_attached_to_first_occurrence) :-
    Text = "Use ZMQ. Use ZMQ.", candidate(C0), C0.records = [A0, _],
    put_dict(evidence, A0, _{quote:"Use ZMQ."}, A), put_dict(records, C0, [A], C),
    semantic_validate(C, Text, Outcome), assertion(Outcome = error(_)).

test(empty_output_is_not_a_successful_digest) :-
    source(Text), semantic_schema(Schema),
    semantic_validate(_{schema:Schema, records:[], gaps:[]}, Text, Outcome),
    assertion(Outcome = error(_)).

:- end_tests(rlm_semantic_compiler).
