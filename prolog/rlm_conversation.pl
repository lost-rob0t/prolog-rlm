:- module(rlm_conversation,
          [ rlm_conversation_ready/0,
            conversation_store_open/2,
            conversation_store_close/2,
            conversation_create/3,
            conversation_open/3,
            conversation_list/3,
            conversation_append/3,
            conversation_message/3,
            conversation_messages/4,
            conversation_search/4,
            conversation_stats/2,
            conversation_export/3,
            conversation_context_pack/3,
            conversation_token_ledger/3,
            conversation_cold_context/3,
            conversation_turn/4
          ]).

/** <module> Durable managed conversation runtime

A conversation owns the complete chronological transcript. Provider-visible
context is a compiled projection of that transcript; removing a message from an
active context pack never removes it from the conversation.

`conversation_turn/4` is a managed facade layered above the existing
`rlm_completion/4` fresh-root primitive. The primitive remains unchanged and
usable independently. Cold history is exposed through a trusted lazy
`rlm_context` adapter rather than copied into a `terms/1` payload on every turn.
*/

:- use_module(library(option)).
:- use_module(library(uuid)).
:- use_module(rlm_chain_schema,
              [ message_normalize/2 ]).
:- use_module(rlm_completion, []).
:- use_module(rlm_context,
              [ context_adapter_register/5,
                context_register_adapter/4,
                context_delete/2
              ]).
:- use_module(rlm_context_budget).
:- use_module(rlm_conversation_persist).

:- dynamic conversation_memory_store/1.
:- dynamic conversation_memory_header/4.
:- dynamic conversation_memory_message/4.

rlm_conversation_ready :-
    rlm_context_budget:rlm_context_budget_ready,
    ensure_conversation_context_adapter.

/* -------------------------------------------------------------------------
 * Store lifecycle
 * ---------------------------------------------------------------------- */

conversation_store_open(Spec, Outcome) :-
    conversation_outcome(store_open,
                         conversation_store_open_(Spec),
                         Outcome).

conversation_store_open_(memory, Store) :-
    !,
    uuid(UUID, [version(4)]),
    atom_concat(conversation_store_, UUID, Id),
    with_mutex(rlm_conversation_memory,
               assertz(conversation_memory_store(Id))),
    Store = conversation_store(memory, Id).
conversation_store_open_(persist(File0), Store) :-
    !,
    require_text(File0, File),
    conversation_persist_open(File),
    Store = conversation_store(persist, File).
conversation_store_open_(Spec, _) :-
    throw(conversation_fault(invalid_store_spec(Spec))).

conversation_store_close(Store, Outcome) :-
    catch(( conversation_store_close_(Store),
            Outcome = ok(closed)
          ),
          Exception,
          conversation_exception(store_close, Exception, Outcome)).

conversation_store_close_(conversation_store(memory, Id)) :-
    !,
    with_mutex(rlm_conversation_memory,
               ( retractall(conversation_memory_message(Id, _, _, _)),
                 retractall(conversation_memory_header(Id, _, _, _)),
                 retractall(conversation_memory_store(Id)) )).
conversation_store_close_(conversation_store(persist, _)) :-
    !,
    conversation_persist_close.
conversation_store_close_(Store) :-
    throw(conversation_fault(invalid_store(Store))).

/* -------------------------------------------------------------------------
 * Conversation identity and append-only transcript
 * ---------------------------------------------------------------------- */

conversation_create(Store, Options, Outcome) :-
    conversation_outcome(create,
                         conversation_create_(Store, Options),
                         Outcome).

conversation_create_(Store, Options, Conversation) :-
    require_store(Store),
    require_options(Options),
    conversation_id(Options, Id),
    option(metadata(Metadata), Options, conversation_metadata{}),
    require_ground(Metadata, metadata),
    get_time(CreatedAt),
    backend_create(Store, Id, CreatedAt, Metadata),
    Conversation = conversation_ref{store:Store,
                                    id:Id,
                                    created_at:CreatedAt,
                                    metadata:Metadata}.

conversation_open(Store, Id0, Outcome) :-
    conversation_outcome(open,
                         conversation_open_(Store, Id0),
                         Outcome).

conversation_open_(Store, Id0, Conversation) :-
    require_store(Store),
    normalize_name(Id0, Id),
    (   backend_header(Store, Id, CreatedAt, Metadata)
    ->  Conversation = conversation_ref{store:Store,
                                        id:Id,
                                        created_at:CreatedAt,
                                        metadata:Metadata}
    ;   throw(conversation_fault(not_found(Id)))
    ).

conversation_list(Store, Options, Outcome) :-
    conversation_outcome(list,
                         conversation_list_(Store, Options),
                         Outcome).

conversation_list_(Store, Options, Conversations) :-
    require_store(Store),
    require_options(Options),
    backend_headers(Store, Headers),
    maplist(header_conversation(Store), Headers, Ascending),
    option(order(Order), Options, desc),
    order_conversations(Order, Ascending, Ordered),
    option(limit(Limit), Options, all),
    apply_limit(Limit, Ordered, Conversations).

header_conversation(Store, Header, Conversation) :-
    Conversation = conversation_ref{store:Store,
                                    id:Header.id,
                                    created_at:Header.created_at,
                                    metadata:Header.metadata}.

order_conversations(asc, Conversations, Conversations) :- !.
order_conversations(desc, Conversations, Ordered) :-
    !,
    reverse(Conversations, Ordered).
order_conversations(Order, _, _) :-
    throw(conversation_fault(invalid_conversation_order(Order))).

conversation_append(Conversation, Message0, Outcome) :-
    conversation_outcome(append,
                         conversation_append_(Conversation, Message0),
                         Outcome).

conversation_append_(Conversation, Message0, Record) :-
    require_conversation(Conversation, Store, Id),
    message_normalize(Message0, MessageOutcome),
    require_normalized_message(MessageOutcome, Message),
    get_time(CreatedAt),
    Base = conversation_message{conversation_id:Id,
                                role:Message.role,
                                content:Message.content,
                                message:Message,
                                created_at:CreatedAt},
    backend_append(Store, Id, Base, Record).

conversation_message(Conversation, Sequence, Outcome) :-
    conversation_outcome(message,
                         conversation_message_(Conversation, Sequence),
                         Outcome).

conversation_message_(Conversation, Sequence, Message) :-
    require_conversation(Conversation, Store, Id),
    require_positive_integer(Sequence, sequence),
    (   backend_get(Store, Id, Sequence, Message)
    ->  true
    ;   throw(conversation_fault(message_not_found(Id, Sequence)))
    ).

conversation_messages(Conversation, Selector, Options, Outcome) :-
    conversation_outcome(messages,
                         conversation_messages_(Conversation,
                                                Selector,
                                                Options),
                         Outcome).

conversation_messages_(Conversation, Selector, Options, Messages) :-
    require_conversation(Conversation, Store, Id),
    require_options(Options),
    backend_list(Store, Id, All),
    select_messages(Selector, All, Selected0),
    option(limit(Limit), Options, all),
    apply_limit(Limit, Selected0, Messages).

conversation_search(Conversation, Query0, Options, Outcome) :-
    conversation_outcome(search,
                         conversation_search_(Conversation,
                                              Query0,
                                              Options),
                         Outcome).

conversation_search_(Conversation, Query0, Options, Matches) :-
    require_text(Query0, Query),
    require_options(Options),
    option(case_sensitive(CaseSensitive), Options, false),
    require_boolean(CaseSensitive, case_sensitive),
    option(max_results(MaxResults), Options, 32),
    require_positive_integer(MaxResults, max_results),
    conversation_messages_(Conversation, all, [], Messages),
    normalize_search_text(CaseSensitive, Query, Needle),
    include(message_matches(CaseSensitive, Needle), Messages, Matches0),
    take_first(MaxResults, Matches0, Matches).

conversation_stats(Conversation, Outcome) :-
    conversation_outcome(stats,
                         conversation_stats_(Conversation),
                         Outcome).

conversation_stats_(Conversation, Stats) :-
    require_conversation(Conversation, _, Id),
    conversation_messages_(Conversation, all, [], Messages),
    length(Messages, MessageCount),
    role_count(Messages, user, UserCount),
    role_count(Messages, assistant, AssistantCount),
    role_count(Messages, tool, ToolCount),
    role_count(Messages, system, SystemCount),
    Stats = conversation_stats{conversation_id:Id,
                               messages:MessageCount,
                               user_messages:UserCount,
                               assistant_messages:AssistantCount,
                               tool_messages:ToolCount,
                               system_messages:SystemCount}.

conversation_export(Conversation, term, Outcome) :-
    !,
    conversation_outcome(export,
                         conversation_export_term(Conversation),
                         Outcome).
conversation_export(_, Format, Outcome) :-
    conversation_exception(export,
                           conversation_fault(unsupported_export_format(Format)),
                           Outcome).

conversation_export_term(Conversation, Export) :-
    require_conversation(Conversation, _, Id),
    conversation_messages_(Conversation, all, [], Messages),
    Export = conversation_export{conversation:Conversation,
                                 conversation_id:Id,
                                 messages:Messages}.

/* -------------------------------------------------------------------------
 * Bounded provider-visible context projection
 * ---------------------------------------------------------------------- */

conversation_context_pack(Conversation, Options, Outcome) :-
    conversation_outcome(context_pack,
                         conversation_context_pack_(Conversation, Options),
                         Outcome).

conversation_context_pack_(Conversation, Options, Pack) :-
    require_options(Options),
    option(policy(PolicyInput), Options, []),
    context_policy(PolicyInput, PolicyOutcome),
    require_budget_outcome(PolicyOutcome, Policy),
    option(token_options(TokenOptions), Options, []),
    require_options(TokenOptions),
    option(visible_sections(SectionSpecs), Options, []),
    require_list(SectionSpecs, visible_sections),
    compile_sections(SectionSpecs, TokenOptions, Sections),
    option(context_units(ExtraUnits), Options, []),
    require_list(ExtraUnits, context_units),
    covered_source_refs(ExtraUnits, CoveredRefs),
    conversation_messages_(Conversation, all, [], Messages),
    messages_context_units(Messages,
                           Policy.min_recent_turns,
                           CoveredRefs,
                           TokenOptions,
                           MessageUnits),
    append(MessageUnits, ExtraUnits, Units),
    context_pack(Units, Sections, Policy, PackOutcome),
    require_budget_outcome(PackOutcome, BudgetPack),
    Pack = conversation_context_pack{conversation_id:Conversation.id,
                                     selected:BudgetPack.selected,
                                     policy:BudgetPack.policy,
                                     ledger:BudgetPack.ledger,
                                     utility:BudgetPack.utility}.

conversation_token_ledger(Conversation, Options, Outcome) :-
    conversation_outcome(token_ledger,
                         conversation_token_ledger_(Conversation, Options),
                         Outcome).

conversation_token_ledger_(Conversation, Options, Ledger) :-
    conversation_context_pack_(Conversation, Options, Pack),
    Ledger = Pack.ledger.

compile_sections([], _, []).
compile_sections([Spec|Specs], TokenOptions, [Section|Sections]) :-
    compile_section(Spec, TokenOptions, Section),
    compile_sections(Specs, TokenOptions, Sections).

compile_section(section(Name, Visibility, Text), TokenOptions, Section) :-
    !,
    context_section(Name,
                    Visibility,
                    Text,
                    TokenOptions,
                    SectionOutcome),
    require_budget_outcome(SectionOutcome, Section).
compile_section(Section, _, Section) :-
    is_dict(Section),
    !.
compile_section(Spec, _, _) :-
    throw(conversation_fault(invalid_visible_section(Spec))).

covered_source_refs(Units, Refs) :-
    findall(Ref,
            ( member(Unit, Units),
              is_dict(Unit),
              get_dict(variants, Unit, Variants),
              member(Variant, Variants),
              is_dict(Variant),
              get_dict(value, Variant, Value),
              is_dict(Value),
              get_dict(source_refs, Value, SourceRefs),
              member(Ref, SourceRefs) ),
            Refs0),
    sort(Refs0, Refs).

messages_context_units(Messages,
                       MinRecent,
                       CoveredRefs,
                       TokenOptions,
                       Units) :-
    length(Messages, Count),
    MandatoryStart is max(1, Count-MinRecent+1),
    messages_context_units(Messages,
                           1,
                           MandatoryStart,
                           CoveredRefs,
                           TokenOptions,
                           Units).

messages_context_units([], _, _, _, _, []).
messages_context_units([Message|Messages],
                       Position,
                       MandatoryStart,
                       CoveredRefs,
                       TokenOptions,
                       Units) :-
    (   Position < MandatoryStart,
        memberchk(Message.ref, CoveredRefs)
    ->  Units = Rest
    ;   message_context_unit(Message,
                             Position,
                             MandatoryStart,
                             TokenOptions,
                             Unit),
        Units = [Unit|Rest]
    ),
    Next is Position+1,
    messages_context_units(Messages,
                           Next,
                           MandatoryStart,
                           CoveredRefs,
                           TokenOptions,
                           Rest).

message_context_unit(Message,
                     Position,
                     MandatoryStart,
                     TokenOptions,
                     Unit) :-
    render_message(Message, Rendered),
    token_count_text(Rendered, TokenOptions, TokenOutcome),
    require_budget_outcome(TokenOutcome, TokenCount),
    (   Position >= MandatoryStart
    ->  Mandatory = true,
        Utility is 1000000+Message.sequence
    ;   Mandatory = false,
        Utility is 1000+Message.sequence
    ),
    format(atom(UnitId), 'conversation_message_~d', [Message.sequence]),
    Variant = context_variant{kind:verbatim,
                              tokens:TokenCount.tokens,
                              utility:Utility,
                              value:Message},
    Unit = context_unit{id:UnitId,
                        section:conversation,
                        mandatory:Mandatory,
                        variants:[Variant]}.

/* -------------------------------------------------------------------------
 * Lazy cold-history adapter
 * ---------------------------------------------------------------------- */

conversation_cold_context(Conversation, Options, Outcome) :-
    conversation_outcome(cold_context,
                         conversation_cold_context_(Conversation, Options),
                         Outcome).

conversation_cold_context_(Conversation, Options, Ref) :-
    require_conversation(Conversation, _, _),
    require_options(Options),
    ensure_conversation_context_adapter,
    context_register_adapter(conversation,
                             Conversation,
                             Options,
                             ContextOutcome),
    require_context_outcome(ContextOutcome, Ref).

ensure_conversation_context_adapter :-
    conversation_context_capabilities(Capabilities),
    context_adapter_register(
        conversation,
        Capabilities,
        rlm_conversation:conversation_context_metadata,
        rlm_conversation:conversation_context_operation,
        Outcome),
    require_context_outcome(Outcome, _).

conversation_context_capabilities(
    capabilities{source_kinds:[conversation],
                 operations:[peek, slice, search],
                 persistent:external,
                 filesystem:false,
                 network:false}).

conversation_context_metadata(Conversation, Metadata) :-
    conversation_stats_(Conversation, Stats),
    conversation_messages_(Conversation, recent(1), [], Recent),
    latest_sequence(Recent, Revision),
    conversation_store_kind(Conversation.store, StoreKind),
    Metadata = conversation_source{kind:conversation,
                                   bytes:unknown,
                                   items:Stats.messages,
                                   conversation_id:Conversation.id,
                                   source_revision:Revision,
                                   store_backend:StoreKind}.

latest_sequence([], 0).
latest_sequence([Message], Message.sequence).

conversation_store_kind(conversation_store(memory, _), memory) :- !.
conversation_store_kind(conversation_store(persist, _), persist) :- !.
conversation_store_kind(_, unknown).

conversation_context_operation(peek(head(Count)),
                               Conversation,
                               Limits,
                               Work) :-
    !,
    require_nonnegative_integer(Count, peek_count),
    conversation_messages_(Conversation, all, [], Messages),
    Effective is min(Count, Limits.max_results),
    take_first(Effective, Messages, Selected),
    messages_work(Selected, false, Work0),
    length(Messages, Total),
    length(Selected, Returned),
    bool_value([Count > Limits.max_results,
                Returned < min(Count, Total)],
               Truncated),
    put_dict(truncated, Work0, Truncated, Work).
conversation_context_operation(peek(tail(Count)),
                               Conversation,
                               Limits,
                               Work) :-
    !,
    require_nonnegative_integer(Count, peek_count),
    Effective is min(Count, Limits.max_results),
    conversation_messages_(Conversation,
                           recent(Effective),
                           [],
                           Selected),
    messages_work(Selected, false, Work0),
    conversation_stats_(Conversation, Stats),
    length(Selected, Returned),
    bool_value([Count > Limits.max_results,
                Returned < min(Count, Stats.messages)],
               Truncated),
    put_dict(truncated, Work0, Truncated, Work).
conversation_context_operation(peek(item(Index)),
                               Conversation,
                               _,
                               Work) :-
    !,
    require_nonnegative_integer(Index, item_index),
    Sequence is Index+1,
    (   conversation_message_(Conversation, Sequence, Message)
    ->  message_view(Message, View),
        view_utf8_size(View, Bytes),
        Work = work{value:View,
                    bytes_inspected:Bytes,
                    items_inspected:1,
                    truncated:false}
    ;   throw(context_fault(out_of_range(Index)))
    ).
conversation_context_operation(slice(Start, Length),
                               Conversation,
                               Limits,
                               Work) :-
    !,
    require_nonnegative_integer(Start, slice_start),
    require_nonnegative_integer(Length, slice_length),
    conversation_stats_(Conversation, Stats),
    (   Start =< Stats.messages
    ->  true
    ;   throw(context_fault(out_of_range(Start)))
    ),
    EffectiveLength is min(Length, Limits.max_results),
    StartSequence is Start+1,
    EndSequence is min(Stats.messages, Start+EffectiveLength),
    (   EffectiveLength =:= 0
    ->  Selected = []
    ;   conversation_messages_(Conversation,
                               range(StartSequence, EndSequence),
                               [],
                               Selected)
    ),
    messages_work(Selected, false, Work0),
    Available is max(0, Stats.messages-Start),
    length(Selected, Returned),
    Target is min(Length, Available),
    bool_value([Length > Limits.max_results,
                Returned < Target],
               Truncated),
    put_dict(truncated, Work0, Truncated, Work).
conversation_context_operation(search(Pattern),
                               Conversation,
                               Limits,
                               Work) :-
    !,
    conversation_messages_(Conversation, all, [], Messages),
    search_conversation_messages(Messages,
                                 Pattern,
                                 Limits,
                                 0,
                                 0,
                                 0,
                                 [],
                                 RevMatches,
                                 Bytes,
                                 Items,
                                 Truncated),
    reverse(RevMatches, Matches),
    Work = work{value:Matches,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated}.
conversation_context_operation(Operation, _, _, _) :-
    throw(context_fault(unsupported_operation(Operation))).

messages_work(Messages, Truncated,
              work{value:Views,
                   bytes_inspected:Bytes,
                   items_inspected:Items,
                   truncated:Truncated}) :-
    maplist(message_view, Messages, Views),
    maplist(view_utf8_size, Views, Sizes),
    sum_list(Sizes, Bytes),
    length(Views, Items).

message_view(Message,
             conversation_message_view{sequence:Message.sequence,
                                       ref:Message.ref,
                                       role:Message.role,
                                       content:Message.content}).

search_conversation_messages([], _, _, Index, Bytes, _, Matches, Matches,
                             Bytes, Index, false) :-
    !.
search_conversation_messages(Remaining,
                             _,
                             Limits,
                             Index,
                             Bytes,
                             OutBytes,
                             Matches,
                             Matches,
                             Bytes,
                             Index,
                             true) :-
    length(Matches, Count),
    (Count >= Limits.max_results ; OutBytes >= Limits.max_bytes),
    Remaining \== [],
    !.
search_conversation_messages([Message|Messages],
                             Pattern,
                             Limits,
                             Index0,
                             Bytes0,
                             OutBytes0,
                             Matches0,
                             Matches,
                             Bytes,
                             Items,
                             Truncated) :-
    render_message(Message, Text),
    utf8_text_size(Text, InspectedBytes),
    Bytes1 is Bytes0+InspectedBytes,
    Index1 is Index0+1,
    (   sub_string(Text, _, _, _, Pattern)
    ->  message_match(Message, Match),
        view_utf8_size(Match, MatchBytes),
        NextOutBytes is OutBytes0+MatchBytes,
        (   NextOutBytes =< Limits.max_bytes
        ->  search_conversation_messages(Messages,
                                         Pattern,
                                         Limits,
                                         Index1,
                                         Bytes1,
                                         NextOutBytes,
                                         [Match|Matches0],
                                         Matches,
                                         Bytes,
                                         Items,
                                         Truncated)
        ;   Matches = Matches0,
            Bytes = Bytes1,
            Items = Index1,
            Truncated = true
        )
    ;   search_conversation_messages(Messages,
                                     Pattern,
                                     Limits,
                                     Index1,
                                     Bytes1,
                                     OutBytes0,
                                     Matches0,
                                     Matches,
                                     Bytes,
                                     Items,
                                     Truncated)
    ).

message_match(Message,
              conversation_match{index:Index,
                                 sequence:Message.sequence,
                                 ref:Message.ref,
                                 role:Message.role,
                                 content:Message.content}) :-
    Index is Message.sequence-1.

view_utf8_size(Value, Bytes) :-
    term_string(Value, Text, [quoted(true), numbervars(true)]),
    utf8_text_size(Text, Bytes).

utf8_text_size(Text, Bytes) :-
    string_bytes(Text, Octets, utf8),
    length(Octets, Bytes).

bool_value(Conditions, true) :-
    member(Condition, Conditions),
    call(Condition),
    !.
bool_value(_, false).

/* -------------------------------------------------------------------------
 * Managed RLM turn
 * ---------------------------------------------------------------------- */

conversation_turn(Conversation, UserMessage0, Options, Outcome) :-
    conversation_outcome(turn,
                         conversation_turn_(Conversation,
                                            UserMessage0,
                                            Options),
                         Outcome).

conversation_turn_(Conversation, UserMessage0, Options, TurnResult) :-
    require_options(Options),
    message_normalize(UserMessage0, UserOutcome),
    require_normalized_message(UserOutcome, UserMessage),
    (   UserMessage.role == user
    ->  true
    ;   throw(conversation_fault(turn_requires_user_message(UserMessage.role)))
    ),
    conversation_append_(Conversation, UserMessage, UserRecord),
    option(context_options(ContextOptions), Options, []),
    conversation_context_pack_(Conversation, ContextOptions, ContextPack),
    render_selected_context(ContextPack.selected, ActiveContext),
    render_content(UserMessage.content, UserText),
    format(string(Query),
           "Continue this managed conversation. Preserve established context and answer the current user request. The complete historical transcript is available through the opaque context handle; search or slice it only when needed.\n\nActive rolling context:\n~s\n\nCurrent user request:\n~s",
           [ActiveContext, UserText]),
    option(completion_options(CompletionOptions0), Options, []),
    require_options(CompletionOptions0),
    managed_completion_options(Conversation.id,
                               CompletionOptions0,
                               CompletionOptions),
    option(cold_context_options(ColdOptions), Options, []),
    require_options(ColdOptions),
    conversation_cold_context_(Conversation, ColdOptions, ColdRef),
    setup_call_cleanup(
        true,
        rlm_completion:rlm_completion(Query,
                                      ColdRef,
                                      CompletionOptions,
                                      CompletionOutcome),
        context_delete(ColdRef.handle, _)),
    managed_completion_result(CompletionOutcome,
                              Conversation,
                              UserRecord,
                              ContextPack,
                              TurnResult).

managed_completion_options(SessionId, Options0, Options) :-
    (   member(Option, Options0),
        Option = capabilities(_)
    ->  CapabilityOptions = Options0
    ;   managed_provider_name(Options0, ProviderName),
        Capabilities = [rlm,
                        model(ProviderName),
                        context(peek),
                        context(slice),
                        context(search)],
        CapabilityOptions = [capabilities(Capabilities)|Options0]
    ),
    Options = [session_id(SessionId)|CapabilityOptions].

managed_provider_name(Options, Name) :-
    (   member(provider_name(Explicit), Options), atom(Explicit)
    ->  Name = Explicit
    ;   member(provider(provider(Name0, _)), Options), atom(Name0)
    ->  Name = Name0
    ;   Name = openrouter
    ).

managed_completion_result(error(Error), _, UserRecord, ContextPack, _) :-
    throw(conversation_fault(completion_failed(Error,
                                               UserRecord.ref,
                                               ContextPack.ledger))).
managed_completion_result(ok(Completion),
                          Conversation,
                          UserRecord,
                          ContextPack,
                          TurnResult) :-
    completion_value_text(Completion.value, AssistantText),
    conversation_append_(Conversation,
                         message(assistant, AssistantText),
                         AssistantRecord),
    TurnResult = conversation_turn_result{user:UserRecord,
                                          assistant:AssistantRecord,
                                          completion:Completion,
                                          context:ContextPack}.

/* -------------------------------------------------------------------------
 * Selection and rendering helpers
 * ---------------------------------------------------------------------- */

select_messages(all, Messages, Messages) :- !.
select_messages(recent(Count), Messages, Selected) :-
    !,
    require_nonnegative_integer(Count, recent),
    length(Messages, Length),
    Drop is max(0, Length-Count),
    drop_first(Drop, Messages, Selected).
select_messages(range(Start, End), Messages, Selected) :-
    !,
    require_positive_integer(Start, range_start),
    require_positive_integer(End, range_end),
    (   Start =< End
    ->  true
    ;   throw(conversation_fault(invalid_range(Start, End)))
    ),
    include(sequence_between(Start, End), Messages, Selected).
select_messages(before(Sequence), Messages, Selected) :-
    !,
    require_positive_integer(Sequence, before),
    include(sequence_before(Sequence), Messages, Selected).
select_messages(after(Sequence), Messages, Selected) :-
    !,
    require_nonnegative_integer(Sequence, after),
    include(sequence_after(Sequence), Messages, Selected).
select_messages(around(Sequence, Radius), Messages, Selected) :-
    !,
    require_positive_integer(Sequence, around_sequence),
    require_nonnegative_integer(Radius, around_radius),
    Start is max(1, Sequence-Radius),
    End is Sequence+Radius,
    include(sequence_between(Start, End), Messages, Selected).
select_messages(role(Role0), Messages, Selected) :-
    !,
    normalize_name(Role0, Role),
    include(message_role(Role), Messages, Selected).
select_messages(Selector, _, _) :-
    throw(conversation_fault(invalid_selector(Selector))).

sequence_between(Start, End, Message) :-
    Message.sequence >= Start,
    Message.sequence =< End.
sequence_before(Sequence, Message) :- Message.sequence < Sequence.
sequence_after(Sequence, Message) :- Message.sequence > Sequence.
message_role(Role, Message) :- Message.role == Role.

apply_limit(all, Messages, Messages) :- !.
apply_limit(Limit, Messages, Selected) :-
    require_nonnegative_integer(Limit, limit),
    take_first(Limit, Messages, Selected).

take_first(0, _, []) :- !.
take_first(_, [], []) :- !.
take_first(Count, [Item|Items], [Item|Selected]) :-
    Count > 0,
    Next is Count-1,
    take_first(Next, Items, Selected).

drop_first(0, Items, Items) :- !.
drop_first(_, [], []) :- !.
drop_first(Count, [_|Items], Rest) :-
    Count > 0,
    Next is Count-1,
    drop_first(Next, Items, Rest).

message_matches(CaseSensitive, Needle, Message) :-
    render_message(Message, Text),
    normalize_search_text(CaseSensitive, Text, Haystack),
    sub_string(Haystack, _, _, _, Needle).

normalize_search_text(true, Text, Text) :- !.
normalize_search_text(false, Text, Normalized) :-
    string_lower(Text, Normalized).

render_selected_context(Selections, Text) :-
    maplist(render_context_selection, Selections, Rendered),
    atomics_to_string(Rendered, "\n", Text).

render_context_selection(Selection, Text) :-
    (   Selection.section == conversation
    ->  render_message(Selection.value, Text)
    ;   render_context_value(Selection.value, Text)
    ).

render_context_value(Value, Text) :-
    is_dict(Value),
    get_dict(text, Value, Text0),
    !,
    render_content(Text0, Text).
render_context_value(Value, Text) :-
    render_content(Value, Text).

render_message(Message, Text) :-
    render_content(Message.content, Content),
    format(string(Text), '[~d] ~w: ~s',
           [Message.sequence, Message.role, Content]).

render_content(Content, Text) :-
    string(Content),
    !,
    Text = Content.
render_content(Content, Text) :-
    atom(Content),
    !,
    atom_string(Content, Text).
render_content(Content, Text) :-
    with_output_to(string(Text),
                   write_term(Content,
                              [ quoted(true),
                                portray(false),
                                max_depth(12)
                              ])).

completion_value_text(Value, Text) :-
    string(Value),
    !,
    Text = Value.
completion_value_text(Value, Text) :-
    atom(Value),
    !,
    atom_string(Value, Text).
completion_value_text(Value, Text) :-
    with_output_to(string(Text),
                   write_term(Value,
                              [ quoted(true),
                                portray(false),
                                max_depth(20)
                              ])).

role_count(Messages, Role, Count) :-
    include(message_role(Role), Messages, RoleMessages),
    length(RoleMessages, Count).

/* -------------------------------------------------------------------------
 * Backends
 * ---------------------------------------------------------------------- */

backend_create(conversation_store(memory, StoreId),
               Id,
               CreatedAt,
               Metadata) :-
    !,
    with_mutex(rlm_conversation_memory,
               (   conversation_memory_header(StoreId, Id, _, _)
               ->  throw(conversation_fault(conversation_exists(Id)))
               ;   assertz(conversation_memory_header(StoreId,
                                                       Id,
                                                       CreatedAt,
                                                       Metadata))
               )).
backend_create(conversation_store(persist, _),
               Id,
               CreatedAt,
               Metadata) :-
    !,
    conversation_persist_create(Id, CreatedAt, Metadata).

backend_header(conversation_store(memory, StoreId),
               Id,
               CreatedAt,
               Metadata) :-
    !,
    with_mutex(rlm_conversation_memory,
               conversation_memory_header(StoreId,
                                            Id,
                                            CreatedAt,
                                            Metadata)).
backend_header(conversation_store(persist, _),
               Id,
               CreatedAt,
               Metadata) :-
    !,
    conversation_persist_header(Id, CreatedAt, Metadata).

backend_headers(conversation_store(memory, StoreId), Headers) :-
    !,
    with_mutex(rlm_conversation_memory,
               findall(CreatedAt-Id-Metadata,
                       conversation_memory_header(StoreId,
                                                  Id,
                                                  CreatedAt,
                                                  Metadata),
                       Rows0)),
    keysort(Rows0, Rows),
    findall(conversation_header{id:Id,
                                created_at:CreatedAt,
                                metadata:Metadata},
            member(CreatedAt-Id-Metadata, Rows),
            Headers).
backend_headers(conversation_store(persist, _), Headers) :-
    !,
    conversation_persist_headers(Headers).

backend_append(conversation_store(memory, StoreId), Id, Base, Message) :-
    !,
    with_mutex(rlm_conversation_memory,
               (   conversation_memory_header(StoreId, Id, _, _)
               ->  findall(Sequence,
                           conversation_memory_message(StoreId,
                                                       Id,
                                                       Sequence,
                                                       _),
                           Sequences),
                   next_sequence(Sequences, Sequence),
                   Ref = conversation_message_ref{conversation_id:Id,
                                                  sequence:Sequence},
                   put_dict(_{ref:Ref, sequence:Sequence},
                            Base,
                            Message),
                   assertz(conversation_memory_message(StoreId,
                                                       Id,
                                                       Sequence,
                                                       Message))
               ;   throw(conversation_fault(not_found(Id)))
               )).
backend_append(conversation_store(persist, _), Id, Base, Message) :-
    !,
    conversation_persist_append(Id, Base, Message).

backend_get(conversation_store(memory, StoreId), Id, Sequence, Message) :-
    !,
    with_mutex(rlm_conversation_memory,
               conversation_memory_message(StoreId,
                                           Id,
                                           Sequence,
                                           Message)).
backend_get(conversation_store(persist, _), Id, Sequence, Message) :-
    !,
    conversation_persist_get(Id, Sequence, Message).

backend_list(conversation_store(memory, StoreId), Id, Messages) :-
    !,
    with_mutex(rlm_conversation_memory,
               findall(Sequence-Message,
                       conversation_memory_message(StoreId,
                                                   Id,
                                                   Sequence,
                                                   Message),
                       Pairs0)),
    keysort(Pairs0, Pairs),
    findall(Message, member(_-Message, Pairs), Messages).
backend_list(conversation_store(persist, _), Id, Messages) :-
    !,
    conversation_persist_list(Id, Messages).

next_sequence([], 1).
next_sequence(Sequences, Sequence) :-
    Sequences \== [],
    max_list(Sequences, Latest),
    Sequence is Latest+1.

/* -------------------------------------------------------------------------
 * Validation and structured outcomes
 * ---------------------------------------------------------------------- */

conversation_id(Options, Id) :-
    (   option(id(Id0), Options)
    ->  normalize_name(Id0, Id)
    ;   uuid(UUID, [version(4)]),
        atom_concat(conversation_, UUID, Id)
    ).

require_store(conversation_store(memory, Id)) :-
    !,
    (   conversation_memory_store(Id)
    ->  true
    ;   throw(conversation_fault(closed_store(conversation_store(memory,
                                                                 Id))))
    ).
require_store(conversation_store(persist, File)) :-
    !,
    require_text(File, _).
require_store(Store) :- throw(conversation_fault(invalid_store(Store))).

require_conversation(Conversation, Store, Id) :-
    (   is_dict(Conversation),
        get_dict(store, Conversation, Store),
        get_dict(id, Conversation, Id)
    ->  require_store(Store),
        (   backend_header(Store, Id, _, _)
        ->  true
        ;   throw(conversation_fault(not_found(Id)))
        )
    ;   throw(conversation_fault(invalid_conversation(Conversation)))
    ).

require_normalized_message(ok(Message), Message) :- !.
require_normalized_message(error(Error), _) :-
    throw(conversation_fault(invalid_message(Error))).

require_budget_outcome(ok(Value), Value) :- !.
require_budget_outcome(error(Error), _) :-
    throw(conversation_fault(context_budget_failed(Error))).

require_context_outcome(ok(Value), Value) :- !.
require_context_outcome(error(Error), _) :-
    throw(conversation_fault(context_adapter_failed(Error))).

conversation_outcome(Phase, Goal, Outcome) :-
    catch(( call(Goal, Value),
            Outcome = ok(Value)
          ),
          Exception,
          conversation_exception(Phase, Exception, Outcome)).

conversation_exception(Phase, conversation_fault(Detail), error(Error)) :-
    !,
    Error = conversation_error{phase:Phase,
                               kind:conversation_error,
                               detail:Detail,
                               message:"conversation operation failed"}.
conversation_exception(Phase, context_fault(Detail), error(Error)) :-
    !,
    Error = conversation_error{phase:Phase,
                               kind:context_error,
                               detail:Detail,
                               message:"conversation context operation failed"}.
conversation_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = conversation_error{phase:Phase,
                               kind:exception,
                               exception:Safe,
                               message:"conversation operation raised an exception"}.

normalize_name(Value, Atom) :- atom(Value), !, Atom = Value.
normalize_name(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
normalize_name(Value, _) :- throw(conversation_fault(expected_name(Value))).

require_text(Value, Text) :- string(Value), !, Text = Value.
require_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
require_text(Value, _) :- throw(conversation_fault(expected_text(Value))).

require_options(Value) :- is_list(Value), !.
require_options(Value) :- throw(conversation_fault(expected_options(Value))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Name) :-
    throw(conversation_fault(expected_list(Name, Value))).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Name) :-
    throw(conversation_fault(non_ground(Name, Value))).

require_boolean(true, _) :- !.
require_boolean(false, _) :- !.
require_boolean(Value, Name) :-
    throw(conversation_fault(expected_boolean(Name, Value))).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Name) :-
    throw(conversation_fault(expected_positive_integer(Name, Value))).

require_nonnegative_integer(Value, _) :- integer(Value), Value >= 0, !.
require_nonnegative_integer(Value, Name) :-
    throw(conversation_fault(expected_nonnegative_integer(Name, Value))).

safe_exception(Exception, Safe) :-
    (   ground(Exception)
    ->  with_output_to(string(Safe),
                       write_term(Exception,
                                  [ quoted(true),
                                    portray(false),
                                    max_depth(10)
                                  ]))
    ;   Safe = "non-ground exception"
    ).
