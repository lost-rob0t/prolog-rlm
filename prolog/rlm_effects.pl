:- module(rlm_effects, []).

/** <module> Public durable-effect runtime facade

Load this module when an integration needs #57 effect identity, #53 authority
composition, and the canonical #54 async executor together. Persistence remains
an internal implementation module.
*/

:- reexport(rlm_effect).
:- reexport(rlm_effect_authority).
:- reexport(rlm_effect_executor).
