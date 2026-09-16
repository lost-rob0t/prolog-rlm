/* Official Claude API provider over the shared Anthropic Messages adapter. */

:- multifile model_provider_protocol/2,
             provider_streaming/2,
             provider_credential/2,
             provider_http_identity_default/2,
             provider_http_identity_option/2.

model_provider_protocol(claude_api, anthropic_messages).
provider_streaming(claude_api, denied).
provider_credential(claude_api, env('ANTHROPIC_API_KEY')).
provider_auth_header(claude_api, 'x-api-key').
provider_http_identity_default(claude_api, 'prolog-rlm/0.1').
provider_http_identity_option(claude_api, user_agent).
provider_subscription_auth(claude_api, unsupported).
