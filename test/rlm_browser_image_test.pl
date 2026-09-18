:- begin_tests(rlm_browser_image).

:- use_module('../prolog/rlm_browser_tool_pack').
:- use_module('../prolog/rlm_image').
:- use_module('../prolog/rlm_image_tool_pack').
:- use_module('../prolog/rlm_tool').

test(browser_pack_registers_closed_read_and_write_surface) :-
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( load_browser_tool_pack(Registry, ok(Loaded)),
          assertion(Loaded.pack == browser_core),
          tool_discover(Registry, Schemas),
          findall(Name-Effect,
                  ( member(Schema, Schemas),
                    Name = Schema.name,
                    Effect = Schema.effect
                  ),
                  Pairs),
          assertion(memberchk(browser_tabs-read, Pairs)),
          assertion(memberchk(browser_read-read, Pairs)),
          assertion(memberchk(browser_screenshot-read, Pairs)),
          assertion(memberchk(browser_open-network_write, Pairs)),
          assertion(memberchk(browser_submit-network_write, Pairs)),
          assertion(length(Pairs, 9))
        ),
        tool_registry_destroy(Registry)).

test(image_pack_is_network_write) :-
    tool_registry_create(Registry),
    setup_call_cleanup(
        true,
        ( load_image_tool_pack(Registry, ok(_)),
          tool_lookup(Registry, image_generate, ok(Schema)),
          assertion(Schema.effect == network_write),
          assertion(Schema.capability == tool(image_generate))
        ),
        tool_registry_destroy(Registry)).

test(openai_image_provider_is_data_only) :-
    openai_image_provider('http://127.0.0.1:9999/v1/images/generations',
                          env('TEST_IMAGE_KEY'),
                          'test-image-model',
                          Provider),
    assertion(Provider ==
              provider(openai_image,
                       [ endpoint('http://127.0.0.1:9999/v1/images/generations'),
                         credential(env('TEST_IMAGE_KEY')),
                         model('test-image-model'),
                         timeout(60)
                       ])).

test(image_request_payload_normalizes_prompt_and_count) :-
    rlm_image:image_request_payload(
        _{prompt:'draw a red cube', n:2, size:"1024x1024"},
        'test-image-model',
        ok(Payload)),
    assertion(Payload.prompt == "draw a red cube"),
    assertion(Payload.n =:= 2),
    assertion(Payload.model == 'test-image-model'),
    assertion(Payload.size == "1024x1024").

test(image_request_payload_rejects_large_count) :-
    rlm_image:image_request_payload(
        _{prompt:"draw", n:5},
        'test-image-model',
        error(Error)),
    assertion(Error.kind == validation_error).

:- end_tests(rlm_browser_image).
