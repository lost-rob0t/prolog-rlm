:- module(rlm_chain,
          [ rlm_chain_ready/0
          ]).

/** <module> Provider and model-chain runtime

This module is the production namespace for provider-neutral model access,
message normalization, structured output, retries, streaming, middleware,
and usage accounting.

Issue #5 fills in the first real provider implementation. Test doubles do not
belong in this module.
*/

rlm_chain_ready.
