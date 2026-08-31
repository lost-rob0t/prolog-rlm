:- begin_tests(live_compiler_cache_openrouter).

:- use_module(library(filesex)).
:- use_module(library(http/http_open)).
:- use_module(library(http/json)).
:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_context').
:- use_module('../prolog/rlm_direct').
:- use_module('../prolog/rlm_skill').
:- use_module('../prolog/rlm_tool').

:- dynamic cache_test_directory/1.
:- dynamic cache_generation/4.
:- at_halt(print_cache_evidence).
:- prolog_load_context(directory, TestDirectory),
   assertz(cache_test_directory(TestDirectory)).

test(fifteen_fresh_explicit_all_tools_compilations_report_provider_cache_hits) :-
    require_cache_environment(Model, Key),
    cache_skill_catalog(SkillCatalog),
    tool_registry_create(ToolRegistry),
    context_register(text("stable opaque cache context"), [], ok(ContextRef)),
    setup_call_cleanup(
        register_cache_tool(ToolRegistry),
        run_cache_turns(1, 15, Model, Key, SkillCatalog, ToolRegistry,
                        ContextRef, CacheSamples),
        ( context_delete(ContextRef.handle, _),
          tool_registry_destroy(ToolRegistry)
        )),
    CacheSamples = [_Cold|WarmSamples],
    include(cache_hit, WarmSamples, Hits),
    length(Hits, HitCount),
    length(WarmSamples, WarmCount),
    HitPercent is (HitCount*100.0)/WarmCount,
    % The runtime-controlled invariant is prefix stability: a churning
    % prefix collapses the hit rate toward zero. Provider-side upstream
    % routing (each instance holding its own cache) adds periodic misses
    % outside runtime control (measured 67%-100% across runs on the pinned
    % glm model), so a majority of warm turns with a real hit floor is the
    % honest bar.
    assertion(HitPercent >= 50.0),
    assertion(HitCount >= 5),
    format(user_error, 'compiler_cache_warm_requests: ~d~n', [WarmCount]),
    format(user_error, 'compiler_cache_hit_requests: ~d~n', [HitCount]),
    format(user_error, 'compiler_cache_hit_percent: ~2f~n', [HitPercent]).

run_cache_turns(Turn, Last, _, _, _, _, _, []) :-
    Turn > Last,
    !.
run_cache_turns(Turn, Last, Model, Key, SkillCatalog, ToolRegistry,
                ContextRef, [Sample|Samples]) :-
    cache_query(Turn, Query, Expected),
    openrouter_provider(Model, Provider),
    all_mode_capabilities(Capabilities),
    Options = [provider(Provider),provider_name(openrouter),
               tool_registry(ToolRegistry),
               skill_catalog(SkillCatalog),explicit_skills([tdd]),
               prompt_compile_mode(all_tools),
               capabilities(Capabilities),
               budget(_{max_model_calls:1,max_tool_calls:0,
                        max_context_ops:0,max_total_tokens:8192,
                        max_cost_usd:0.25,max_output_bytes:1024,
                        time_limit:90.0}),
               planner_max_tokens(256),temperature(0),
               reasoning_effort(minimal)],
    rlm_direct(Query, ContextRef, Options, Outcome),
    require_cache_completion(Outcome, Expected, Result),
    GenerationId = Result.response.response_id,
    generation_cache_sample(Key, GenerationId, Sample),
    assertz(cache_generation(Turn,GenerationId,Sample.cached_tokens,
                             Sample.response_cache_hit)),
    Next is Turn+1,
    run_cache_turns(Next, Last, Model, Key, SkillCatalog, ToolRegistry,
                    ContextRef, Samples).

all_mode_capabilities([
    context(peek),context(slice),context(search),tool(cache_probe),
    spec(catalog),spec(normalize),spec(freeze),spec(observe),spec(verify),
    plan(execute)
]).

cache_query(Turn, Query, Expected) :-
    length(Codes, 6000),
    maplist(=(0'a), Codes),
    string_codes(Prefix, Codes),
    format(string(Expected), "CACHE_OK_~d", [Turn]),
    format(string(Query),
           "Stable cache-prefix probe. Do not call tools. The following padding is intentional and invariant across compiler reloads:\n~s\nTurn suffix ~d. Reply only ~s",
           [Prefix,Turn,Expected]).

cache_skill_catalog(Catalog) :-
    cache_test_directory(TestDirectory),
    directory_file_path(TestDirectory, 'fixtures/skills', Root),
    skill_catalog_load([skill_root(cache_test,Root)], [], ok(Catalog)).

register_cache_tool(Registry) :-
    Schema = tool_schema{
                 name:cache_probe,
                 description:"Stable read-only schema used only to test provider prefix caching",
                 capability:tool(cache_probe),effect:read,
                 arguments:_{type:object,properties:_{},required:[],
                             additional_properties:false},
                 result:_{type:string},
                 limits:_{time_limit:1.0,max_output_bytes:128}},
    tool_register(Registry, Schema,
                  plunit_live_compiler_cache_openrouter:cache_probe_handler,
                  ok(_)).

cache_probe_handler(_, "unused").

require_cache_completion(ok(Result), Expected, Result) :-
    !,
    assertion(Result.value == Expected),
    assertion(Result.turns =:= 1),
    assertion(Result.tool_calls =:= 0),
    assertion(Result.context_calls =:= 0).
require_cache_completion(error(Error), _, _) :-
    throw(error(cache_completion_failed(Error),_)).

generation_cache_sample(Key, GenerationId, Sample) :-
    % OpenRouter's generation endpoint is eventually consistent: a record
    % may 404 for tens of seconds right after a fast completion. Retry
    % briefly; the sampled fields are unchanged.
    generation_cache_sample_(Key, GenerationId, 15, Sample).

generation_cache_sample_(Key, GenerationId, AttemptsLeft, Sample) :-
    fetch_generation_sample(Key, GenerationId, Status, Sample0),
    (   Status == 200
    ->  Sample = Sample0
    ;   Status == 404,
        AttemptsLeft > 1
    ->  sleep(2),
        AttemptsLeft1 is AttemptsLeft - 1,
        generation_cache_sample_(Key, GenerationId, AttemptsLeft1, Sample)
    ;   throw(error(generation_metadata_failed(GenerationId,Status),_))
    ).

fetch_generation_sample(Key, GenerationId, Status, Sample) :-
    format(string(URL),
           "https://openrouter.ai/api/v1/generation?id=~s",
           [GenerationId]),
    format(string(Authorization), "Bearer ~s", [Key]),
    setup_call_cleanup(
        http_open(URL, Stream,
                  [request_header('Authorization'=Authorization),
                   request_header('User-Agent'='prolog-rlm/0.1'),
                   status_code(Status),timeout(30)]),
        (   Status == 200
        ->  read_generation_sample(Stream, GenerationId, Sample)
        ;   Sample = none
        ),
        close(Stream)).

read_generation_sample(Stream, _, Sample) :-
    json_read_dict(Stream, Envelope),
    Data = Envelope.data,
    numeric_or_zero(Data, native_tokens_cached, CachedTokens),
    ( get_dict(response_cache_source_id, Data, Source),
      Source \== null
    -> ResponseCacheHit=true
    ; ResponseCacheHit=false
    ),
    Sample = cache_sample{cached_tokens:CachedTokens,
                          response_cache_hit:ResponseCacheHit}.

numeric_or_zero(Dict, Key, Value) :-
    ( get_dict(Key,Dict,Found), number(Found) -> Value=Found ; Value=0 ).

cache_hit(Sample) :-
    Sample.cached_tokens > 0,
    !.
cache_hit(Sample) :- Sample.response_cache_hit == true.

require_cache_environment(Model, Key) :-
    ( getenv('OPENROUTER_API_KEY', Key0), Key0 \== '', Key0 \== ""
    -> ( atom(Key0) -> atom_string(Key0, Key) ; Key=Key0 )
    ; throw(error(missing_cache_credential,_))
    ),
    default_openrouter_model(Model),
    require_pinned_cache_model(Model).

% The cache acceptance measures provider prefix caching through the
% OpenRouter generation API (native_tokens_cached /
% response_cache_source_id), so the pinned model must be a paid model;
% free tiers do not report reliable cache metadata.
require_pinned_cache_model(Model) :-
    \+ sub_atom(Model, _, 5, 0, ':free'),
    Model \== 'openrouter/free',
    !.
require_pinned_cache_model(Model) :-
    throw(error(cache_test_requires_paid_model(Model),_)).

print_cache_evidence :-
    forall(cache_generation(Turn,Id,Cached,ResponseHit),
           ( format(user_error, 'compiler_cache_turn_~d_generation_id: ~w~n',
                    [Turn,Id]),
             format(user_error, 'compiler_cache_turn_~d_cached_tokens: ~d~n',
                    [Turn,Cached]),
             format(user_error, 'compiler_cache_turn_~d_response_hit: ~w~n',
                    [Turn,ResponseHit])
           )).

:- end_tests(live_compiler_cache_openrouter).
