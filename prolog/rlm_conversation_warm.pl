:- module(rlm_conversation_warm,
          [ rlm_conversation_warm_ready/0,
            default_warm_policy/1,
            warm_context_schema/1,
            conversation_warm_derive/4,
            conversation_warm_publish/5,
            conversation_warm_list/4,
            conversation_warm_context_units/5
          ]).

/** <module> Durable warm-context derivation for managed conversations

Warm context is derived, versioned state.  It never replaces or mutates source
conversation messages.  Each warm record names exact source message refs and
contains multiple provider-visible representations with independently measured
token costs.  The generic context-budget solver can therefore backtrack from a
verbatim representation to a smaller summary while preserving mandatory hot
context.
*/

:- use_module(library(option)).
:- use_module(library(lists)).
:- use_module(rlm_artifact).
:- use_module(rlm_chain_schema,
              [ structured_schema_compile/2,
                structured_validate/3,
                structured_decode_validate/3
              ]).
:- use_module(rlm_completion, []).
:- use_module(rlm_context_budget).
:- use_module(rlm_conversation).

rlm_conversation_warm_ready :-
    rlm_context_budget:rlm_context_budget_ready,
    rlm_artifact:rlm_artifact_ready.

default_warm_policy(
    warm_policy{max_candidates:32,
                fidelity:_{verbatim:100,
                           detailed_summary:90,
                           compact_summary:70,
                           facts_only:60},
                weights:_{pinned:100000,
                          direct_reference:1000,
                          active_task:600,
                          unresolved:400,
                          dependency:300,
                          entity:200,
                          topic:120,
                          retrieval:100,
                          recency:1}}).

warm_context_schema(
    object([ field(summary, string, required),
             field(decisions, list(string), required),
             field(facts, list(string), required),
             field(unresolved, list(string), required),
             field(entities, list(string), required),
             field(topics, list(string), required),
             field(files, list(string), required),
             field(symbols, list(string), required)
           ])).

/* -------------------------------------------------------------------------
 * Derivation and publication
 * ---------------------------------------------------------------------- */

conversation_warm_derive(Conversation, Range, Options, Outcome) :-
    warm_outcome(derive,
                 conversation_warm_derive_(Conversation,
                                           Range,
                                           Options),
                 Outcome).

conversation_warm_derive_(Conversation, Range0, Options, Warm) :-
    require_options(Options),
    normalize_range(Range0, Range),
    source_messages(Conversation, Range, Messages),
    source_refs(Messages, Refs),
    render_messages(Messages, SourceText),
    Source = warm_source{conversation_id:Conversation.id,
                         range:Range,
                         refs:Refs,
                         messages:Messages,
                         text:SourceText},
    generate_warm(Source, Options, Generated, Generation),
    validate_generated(Generated, Data),
    option(token_options(TokenOptions), Options, []),
    require_options(TokenOptions),
    build_variants(SourceText,
                   Data,
                   TokenOptions,
                   Variants),
    get_time(CreatedAt),
    Warm = warm_context{conversation_id:Conversation.id,
                        source_range:Range,
                        source_refs:Refs,
                        generated:Data,
                        variants:Variants,
                        generation:Generation,
                        created_at:CreatedAt}.

conversation_warm_publish(Conversation,
                          ArtifactStore,
                          Range,
                          Options,
                          Outcome) :-
    warm_outcome(publish,
                 conversation_warm_publish_(Conversation,
                                            ArtifactStore,
                                            Range,
                                            Options),
                 Outcome).

conversation_warm_publish_(Conversation,
                           ArtifactStore,
                           Range,
                           Options,
                           Published) :-
    conversation_warm_derive_(Conversation, Range, Options, Warm),
    warm_namespace(Conversation, Namespace),
    warm_key(Warm.source_range, Key),
    Provenance = warm_provenance{producer_type:conversation_compaction,
                                 conversation_id:Conversation.id,
                                 source_range:Warm.source_range,
                                 source_refs:Warm.source_refs,
                                 generator:Warm.generation.kind},
    artifact_put(ArtifactStore,
                 Namespace,
                 Key,
                 warm_context,
                 Warm,
                 Provenance,
                 ArtifactOutcome),
    require_artifact_outcome(ArtifactOutcome, Artifact),
    Published = warm_publication{artifact:Artifact,
                                 warm:Warm}.

conversation_warm_list(Conversation,
                       ArtifactStore,
                       Options,
                       Outcome) :-
    warm_outcome(list,
                 conversation_warm_list_(Conversation,
                                         ArtifactStore,
                                         Options),
                 Outcome).

conversation_warm_list_(Conversation,
                        ArtifactStore,
                        Options,
                        Artifacts) :-
    require_options(Options),
    warm_namespace(Conversation, Namespace),
    option(history(History), Options, false),
    require_boolean(History, history),
    artifact_list(ArtifactStore,
                  Namespace,
                  [history(History)],
                  ArtifactOutcome),
    require_artifact_outcome(ArtifactOutcome, Artifacts).

/* -------------------------------------------------------------------------
 * Candidate narrowing and context-unit compilation
 * ---------------------------------------------------------------------- */

conversation_warm_context_units(Conversation,
                                ArtifactStore,
                                Signals,
                                Options,
                                Outcome) :-
    warm_outcome(context_units,
                 conversation_warm_context_units_(Conversation,
                                                  ArtifactStore,
                                                  Signals,
                                                  Options),
                 Outcome).

conversation_warm_context_units_(Conversation,
                                 ArtifactStore,
                                 Signals0,
                                 Options,
                                 Units) :-
    require_options(Options),
    normalize_signals(Signals0, Signals),
    warm_policy(Options, Policy),
    conversation_warm_list_(Conversation,
                            ArtifactStore,
                            [history(false)],
                            Artifacts),
    rank_candidates(Artifacts, Signals, Policy, Ranked),
    take_first(Policy.max_candidates, Ranked, Selected),
    maplist(warm_artifact_unit(Signals, Policy), Selected, Units).

warm_policy(Options, Policy) :-
    default_warm_policy(Default),
    option(policy(Policy0), Options, Default),
    (   is_dict(Policy0)
    ->  put_dict(Policy0, Default, Candidate)
    ;   throw(warm_fault(invalid_policy(Policy0)))
    ),
    require_positive_integer(Candidate.max_candidates, max_candidates),
    validate_score_dict(Candidate.fidelity, fidelity),
    validate_score_dict(Candidate.weights, weights),
    Policy = Candidate.

rank_candidates(Artifacts, Signals, Policy, Ranked) :-
    findall(Negative-Artifact,
            ( member(Artifact, Artifacts),
              candidate_score(Artifact, Signals, Policy, Score),
              Negative is -Score ),
            Pairs0),
    keysort(Pairs0, Pairs),
    findall(Artifact, member(_-Artifact, Pairs), Ranked).

candidate_score(Artifact, Signals, Policy, Score) :-
    artifact_warm(Artifact, Warm),
    Range = Warm.source_range,
    range_end(Range, End),
    weight(Policy, recency, RecencyWeight),
    RecencyScore is End*RecencyWeight,
    signal_score(Artifact.key, Signals, Policy, SignalScore, _),
    Score is RecencyScore+SignalScore.

warm_artifact_unit(Signals, Policy, Artifact, Unit) :-
    artifact_warm(Artifact, Warm),
    signal_score(Artifact.key, Signals, Policy, SignalScore, Reasons),
    pinned_signal(Artifact.key, Signals, Mandatory),
    maplist(warm_variant_context(Artifact,
                                 Warm,
                                 Policy,
                                 SignalScore,
                                 Reasons),
            Warm.variants,
            Variants),
    Unit = context_unit{id:Artifact.key,
                        section:warm,
                        mandatory:Mandatory,
                        variants:Variants}.

warm_variant_context(Artifact,
                     Warm,
                     Policy,
                     SignalScore,
                     Reasons,
                     WarmVariant,
                     Variant) :-
    fidelity_score(Policy, WarmVariant.kind, Fidelity),
    Utility is Fidelity+SignalScore,
    Value = warm_context_value{artifact_ref:Artifact.ref,
                               source_range:Warm.source_range,
                               source_refs:Warm.source_refs,
                               kind:WarmVariant.kind,
                               text:WarmVariant.text,
                               reasons:Reasons},
    Variant = context_variant{kind:WarmVariant.kind,
                              tokens:WarmVariant.tokens,
                              utility:Utility,
                              value:Value}.

fidelity_score(Policy, Kind, Score) :-
    (   get_dict(Kind, Policy.fidelity, Score),
        integer(Score),
        Score >= 0
    ->  true
    ;   throw(warm_fault(missing_fidelity_score(Kind)))
    ).

signal_score(Key, Signals, Policy, Score, Reasons) :-
    findall(Contribution-Reason,
            ( member(warm_signal(Key, Kind, Strength), Signals),
              weight(Policy, Kind, Weight),
              Contribution is Strength*Weight,
              Reason = signal(Kind, Strength, Weight, Contribution) ),
            Contributions),
    findall(Value,
            member(Value-_, Contributions),
            Values),
    sum_list(Values, Score),
    findall(Reason,
            member(_-Reason, Contributions),
            Reasons).

weight(Policy, Kind, Weight) :-
    (   get_dict(Kind, Policy.weights, Weight),
        integer(Weight),
        Weight >= 0
    ->  true
    ;   throw(warm_fault(unsupported_signal_kind(Kind)))
    ).

pinned_signal(Key, Signals, true) :-
    member(warm_signal(Key, pinned, Strength), Signals),
    Strength > 0,
    !.
pinned_signal(_, _, false).

normalize_signals(Signals0, Signals) :-
    require_list(Signals0, signals),
    maplist(normalize_signal, Signals0, Signals).

normalize_signal(warm_signal(Key0, Kind0, Strength),
                 warm_signal(Key, Kind, Strength)) :-
    !,
    normalize_name(Key0, Key),
    normalize_name(Kind0, Kind),
    require_nonnegative_integer(Strength, signal_strength).
normalize_signal(Signal, _) :-
    throw(warm_fault(invalid_signal(Signal))).

/* -------------------------------------------------------------------------
 * Generators
 * ---------------------------------------------------------------------- */

generate_warm(Source, Options, Data, Generation) :-
    option(generator(Generator), Options, rlm),
    (   Generator == rlm
    ->  rlm_generate(Source, Options, Data, Generation)
    ;   callable(Generator)
    ->  callback_generate(Generator, Source, Options, Data, Generation)
    ;   throw(warm_fault(invalid_generator(Generator)))
    ).

callback_generate(Generator, Source, Options, Data,
                  warm_generation{kind:callback}) :-
    catch(( call(Generator, Source, Options, Raw)
          -> Data = Raw
          ;  throw(warm_fault(generator_failed))
          ),
          Exception,
          generator_exception(Exception)).

rlm_generate(Source, Options, Data, Generation) :-
    option(completion_options(CompletionOptions), Options, []),
    require_options(CompletionOptions),
    warm_prompt(Prompt),
    source_payloads(Source.messages, Payloads),
    rlm_completion:rlm_completion(Prompt,
                                  terms(Payloads),
                                  CompletionOptions,
                                  CompletionOutcome),
    (   CompletionOutcome = ok(Completion)
    ->  completion_structured_value(Completion.value, Data),
        Generation = warm_generation{kind:rlm,
                                     usage:Completion.usage,
                                     recursion:Completion.recursion}
    ;   CompletionOutcome = error(Error)
    ->  throw(warm_fault(rlm_generation_failed(Error)))
    ;   throw(warm_fault(invalid_completion_outcome(CompletionOutcome)))
    ).

warm_prompt("Derive warm context for the supplied conversation range. Return ONLY one JSON object with exactly these fields: summary (string), decisions (array of strings), facts (array of strings), unresolved (array of strings), entities (array of strings), topics (array of strings), files (array of strings), symbols (array of strings). Preserve concrete decisions and unresolved work; do not invent facts. The supplied opaque context is the authoritative source.").

source_payloads(Messages, Payloads) :-
    findall(Message.message,
            member(Message, Messages),
            Payloads).

completion_structured_value(Value, Data) :-
    warm_context_schema(SchemaSpec),
    structured_schema_compile(SchemaSpec, SchemaOutcome),
    require_schema_outcome(SchemaOutcome, Schema),
    (   is_dict(Value)
    ->  structured_validate(Schema, Value, Validation)
    ;   text_value(Value, Text)
    ->  structured_decode_validate(Schema, Text, Validation)
    ;   throw(warm_fault(invalid_rlm_value(Value)))
    ),
    require_schema_outcome(Validation, Data).

generator_exception(warm_fault(Detail)) :-
    !,
    throw(warm_fault(Detail)).
generator_exception(Exception) :-
    safe_exception(Exception, Safe),
    throw(warm_fault(generator_exception(Safe))).

/* -------------------------------------------------------------------------
 * Structured data and variants
 * ---------------------------------------------------------------------- */

validate_generated(Generated, Data) :-
    warm_context_schema(SchemaSpec),
    structured_schema_compile(SchemaSpec, SchemaOutcome),
    require_schema_outcome(SchemaOutcome, Schema),
    structured_validate(Schema, Generated, Validation),
    require_schema_outcome(Validation, Data).

build_variants(SourceText, Data, TokenOptions, Variants) :-
    detailed_text(Data, Detailed),
    compact_text(Data, Compact),
    facts_text(Data, Facts),
    variant(verbatim, SourceText, TokenOptions, Verbatim),
    variant(detailed_summary, Detailed, TokenOptions, DetailedVariant),
    variant(compact_summary, Compact, TokenOptions, CompactVariant),
    variant(facts_only, Facts, TokenOptions, FactsVariant),
    Variants = [Verbatim,
                DetailedVariant,
                CompactVariant,
                FactsVariant].

variant(Kind, Text, TokenOptions, Variant) :-
    token_count_text(Text, TokenOptions, TokenOutcome),
    require_budget_outcome(TokenOutcome, Count),
    Variant = warm_variant{kind:Kind,
                           text:Text,
                           tokens:Count.tokens,
                           token_count:Count}.

detailed_text(Data, Text) :-
    format_lines("Decisions", Data.decisions, Decisions),
    format_lines("Facts", Data.facts, Facts),
    format_lines("Unresolved", Data.unresolved, Unresolved),
    format_lines("Entities", Data.entities, Entities),
    format_lines("Topics", Data.topics, Topics),
    format_lines("Files", Data.files, Files),
    format_lines("Symbols", Data.symbols, Symbols),
    format(string(Text),
           "Summary: ~s\n~s~s~s~s~s~s~s",
           [Data.summary,
            Decisions,
            Facts,
            Unresolved,
            Entities,
            Topics,
            Files,
            Symbols]).

compact_text(Data, Text) :-
    format_lines("Unresolved", Data.unresolved, Unresolved),
    format(string(Text), "Summary: ~s\n~s", [Data.summary, Unresolved]).

facts_text(Data, Text) :-
    append(Data.decisions, Data.facts, Facts0),
    format_lines("Facts and decisions", Facts0, Text).

format_lines(_, [], "") :- !.
format_lines(Label, Values, Text) :-
    maplist(prefix_bullet, Values, Lines),
    atomics_to_string(Lines, "\n", Body),
    format(string(Text), "~s:\n~s\n", [Label, Body]).

prefix_bullet(Value, Line) :-
    format(string(Line), "- ~s", [Value]).

/* -------------------------------------------------------------------------
 * Conversation source and artifact identity
 * ---------------------------------------------------------------------- */

source_messages(Conversation, Range, Messages) :-
    conversation_messages(Conversation,
                          Range,
                          [],
                          MessageOutcome),
    require_conversation_outcome(MessageOutcome, Messages),
    (   Messages == []
    ->  throw(warm_fault(empty_source_range(Range)))
    ;   true
    ).

source_refs(Messages, Refs) :-
    findall(Message.ref, member(Message, Messages), Refs).

render_messages(Messages, Text) :-
    maplist(render_message, Messages, Rendered),
    atomics_to_string(Rendered, "\n", Text).

render_message(Message, Text) :-
    content_text(Message.content, Content),
    format(string(Text), '[~d] ~w: ~s',
           [Message.sequence, Message.role, Content]).

content_text(Content, Content) :- string(Content), !.
content_text(Content, Text) :- atom(Content), !, atom_string(Content, Text).
content_text(Content, Text) :-
    with_output_to(string(Text),
                   write_term(Content,
                              [quoted(true), portray(false), max_depth(12)])).

warm_namespace(Conversation, [conversation, ConversationId, warm]) :-
    ConversationId = Conversation.id.

warm_key(range(Start, End), Key) :-
    format(atom(Key), 'range_~d_~d', [Start, End]).

artifact_warm(Artifact, Warm) :-
    (   is_dict(Artifact),
        Artifact.kind == warm_context,
        is_dict(Artifact.value)
    ->  Warm = Artifact.value
    ;   throw(warm_fault(invalid_warm_artifact(Artifact)))
    ).

normalize_range(range(Start, End), range(Start, End)) :-
    !,
    require_positive_integer(Start, range_start),
    require_positive_integer(End, range_end),
    (   Start =< End
    ->  true
    ;   throw(warm_fault(invalid_range(Start, End)))
    ).
normalize_range(Range, _) :-
    throw(warm_fault(invalid_range(Range))).

range_end(range(_, End), End).

/* -------------------------------------------------------------------------
 * Helpers and structured outcomes
 * ---------------------------------------------------------------------- */

validate_score_dict(Dict, Name) :-
    (   is_dict(Dict)
    ->  dict_pairs(Dict, _, Pairs),
        forall(member(_-Value, Pairs),
               require_nonnegative_integer(Value, Name))
    ;   throw(warm_fault(expected_score_dict(Name, Dict)))
    ).

take_first(0, _, []) :- !.
take_first(_, [], []) :- !.
take_first(Count, [Item|Items], [Item|Taken]) :-
    Count > 0,
    Next is Count-1,
    take_first(Next, Items, Taken).

require_conversation_outcome(ok(Value), Value) :- !.
require_conversation_outcome(error(Error), _) :-
    throw(warm_fault(conversation_error(Error))).

require_artifact_outcome(ok(Value), Value) :- !.
require_artifact_outcome(error(Error), _) :-
    throw(warm_fault(artifact_error(Error))).

require_budget_outcome(ok(Value), Value) :- !.
require_budget_outcome(error(Error), _) :-
    throw(warm_fault(context_budget_error(Error))).

require_schema_outcome(ok(Value), Value) :- !.
require_schema_outcome(error(Error), _) :-
    throw(warm_fault(schema_error(Error))).

warm_outcome(Phase, Goal, Outcome) :-
    catch(( call(Goal, Value), Outcome = ok(Value) ),
          Exception,
          warm_exception(Phase, Exception, Outcome)).

warm_exception(Phase, warm_fault(Detail), error(Error)) :-
    !,
    Error = warm_context_error{phase:Phase,
                               kind:warm_context_error,
                               detail:Detail,
                               message:"warm conversation context operation failed"}.
warm_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = warm_context_error{phase:Phase,
                               kind:exception,
                               exception:Safe,
                               message:"warm conversation context raised an exception"}.

normalize_name(Value, Atom) :- atom(Value), !, Atom = Value.
normalize_name(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
normalize_name(Value, _) :- throw(warm_fault(expected_name(Value))).

text_value(Value, Text) :- string(Value), !, Text = Value.
text_value(Value, Text) :- atom(Value), !, atom_string(Value, Text).

require_options(Value) :- is_list(Value), !.
require_options(Value) :- throw(warm_fault(expected_options(Value))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Name) :- throw(warm_fault(expected_list(Name, Value))).

require_boolean(true, _) :- !.
require_boolean(false, _) :- !.
require_boolean(Value, Name) :-
    throw(warm_fault(expected_boolean(Name, Value))).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Name) :-
    throw(warm_fault(expected_positive_integer(Name, Value))).

require_nonnegative_integer(Value, _) :- integer(Value), Value >= 0, !.
require_nonnegative_integer(Value, Name) :-
    throw(warm_fault(expected_nonnegative_integer(Name, Value))).

safe_exception(Exception, Safe) :-
    (   ground(Exception)
    ->  with_output_to(string(Safe),
                       write_term(Exception,
                                  [quoted(true), portray(false), max_depth(10)]))
    ;   Safe = "non-ground exception"
    ).
