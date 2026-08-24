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
                fidelity:warm_fidelity{verbatim:100,
                                       detailed_summary:90,
                                       compact_summary:70,
                                       facts_only:60},
                weights:warm_weights{pinned:100000,
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
    get_dict(id, Conversation, ConversationId),
    Source = warm_source{conversation_id:ConversationId,
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
    Warm = warm_context{conversation_id:ConversationId,
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
    get_dict(source_range, Warm, SourceRange),
    get_dict(source_refs, Warm, SourceRefs),
    get_dict(generation, Warm, Generation),
    get_dict(kind, Generation, GeneratorKind),
    get_dict(id, Conversation, ConversationId),
    warm_key(SourceRange, Key),
    Provenance = warm_provenance{producer_type:conversation_compaction,
                                 conversation_id:ConversationId,
                                 source_range:SourceRange,
                                 source_refs:SourceRefs,
                                 generator:GeneratorKind},
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
    get_dict(max_candidates, Policy, MaxCandidates),
    take_first(MaxCandidates, Ranked, Selected),
    maplist(warm_artifact_unit(Signals, Policy), Selected, Units).

warm_policy(Options, Policy) :-
    default_warm_policy(Default),
    option(policy(Policy0), Options, Default),
    (   is_dict(Policy0)
    ->  put_dict(Policy0, Default, Candidate)
    ;   throw(warm_fault(invalid_policy(Policy0)))
    ),
    get_dict(max_candidates, Candidate, MaxCandidates),
    get_dict(fidelity, Candidate, Fidelity),
    get_dict(weights, Candidate, Weights),
    require_positive_integer(MaxCandidates, max_candidates),
    validate_score_dict(Fidelity, fidelity),
    validate_score_dict(Weights, weights),
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
    get_dict(source_range, Warm, Range),
    range_end(Range, End),
    weight(Policy, recency, RecencyWeight),
    RecencyScore is End*RecencyWeight,
    get_dict(key, Artifact, Key),
    signal_score(Key, Signals, Policy, SignalScore, _),
    Score is RecencyScore+SignalScore.

warm_artifact_unit(Signals, Policy, Artifact, Unit) :-
    artifact_warm(Artifact, Warm),
    get_dict(key, Artifact, Key),
    get_dict(variants, Warm, WarmVariants),
    signal_score(Key, Signals, Policy, SignalScore, Reasons),
    pinned_signal(Key, Signals, Mandatory),
    maplist(warm_variant_context(Artifact,
                                 Warm,
                                 Policy,
                                 SignalScore,
                                 Reasons),
            WarmVariants,
            Variants),
    Unit = context_unit{id:Key,
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
    get_dict(kind, WarmVariant, Kind),
    get_dict(tokens, WarmVariant, Tokens),
    get_dict(text, WarmVariant, Text),
    get_dict(ref, Artifact, ArtifactRef),
    get_dict(source_range, Warm, SourceRange),
    get_dict(source_refs, Warm, SourceRefs),
    fidelity_score(Policy, Kind, Fidelity),
    Utility is Fidelity+SignalScore,
    Value = warm_context_value{artifact_ref:ArtifactRef,
                               source_range:SourceRange,
                               source_refs:SourceRefs,
                               kind:Kind,
                               text:Text,
                               reasons:Reasons},
    Variant = context_variant{kind:Kind,
                              tokens:Tokens,
                              utility:Utility,
                              value:Value}.

fidelity_score(Policy, Kind, Score) :-
    get_dict(fidelity, Policy, Fidelity),
    (   get_dict(Kind, Fidelity, Score),
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
    get_dict(weights, Policy, Weights),
    (   get_dict(Kind, Weights, Weight),
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
    get_dict(messages, Source, Messages),
    source_payloads(Messages, Payloads),
    rlm_completion:rlm_completion(Prompt,
                                  terms(Payloads),
                                  CompletionOptions,
                                  CompletionOutcome),
    (   CompletionOutcome = ok(Completion)
    ->  get_dict(value, Completion, CompletionValue),
        get_dict(usage, Completion, Usage),
        get_dict(recursion, Completion, Recursion),
        completion_structured_value(CompletionValue, Data),
        Generation = warm_generation{kind:rlm,
                                     usage:Usage,
                                     recursion:Recursion}
    ;   CompletionOutcome = error(Error)
    ->  throw(warm_fault(rlm_generation_failed(Error)))
    ;   throw(warm_fault(invalid_completion_outcome(CompletionOutcome)))
    ).

warm_prompt("Derive warm context for the supplied conversation range. Return ONLY one JSON object with exactly these fields: summary (string), decisions (array of strings), facts (array of strings), unresolved (array of strings), entities (array of strings), topics (array of strings), files (array of strings), symbols (array of strings). Preserve concrete decisions and unresolved work; do not invent facts. The supplied opaque context is the authoritative source.").

source_payloads(Messages, Payloads) :-
    findall(Payload,
            ( member(Message, Messages),
              get_dict(message, Message, Payload) ),
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
    get_dict(tokens, Count, Tokens),
    Variant = warm_variant{kind:Kind,
                           text:Text,
                           tokens:Tokens,
                           token_count:Count}.

detailed_text(Data, Text) :-
    get_dict(summary, Data, Summary),
    get_dict(decisions, Data, DecisionValues),
    get_dict(facts, Data, FactValues),
    get_dict(unresolved, Data, UnresolvedValues),
    get_dict(entities, Data, EntityValues),
    get_dict(topics, Data, TopicValues),
    get_dict(files, Data, FileValues),
    get_dict(symbols, Data, SymbolValues),
    format_lines("Decisions", DecisionValues, Decisions),
    format_lines("Facts", FactValues, Facts),
    format_lines("Unresolved", UnresolvedValues, Unresolved),
    format_lines("Entities", EntityValues, Entities),
    format_lines("Topics", TopicValues, Topics),
    format_lines("Files", FileValues, Files),
    format_lines("Symbols", SymbolValues, Symbols),
    format(string(Text),
           "Summary: ~s\n~s~s~s~s~s~s~s",
           [Summary,
            Decisions,
            Facts,
            Unresolved,
            Entities,
            Topics,
            Files,
            Symbols]).

compact_text(Data, Text) :-
    get_dict(summary, Data, Summary),
    get_dict(unresolved, Data, UnresolvedValues),
    format_lines("Unresolved", UnresolvedValues, Unresolved),
    format(string(Text), "Summary: ~s\n~s", [Summary, Unresolved]).

facts_text(Data, Text) :-
    get_dict(decisions, Data, Decisions),
    get_dict(facts, Data, Facts),
    append(Decisions, Facts, Facts0),
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
    findall(Ref,
            ( member(Message, Messages),
              get_dict(ref, Message, Ref) ),
            Refs).

render_messages(Messages, Text) :-
    maplist(render_message, Messages, Rendered),
    atomics_to_string(Rendered, "\n", Text).

render_message(Message, Text) :-
    get_dict(content, Message, RawContent),
    get_dict(sequence, Message, Sequence),
    get_dict(role, Message, Role),
    content_text(RawContent, Content),
    format(string(Text), '[~d] ~w: ~s',
           [Sequence, Role, Content]).

content_text(Content, Content) :- string(Content), !.
content_text(Content, Text) :- atom(Content), !, atom_string(Content, Text).
content_text(Content, Text) :-
    with_output_to(string(Text),
                   write_term(Content,
                              [quoted(true), portray(false), max_depth(12)])).

warm_namespace(Conversation, [conversation, ConversationId, warm]) :-
    get_dict(id, Conversation, ConversationId).

warm_key(range(Start, End), Key) :-
    format(atom(Key), 'range_~d_~d', [Start, End]).

artifact_warm(Artifact, Warm) :-
    (   is_dict(Artifact),
        get_dict(kind, Artifact, warm_context),
        get_dict(value, Artifact, Value),
        is_dict(Value)
    ->  Warm = Value
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
