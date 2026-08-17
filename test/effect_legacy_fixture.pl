:- module(effect_legacy_fixture,
          [ legacy_fixture_create/2
          ]).

/** <module> Journal fixture emitted through the PR #78 predicate schema */

:- use_module(library(persistency)).

:- persistent
       effect_call_record(call_id:atom, fingerprint:atom, kind:atom,
                          request:any, logical_key:any, created_at:float),
       effect_attempt_record(attempt_id:atom, revision:integer, call_id:atom,
                             fingerprint:atom, sequence:integer,
                             parent_attempt:any, mode:atom, status:atom,
                             idempotency_key:atom, authority:any,
                             metadata:any, created_at:float, updated_at:float),
       effect_observation_record(attempt_id:atom, observation:any),
       effect_event_record(call_id:atom, sequence:integer, event:any).

legacy_fixture_create(File, Details) :-
    setup_call_cleanup(
        db_attach(File, [sync(close)]),
        write_fixture(Details),
        db_detach).

write_fixture(Details) :-
    Call1 = legacy_call_observed,
    Call2 = legacy_call_uncertain,
    Fingerprint1 = 'sha256:legacy-observed',
    Fingerprint2 = 'sha256:legacy-uncertain',
    assert_effect_call_record(Call1, Fingerprint1, model,
                              request{prompt:observed}, auto, 1.0),
    assert_effect_call_record(Call2, Fingerprint2, tool,
                              request{target:uncertain}, auto, 2.0),
    write_attempt_revisions(legacy_attempt_observed, Call1, Fingerprint1,
                            'legacy-provider-key-observed',
                            [admitted,dispatching,observed]),
    write_attempt_revisions(legacy_attempt_uncertain, Call2, Fingerprint2,
                            'legacy-provider-key-uncertain',
                            [admitted,dispatching]),
    Observation = observation{status:succeeded,
                              value:legacy_value,
                              usage:usage{units:7},
                              provenance:legacy_provider},
    assert_effect_observation_record(legacy_attempt_observed, Observation),
    assert_effect_event_record(Call1, 1,
                               effect_event{event_id:legacy_event_1,
                                            sequence:1,
                                            type:attempt_admitted,
                                            detail:event_detail{}}),
    db_sync(gc(always)),
    Details = legacy_fixture{observed_call:Call1,
                             observed_attempt:legacy_attempt_observed,
                             uncertain_attempt:legacy_attempt_uncertain,
                             observed_provider_key:'legacy-provider-key-observed',
                             uncertain_provider_key:'legacy-provider-key-uncertain',
                             observation:Observation}.

write_attempt_revisions(AttemptId, CallId, Fingerprint, ProviderKey,
                        Statuses) :-
    forall(nth1(Revision, Statuses, Status),
           ( UpdatedAt is float(Revision),
             assert_effect_attempt_record(
                 AttemptId, Revision, CallId, Fingerprint, 1, none, initial,
                 Status, ProviderKey, authority_ref{tier:dangerous},
                 metadata{}, 1.0, UpdatedAt) )).
