/* Named OpenAI API Chat Completions provider. */

provider_constructor(openai_api, rlm_chain, openai_api_provider/2).
provider_wire_protocol(openai_api, openai_chat_completions).
provider_credential_boundary(openai_api, env('OPENAI_API_KEY'), request_dispatch).
provider_native_tool_format(openai_api, openai_compatible).
provider_subscription_auth(openai_api, unsupported).
