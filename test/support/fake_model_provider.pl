:- module(fake_model_provider,
          [ fake_model_complete/2
          ]).

/** <module> Deterministic model test double

This module is intentionally test-only. Production code must never import it.
*/

fake_model_complete(Request,
                    model_response{provider:fake,
                                   content:"deterministic fake response",
                                   request:Request}).
