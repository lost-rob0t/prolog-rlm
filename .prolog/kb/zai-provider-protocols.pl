/* Z.AI Coding Plan provider architecture, verified by deterministic fixtures. */

model_provider_protocol(zai_coding, openai_chat_completions).
model_provider_protocol(zai_codex, openai_responses).
model_provider_protocol(zai_claude, anthropic_messages).

provider_streaming(zai_coding, supported).
provider_streaming(zai_codex, denied).
provider_streaming(zai_claude, denied).

provider_credential(zai_coding, env('ZAI_API_KEY')).
provider_credential(zai_codex, env('ZAI_API_KEY')).
provider_credential(zai_claude, env('ZAI_API_KEY')).

provider_http_identity_default(Provider, 'prolog-rlm/0.1') :-
    memberchk(Provider, [zai_coding,zai_codex,zai_claude]).
provider_http_identity_option(Provider, user_agent) :-
    memberchk(Provider, [zai_coding,zai_codex,zai_claude]).

provider_native_continuation(responses, lossless_ordered_sequence).
provider_native_continuation(anthropic_messages, lossless_ordered_sequence).

provider_protocol_invariant(Protocol, tool_result_correlation_required) :-
    memberchk(Protocol, [openai_responses, anthropic_messages]).
provider_protocol_invariant(Protocol, malformed_wire_data_fails_closed) :-
    memberchk(Protocol, [openai_responses, anthropic_messages]).
