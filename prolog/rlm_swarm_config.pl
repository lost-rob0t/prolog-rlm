:- module(rlm_swarm_config,
          [ rlm_swarm_config_ready/0,
            swarm_config_schema_version/1,
            swarm_config_default/1,
            swarm_config_field/2,
            swarm_config_normalize/4,
            swarm_config_effective/2,
            swarm_config_redact/2,
            swarm_config_read_file/2,
            swarm_spend_rate_parse/2,
            swarm_guardrail_class/1
          ]).

/** <module> Closed versioned swarm configuration schema and normalizer

The single configuration authority for rlm_swarm (RLM-DESIGN-574-a, slice 1).
One closed, versioned schema, one normalizer with per-field provenance, and
one effective-config contract. `swarm_config{}` is the only configuration
value consumed by the library and by pswarm; rlm_cli's completion budget
default is deliberately NOT reused (research amendment #4: the swarm
lifetime cap default is 0.10 USD, independent of the 0.25 per-run budget).

Normalization is a pure function of (defaults, config file term, CLI
options) — no dynamic predicates, so the effective config is replayable and
hashable. Precedence is CLI over file over defaults; scalars are last-wins
within a layer, guardrail enablement unions across layers (a restriction
must never be silently reduced), and spend-rate windows resolve to the
strictest (minimum USD) quota across layers. Unknown fields, unknown schema
versions, unknown guardrail classes, unknown spend-rate units, non-ground
or multiple config terms, contradictory bounds, and a missing required
`-n` all fail closed via `swarm_config_fault/1` — nothing is clamped.

Guardrail classes are validated syntactically here (bare = `all`, or a
comma list of ground class atoms); the semantic set of recognized classes
is pinned and enforced by slice 9, which also owns the vocabulary table.
*/

:- use_module(rlm_cli_args).
:- use_module(library(lists)).

rlm_swarm_config_ready.

swarm_config_schema_version(1).

swarm_config_default(swarm_config{cap_usd:0.10,
                                  n:none,
                                  min_agents:1,
                                  max_agents:64,
                                  rate:60,
                                  spend_rate:[],
                                  kb:none,
                                  enable_guardrail:[],
                                  web:false,
                                  console:none,
                                  background:false,
                                  daemon:false,
                                  unsupported:[]}).

/* Closed leaf registry. `n` has no default: the population is a
   spend-amplification knob and must be deliberate (resolved vote Q2). */
swarm_config_field(cap_usd,        number_nonnegative).
swarm_config_field(n,              integer_positive).
swarm_config_field(min_agents,     integer_positive).
swarm_config_field(max_agents,     integer_positive).
swarm_config_field(rate,           integer_positive).
swarm_config_field(spend_rate,     spend_rate_text).
swarm_config_field(kb,             text).
swarm_config_field(enable_guardrail, guardrail_text).
swarm_config_field(web,            boolean).
swarm_config_field(console,        text).
swarm_config_field(background,     boolean).
swarm_config_field(daemon,         boolean).

/* Effective config ------------------------------------------------------ */

% Recompute the derived fields of a normalized swarm_config dict: bounds
% coherence (min =< max; required n inside bounds) and unsupported-feature
% markers (resolved vote Q12: --web true parses but the effective config
% records web(false) plus an unsupported_feature marker; a future
% `pswarm run` with web enabled must fail closed on this marker, never
% silently no-op).
swarm_config_effective(Config0, Effective) :-
    check_bounds(Config0),
    derive_unsupported(Config0, Effective).

check_bounds(Config) :-
    Min = Config.min_agents,
    Max = Config.max_agents,
    (   Min =< Max
    ->  true
    ;   throw(swarm_config_fault(contradictory_bounds(min_agents, Max, Min)))
    ),
    (   Config.n == none
    ->  throw(swarm_config_fault(missing_required_field(n)))
    ;   N = Config.n,
        (   N >= Min,
            N =< Max
        ->  true
        ;   throw(swarm_config_fault(n_outside_bounds(N, Min, Max)))
        )
    ).

derive_unsupported(Config0, Effective) :-
    (   Config0.web == true
    ->  put_dict(web, Config0, false, Config1),
        append(Config1.unsupported, [web], Unsupported0),
        sort(Unsupported0, Unsupported),
        put_dict(unsupported, Config1, Unsupported, Effective)
    ;   Effective = Config0
    ).

/* Normalization --------------------------------------------------------- */

% FileInput :: none | file(Path, TermPos, swarm_config(SchemaVersion, Fields)).
% The Path and TermPos (from read_term/3's term_positions) feed the file
% provenance source file(Path, TermPos).
%
% CliOptions :: [cli_field(Field, Value, ArgIndex), ...] where ArgIndex is
% the 0-based position of the flag token in the pswarm argv. Values are the
% typed results of the shared rlm_cli_args validators, except spend-rate and
% guardrail tokens which this normalizer validates through
% swarm_spend_rate_parse/2 and swarm_guardrail_class/1.
%
% Provenance maps every registry field to a source: `default`, or
% file(Path, TermPos), or cli(ArgIndex) for scalar last-wins observability.
% Collection fields (enable_guardrail, spend_rate) map to the sorted list of
% contributing sources.
swarm_config_normalize(FileInput, CliOptions, Effective, Provenance) :-
    swarm_config_default(Default),
    provenance_defaults(Provenance0),
    normalize_file_layer(FileInput, Default, Provenance0,
                         Config1, Provenance1, FileRates),
    normalize_cli_layer(CliOptions, Config1, Provenance1,
                        Config2, Provenance2, CliRates),
    append(FileRates, CliRates, AllRates),
    last_wins_within_layer(AllRates, Resolved),
    strictest_across_layers(Resolved, Merged, Sources),
    sort_rates(Merged, Rates),
    (   Sources == []
    ->  Provenance = Provenance2
    ;   put_dict(spend_rate, Provenance2, Sources, Provenance)
    ),
    put_dict(spend_rate, Config2, Rates, Config3),
    swarm_config_effective(Config3, Effective).

provenance_defaults(Provenance) :-
    findall(Field, swarm_config_field(Field, _Type), Fields),
    provenance_defaults(Fields, swarm_provenance{}, Provenance).

provenance_defaults([], Provenance, Provenance).
provenance_defaults([Field|Fields], Provenance0, Provenance) :-
    put_dict(Field, Provenance0, default, Provenance1),
    provenance_defaults(Fields, Provenance1, Provenance).

normalize_file_layer(none, Config, Provenance, Config, Provenance, []).
normalize_file_layer(file(Path, TermPos, Term), Config0, Provenance0,
                     Config, Provenance, Rates) :-
    (   Term = swarm_config(Version, Fields)
    ->  (   Version == 1
        ->  Source = file(Path, TermPos),
            fold_fields(Fields, Source, file,
                        state(Config0, Provenance0, []),
                        state(Config, Provenance, Rates))
        ;   throw(swarm_config_fault(unsupported_schema_version(Version, 1)))
        )
    ;   throw(swarm_config_fault(invalid_config_term(Term)))
    ).

normalize_cli_layer([], Config, Provenance, Config, Provenance, []).
normalize_cli_layer([cli_field(Name, Raw, Index)|Rest],
                    Config0, Provenance0, Config, Provenance, Rates) :-
    (   atom(Name),
        swarm_config_field(Name, Type)
    ->  field_value(Name, Type, Raw, Value),
        put_entry(Name, Value, cli(Index), cli,
                  state(Config0, Provenance0, []),
                  state(Config1, Provenance1, RatesRev))
    ;   throw(swarm_config_fault(unknown_field(Name)))
    ),
    normalize_cli_layer(Rest, Config1, Provenance1, Config, Provenance, RatesTail),
    append(RatesRev, RatesTail, Rates).

fold_fields([], _, _, State, State).
fold_fields([FieldTerm|Rest], Source, Layer, State0, State) :-
    step_field(FieldTerm, Source, Layer, State0, State1),
    fold_fields(Rest, Source, Layer, State1, State).

step_field(FieldTerm, Source, file, State0, State) :-
    FieldTerm =.. [Name|Args],
    (   Args = [Raw]
    ->  (   atom(Name),
            swarm_config_field(Name, Type)
        ->  field_value(Name, Type, Raw, Value),
            put_entry(Name, Value, Source, file, State0, State)
        ;   throw(swarm_config_fault(unknown_field(Name)))
        )
    ;   throw(swarm_config_fault(invalid_config_field(FieldTerm)))
    ).

% Scalar fields: last occurrence within the layer wins (sequential
% replacement, provenance records the winning occurrence). enable_guardrail:
% union within and across layers — guardrail enablement is a restriction and
% must never be silently reduced. spend_rate: collected per layer and
% resolved after both layers (duplicate window last-wins within a layer,
% strictest minimum USD across layers).
put_entry(spend_rate, Rate, Source, Layer,
          state(Config, Provenance, Rates0),
          state(Config, Provenance,
                [rate_entry{layer:Layer, rate:Rate, source:Source}|Rates0])) :- !.
put_entry(enable_guardrail, Value, Source, _Layer,
          state(Config0, Provenance0, Rates),
          state(Config, Provenance, Rates)) :- !,
    get_dict(enable_guardrail, Config0, Old),
    append(Old, Value, Union0),
    sort(Union0, Union),
    put_dict(enable_guardrail, Config0, Union, Config),
    add_source(enable_guardrail, Source, Provenance0, Provenance).
put_entry(Field, Value, Source, _Layer,
          state(Config0, Provenance0, Rates),
          state(Config, Provenance, Rates)) :-
    put_dict(Field, Config0, Value, Config),
    put_dict(Field, Provenance0, Source, Provenance).

add_source(Field, Source, Provenance0, Provenance) :-
    get_dict(Field, Provenance0, Old),
    (   is_list(Old)
    ->  Old0 = Old
    ;   Old0 = [Old]
    ),
    exclude(=(default), Old0, Kept),
    sort([Source|Kept], Sources),
    put_dict(Field, Provenance0, Sources, Provenance).

/* Typed field validation ------------------------------------------------ */

field_value(Field, number_nonnegative, Raw, Value) :-
    number(Raw),
    !,
    (   Raw >= 0
    ->  Value = Raw
    ;   fault_invalid(Field, Raw)
    ).
field_value(Field, number_nonnegative, Raw, Value) :-
    text_value(Raw, Text),
    !,
    catch(cli_number_arg(Text, Number),
          cli_fault(_),
          fault_invalid(Field, Raw)),
    (   Number >= 0
    ->  Value = Number
    ;   fault_invalid(Field, Raw)
    ).
field_value(Field, integer_positive, Raw, Value) :-
    integer(Raw),
    !,
    (   Raw > 0
    ->  Value = Raw
    ;   fault_invalid(Field, Raw)
    ).
field_value(Field, integer_positive, Raw, Value) :-
    text_value(Raw, Text),
    !,
    catch(cli_positive_integer_arg(Text, Value),
          cli_fault(_),
          fault_invalid(Field, Raw)).
field_value(Field, boolean, Raw, Value) :-
    (   Raw == true
    ->  Value = true
    ;   Raw == false
    ->  Value = false
    ;   fault_invalid(Field, Raw)
    ).
field_value(_, text, Raw, Value) :-
    text_value(Raw, Value),
    !.
field_value(Field, text, Raw, _) :-
    fault_invalid(Field, Raw).
field_value(_, spend_rate_text, Raw, Value) :-
    text_value(Raw, Text),
    !,
    swarm_spend_rate_parse(Text, Value).
field_value(Field, spend_rate_text, Raw, _) :-
    fault_invalid(Field, Raw).
field_value(_, guardrail_text, Raw, Value) :-
    text_value(Raw, _Text),
    !,
    guardrail_parse(Raw, Value).
field_value(Field, guardrail_text, Raw, _) :-
    fault_invalid(Field, Raw).
field_value(Field, _Type, Raw, _) :-
    fault_invalid(Field, Raw).

fault_invalid(Field, Raw) :-
    throw(swarm_config_fault(invalid_field_value(Field, Raw))).

text_value(Raw, Value) :- atom(Raw), !, atom_string(Raw, Value).
text_value(Raw, Raw) :- string(Raw).

/* Spend rates ----------------------------------------------------------- */

% "<usd>/<min|hr|day|week|year>" -> spend_rate{usd, window_minutes}.
% Windows are fixed minute counts: 1/60/1440/10080/525600. The year window
% is a fixed 365 days (525600 minutes); leap-year drift is the documented
% consequence of the resolved vote Q11.
swarm_spend_rate_parse(Text0, spend_rate{usd:USD, window_minutes:Minutes}) :-
    spend_rate_text(Text0, String),
    (   split_string(String, "/", "", [AmountText, UnitText])
    ->  (   unit_minutes(UnitText, Minutes)
        ->  (   catch(number_string(USD, AmountText), _, fail),
                USD >= 0
            ->  true
            ;   throw(swarm_config_fault(malformed_spend_rate(String)))
            )
        ;   throw(swarm_config_fault(unknown_spend_rate_unit(UnitText, String)))
        )
    ;   throw(swarm_config_fault(malformed_spend_rate(String)))
    ).

spend_rate_text(Text, Text) :- string(Text), Text \== "", !.
spend_rate_text(Text, String) :- atom(Text), !, atom_string(Text, String).
spend_rate_text(Raw, _) :-
    throw(swarm_config_fault(malformed_spend_rate(Raw))).

unit_minutes("min", 1).
unit_minutes("hr", 60).
unit_minutes("day", 1440).
unit_minutes("week", 10080).
unit_minutes("year", 525600).

last_wins_within_layer(Entries, Resolved) :-
    last_wins_within_layer(Entries, [], Resolved).

last_wins_within_layer([], Resolved, Resolved) :- !.
last_wins_within_layer([Entry|Rest], Acc0, Resolved) :-
    get_dict(layer, Entry, Layer),
    get_dict(rate, Entry, Rate),
    get_dict(window_minutes, Rate, Window),
    remove_layer_window(Acc0, Layer, Window, Acc1),
    last_wins_within_layer(Rest, [Entry|Acc1], Resolved).

remove_layer_window([], _, _, []).
remove_layer_window([Entry|Entries], Layer, Window, Out) :-
    (   get_dict(layer, Entry, Layer),
        get_dict(window_minutes, Entry.rate, Window)
    ->  Out = Entries
    ;   Out = [Entry|OutRest],
        remove_layer_window(Entries, Layer, Window, OutRest)
    ).

strictest_across_layers([], [], []) :- !.
strictest_across_layers(Resolved, Merged, Sources) :-
    findall(Window,
            (   member(Entry, Resolved),
                get_dict(rate, Entry, Rate),
                get_dict(window_minutes, Rate, Window)
            ),
            Windows0),
    sort(Windows0, Windows),
    strictest_windows(Windows, Resolved, Merged, SourcesAll),
    sort(SourcesAll, Sources).

strictest_windows([], _, [], []).
strictest_windows([Window|Rest], Entries,
                  [spend_rate{usd:USD, window_minutes:Window}|Rates],
                  Sources0) :-
    layer_usd(Entries, file, Window, FileUsd, FileSource),
    layer_usd(Entries, cli, Window, CliUsd, CliSource),
    choose_strictest(FileUsd, FileSource, CliUsd, CliSource, USD, WindowSources),
    strictest_windows(Rest, Entries, Rates, RestSources),
    append(WindowSources, RestSources, Sources0).

layer_usd(Entries, Layer, Window, Usd, Source) :-
    member(Entry, Entries),
    get_dict(layer, Entry, EntryLayer),
    EntryLayer == Layer,
    get_dict(rate, Entry, Rate),
    get_dict(usd, Rate, Usd),
    get_dict(window_minutes, Rate, Window),
    get_dict(source, Entry, Source),
    !.
layer_usd(_, _, _, none, none).

choose_strictest(none, _, CliUsd, CliSource, CliUsd, [CliSource]) :- !.
choose_strictest(FileUsd, FileSource, none, _, FileUsd, [FileSource]) :- !.
choose_strictest(FileUsd, FileSource, CliUsd, CliSource, USD,
                 [FileSource, CliSource]) :-
    USD is min(FileUsd, CliUsd).

sort_rates(Rates0, Rates) :-
    rate_pairs(Rates0, Pairs0),
    keysort(Pairs0, Pairs),
    rate_pairs(Rates, Pairs).

rate_pairs([], []).
rate_pairs([Rate|Rates], [Window-Rate|Pairs]) :-
    get_dict(window_minutes, Rate, Window),
    rate_pairs(Rates, Pairs).

/* Guardrail classes ----------------------------------------------------- */

% Closed SYNTACTIC guardrail vocabulary: `all`, or a comma list of ground
% class atoms over [A-Za-z0-9_-]. The semantic set of recognized classes is
% pinned and enforced by slice 9; this predicate only decides whether a
% spec is well-formed, so parsing never depends on slice 9's table.
swarm_guardrail_class(all) :- !.
swarm_guardrail_class(Spec) :-
    text_value(Spec, Text),
    split_string(Text, ",", "", Elements),
    maplist(guardrail_element, Elements).

guardrail_element(ElementText) :-
    atom_string(Element, ElementText),
    Element \== '',
    atom_chars(Element, Chars),
    Chars \= [],
    maplist(guardrail_char, Chars).

guardrail_char(Char) :-
    (   char_type(Char, alnum)
    ;   Char == '-'
    ;   Char == '_'
    ),
    !.

guardrail_parse(Raw, [all]) :-
    text_value(Raw, "all"),
    !.
guardrail_parse(Raw, List) :-
    text_value(Raw, Text),
    swarm_guardrail_class(Text),
    !,
    split_string(Text, ",", "", Elements),
    maplist(atom_string, List0, Elements),
    sort(List0, List).
guardrail_parse(Raw, _) :-
    throw(swarm_config_fault(invalid_guardrail_class(Raw))).

/* Redaction ------------------------------------------------------------- */

% Emission view of the effective config: closed-schema projection (unknown
% keys fail closed) with atom values normalized to strings so JSON emission
% through rlm_trace is stable. Schema v1 carries no credential-bearing
% fields (kb/console are type-validated paths only); any future
% credential-bearing field must be registered here explicitly.
swarm_config_redact(Config, Redacted) :-
    is_dict(Config),
    dict_pairs(Config, Tag, Pairs),
    (   Tag == swarm_config
    ->  maplist(redact_pair, Pairs, RedactedPairs),
        dict_pairs(Redacted, Tag, RedactedPairs)
    ;   throw(swarm_config_fault(invalid_config_dict(Tag)))
    ).

redact_pair(Key-Value0, Key-Value) :-
    (   Key == unsupported
    ->  true
    ;   swarm_config_field(Key, _Type)
    ->  true
    ;   throw(swarm_config_fault(unknown_field(Key)))
    ),
    redact_value(Value0, Value).

redact_value(Value, Value) :- ( Value == true ; Value == false ), !.
redact_value(Value0, Value) :- atom(Value0), !, atom_string(Value0, Value).
redact_value(Value, Value).

/* Config file reading --------------------------------------------------- */

% Read the operator-owned config file: EXACTLY one ground
% swarm_config(SchemaVersion, [Field(Value), ...]) term, read with
% read_term/3 (never consult/1). Zero terms, more than one term, or a
% non-ground term fail closed. The swarm_config(SchemaVersion, Fields)
% shape and the schema version are validated by swarm_config_normalize/4.
swarm_config_read_file(Path0, file(Path, TermPos, Term)) :-
    ( atom(Path0) -> Path = Path0 ; atom_string(Path, Path0) ),
    setup_call_cleanup(
        open(Path, read, Stream, [encoding(utf8)]),
        read_single_config_term(Stream, Term, TermPos),
        close(Stream)).

read_single_config_term(Stream, Term, TermPos) :-
    catch(read_term(Stream, Term0, [subterm_positions(TermPos)]),
          error(SyntaxError, _),
          throw(swarm_config_fault(malformed_config_term(SyntaxError)))),
    (   Term0 == end_of_file
    ->  throw(swarm_config_fault(empty_config_file))
    ;   read_term(Stream, Extra, []),
        Extra \== end_of_file
    ->  throw(swarm_config_fault(multiple_config_terms))
    ;   true
    ),
    (   ground(Term0)
    ->  Term = Term0
    ;   throw(swarm_config_fault(non_ground_config_term))
    ).
