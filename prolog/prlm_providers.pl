:- module(prlm_providers,
          [ prlm_providers_ready/0,
            prlm_provider_register/3,
            prlm_provider_registered/2,
            prlm_model_call/4,
            prlm_model_call/5,
            prlm_validate_proposal/3,
            prlm_proposal_op_add/1,
            prlm_proposal_op/1,
            prlm_prolog_provider/4,
            prlm_http_post/5,
            prlm_process_run/4,
            prlm_actor_provider_ask/4
          ]).

/** <module> prlm_providers — replaceable language providers

LLMs (and any other text source) are replaceable *language providers*.
Providers generate PROPOSALS (inert data); the Prolog runtime stays
authoritative and decides what is valid via prlm_validate_proposal/3.
Nothing a provider returns is ever executed directly.

Adapters (closed terms):

  * `prolog` — the deterministic built-in "no model" provider, driven by the
    multifile hook prlm_prolog_provider/4.  When no clause succeeds the
    proposal text is "" and the status is `unsupported`.  This is the
    Prolog-only mode: the language runs WITHOUT any model whenever it can
    answer procedurally.
  * `echo` — proposal text is the content of the last user message.
  * `fake(Calls)` — Calls is a list of fake(Text), consumed in order;
    deterministic and stateful per session.  State lives in the session KVS
    under the key provider_fake_remaining(Name).  When exhausted the
    adapter raises prlm_error(type_error, _{fake:exhausted}), which
    prlm_model_call/{4,5} converts into a status `error` proposal (errors
    are data, never thrown at callers).
  * `fake_fn(Pred)` — trusted host Pred/3: call(Pred, Session, Messages, Text).
    Unqualified Pred resolves in module `user`; pass Module:Pred for
    callbacks defined elsewhere.
  * `http(Endpoint, Headers)` — deferred through the multifile dynamic hook
    prlm_http_post/5.  Default (no clauses) fails -> status `error`.
  * `process(Cmd)` — deferred through prlm_process_run/4.
  * `actor(ActorId)` — deferred through prlm_actor_provider_ask/4.

Session interaction is by contract through the prlm_session module
(prlm_session_get/put/3, prlm_session_option/3, prlm_event_emit/3); this
module calls those predicates module-qualified so it carries no load-time
dependency on where prlm_session.pl lives.

Token accounting is a deterministic estimate: whitespace-separated token
counts of all message contents (tokens_in) and of the returned text
(tokens_out).  Exactly one model_call event is emitted per call, AFTER the
invocation, carrying both counts; adapter errors additionally emit a
failure event.

The authority gate prlm_validate_proposal/3 parses proposal text with the
kernel's parse-only prlm_read_goal/3 (this never executes anything) and
accepts it only when the parsed term unifies with a prlm_proposal_op/1
whitelist shape.  Rejection is DATA: rejected(not_a_term) |
rejected(not_whitelisted).  prlm_proposal_op/1 is multifile+dynamic so
trusted hosts can extend it with prlm_proposal_op_add/1.
*/

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(prlm_kernel).

% ============================================================
% Extension hooks (all multifile + dynamic; trusted hosts only)
% ============================================================

:- multifile prlm_prolog_provider/4.
:- dynamic prlm_prolog_provider/4.
% prlm_prolog_provider(Session, Messages, Opts, Text)

:- multifile prlm_http_post/5.
:- dynamic prlm_http_post/5.
% prlm_http_post(Session, Endpoint, Headers, RequestBody, ResponseText)

:- multifile prlm_process_run/4.
:- dynamic prlm_process_run/4.
% prlm_process_run(Session, Cmd, InputText, OutputText)

:- multifile prlm_actor_provider_ask/4.
:- dynamic prlm_actor_provider_ask/4.
% prlm_actor_provider_ask(Session, ActorId, Messages, Text)

:- multifile prlm_proposal_op/1.
:- dynamic prlm_proposal_op/1.

% Default whitelist of proposal op shapes (the authority gate).  Arg
% positions are documented in the module header; all patterns are open.
prlm_proposal_op(model_call_step(_)).
prlm_proposal_op(tool_call_step(_, _)).
prlm_proposal_op(ctx_compile_step).
prlm_proposal_op(ctx_op_step(_)).
prlm_proposal_op(assert_fact_step(_, _)).
prlm_proposal_op(learn_step(_)).
prlm_proposal_op(spawn_agent_step(_)).
prlm_proposal_op(send_message_step(_, _)).
prlm_proposal_op(verify_step(_)).
prlm_proposal_op(yield_step(_)).

% ============================================================
% Readiness
% ============================================================

prlm_providers_ready.

% ============================================================
% Provider registry (per session, via the session KVS)
% ============================================================

%! prlm_provider_register(+Session, +Name, +Adapter) is det
%
% Validate the adapter shape and store it in the session under the KVS key
% prlm_providers.  Unknown shapes throw prlm_error(type_error, _{adapter:
% Adapter}).  Emits nothing.
prlm_provider_register(Session, Name, Adapter) :-
    (   atom(Name)
    ->  true
    ;   throw(prlm_error(type_error, _{provider_name: Name}))
    ),
    validate_adapter(Adapter),
    session_providers(Session, D0),
    put_dict(Name, D0, Adapter, D1),
    prlm_session:prlm_session_put(Session, prlm_providers, D1).

%! prlm_provider_registered(+Session, -Names) is det
%
% Sorted atom names of the providers registered on Session.
prlm_provider_registered(Session, Names) :-
    session_providers(Session, D),
    dict_keys(D, Keys0),
    sort(Keys0, Names).

session_providers(Session, Dict) :-
    (   prlm_session:prlm_session_get(Session, prlm_providers, D0)
    ->  Dict = D0
    ;   Dict = providers{}
    ).

validate_adapter(prolog) :- !.
validate_adapter(echo) :- !.
validate_adapter(fake(Calls)) :- !,
    validate_fake_calls(Calls).
validate_adapter(fake_fn(Pred)) :- !,
    (   callable(Pred)
    ->  true
    ;   throw(prlm_error(type_error, _{adapter: fake_fn(Pred)}))
    ).
validate_adapter(http(Endpoint, Headers)) :- !,
    (   text_atom(Endpoint),
        is_dict(Headers)
    ->  true
    ;   throw(prlm_error(type_error, _{adapter: http(Endpoint, Headers)}))
    ).
validate_adapter(process(Cmd)) :- !,
    (   atom(Cmd)
    ->  true
    ;   throw(prlm_error(type_error, _{adapter: process(Cmd)}))
    ).
validate_adapter(actor(ActorId)) :- !,
    (   atom(ActorId)
    ->  true
    ;   integer(ActorId)
    ->  true
    ;   throw(prlm_error(type_error, _{adapter: actor(ActorId)}))
    ).
validate_adapter(Adapter) :-
    throw(prlm_error(type_error, _{adapter: Adapter})).

validate_fake_calls([]).
validate_fake_calls([fake(T)|Rest]) :- !,
    (   text_atom(T)
    ->  validate_fake_calls(Rest)
    ;   throw(prlm_error(type_error, _{adapter: fake(T)}))
    ).
validate_fake_calls([Other|_]) :-
    throw(prlm_error(type_error, _{adapter: Other})).

text_atom(T) :- atom(T).
text_atom(T) :- string(T).

% ============================================================
% Model calls
% ============================================================

%! prlm_model_call(+Session, +Messages, +Opts, -Proposal) is det
%
% Resolve the provider from the session's default (prlm_session_option
% provider) and behave as prlm_model_call/5.
prlm_model_call(Session, Messages, Opts, Proposal) :-
    (   prlm_session:prlm_session_option(Session, provider, Name)
    ->  prlm_model_call(Session, Name, Messages, Opts, Proposal)
    ;   throw(prlm_error(existence_error, _{provider: none}))
    ).

%! prlm_model_call(+Session, +Provider, +Messages, +Opts, -Proposal) is det
%
% Invoke the named provider on Messages.  Provider errors become DATA:
% proposal{status: error, reason: Reason} plus a `failure` event — never a
% throw (the fake-fixture exhaustion is folded into the same DATA path;
% its internal signal is prlm_error(type_error, _{fake:exhausted})).
% Unregistered providers and malformed messages/options are programming
% errors and DO throw prlm_error/2.
%
% Proposal = proposal{text, term, provider, status, reason, time,
%                     usage{tokens_in, tokens_out}}.
% Exactly one model_call event is emitted per call, after the invocation,
% with tokens_in and tokens_out.
prlm_model_call(Session, Provider, Messages, Opts, Proposal) :-
    (   atom(Provider)
    ->  true
    ;   throw(prlm_error(type_error, _{provider: Provider}))
    ),
    validate_messages(Messages, Count),
    validate_options(Opts, Model),
    messages_tokens(Messages, TokensIn),
    provider_adapter(Session, Provider, Adapter),
    get_time(Time),
    invoke_adapter(Session, Provider, Adapter, Messages, Opts, Result),
    finish_proposal(Session, Provider, Model, Count, TokensIn, Time, Result,
                    Proposal).

provider_adapter(Session, Name, Adapter) :-
    (   session_providers(Session, D),
        get_dict(Name, D, A0)
    ->  Adapter = A0
    ;   Name == prolog
    ->  Adapter = prolog
    ;   throw(prlm_error(existence_error, _{provider: Name}))
    ).

validate_messages(Messages, Count) :-
    (   is_list(Messages)
    ->  validate_messages_(Messages, 0, Count)
    ;   throw(prlm_error(type_error, _{messages: Messages}))
    ).

validate_messages_([], N, N).
validate_messages_([M|Ms], N0, N) :-
    (   M = msg(Role, Content),
        valid_role(Role),
        text_atom(Content)
    ->  N1 is N0 + 1,
        validate_messages_(Ms, N1, N)
    ;   throw(prlm_error(type_error, _{message: M}))
    ).

valid_role(system).
valid_role(user).
valid_role(assistant).
valid_role(tool).

validate_options(Opts, Model) :-
    (   is_dict(Opts)
    ->  dict_keys(Opts, Keys),
        (   member(Key, Keys),
            \+ memberchk(Key, [model, temperature])
        ->  throw(prlm_error(type_error, _{option: Key}))
        ;   true
        ),
        (   get_dict(model, Opts, M)
        ->  (   atom(M)
            ->  Model = M
            ;   throw(prlm_error(type_error, _{model: M}))
            )
        ;   Model = none
        ),
        (   get_dict(temperature, Opts, T)
        ->  (   number(T)
            ->  true
            ;   throw(prlm_error(type_error, _{temperature: T}))
            )
        ;   true
        )
    ;   throw(prlm_error(type_error, _{options: Opts}))
    ).

invoke_adapter(Session, Name, Adapter, Messages, Opts, Result) :-
    catch(catch(adapter_invoke(Session, Name, Adapter, Messages, Opts, R0),
                prlm_error(Type, Info),
                R0 = error(Type, Info)),
          Other,
          R0 = error(throw, Other)),
    Result = R0.

adapter_invoke(_Session, _Name, echo, Messages, _Opts, Result) :-
    (   last_user_content(Messages, Content)
    ->  Result = ok(Content)
    ;   Result = error(no_user_message, none)
    ).
adapter_invoke(Session, Name, fake(Calls), _Messages, _Opts, ok(Text)) :-
    fake_remaining_key(Name, Key),
    (   prlm_session:prlm_session_get(Session, Key, Remaining0)
    ->  true
    ;   Remaining0 = Calls
    ),
    (   Remaining0 == []
    ->  throw(prlm_error(type_error, _{fake: exhausted}))
    ;   Remaining0 = [fake(Text)|Rest],
        prlm_session:prlm_session_put(Session, Key, Rest)
    ).
adapter_invoke(Session, _Name, fake_fn(Pred), Messages, _Opts, Result) :-
    (   Pred = _:_
    ->  Goal = Pred
    ;   Goal = user:Pred
    ),
    (   call(Goal, Session, Messages, Text)
    ->  Result = ok(Text)
    ;   Result = error(fake_fn_failed, none)
    ).
adapter_invoke(Session, _Name, prolog, Messages, Opts, Result) :-
    (   prlm_prolog_provider(Session, Messages, Opts, Text)
    ->  Result = ok(Text)
    ;   Result = unsupported
    ).
adapter_invoke(Session, _Name, http(Endpoint, Headers), Messages, _Opts, Result) :-
    render_messages(Messages, Body),
    (   prlm_http_post(Session, Endpoint, Headers, Body, ResponseText)
    ->  Result = ok(ResponseText)
    ;   Result = error(http_hook_failed, _{endpoint: Endpoint})
    ).
adapter_invoke(Session, _Name, process(Cmd), Messages, _Opts, Result) :-
    render_messages(Messages, Input),
    (   prlm_process_run(Session, Cmd, Input, OutputText)
    ->  Result = ok(OutputText)
    ;   Result = error(process_hook_failed, _{cmd: Cmd})
    ).
adapter_invoke(Session, _Name, actor(ActorId), Messages, _Opts, Result) :-
    (   prlm_actor_provider_ask(Session, ActorId, Messages, Text)
    ->  Result = ok(Text)
    ;   Result = error(actor_hook_failed, _{actor: ActorId})
    ).

fake_remaining_key(Name, provider_fake_remaining(Name)).

finish_proposal(Session, Provider, Model, Count, TokensIn, Time, Result,
                Proposal) :-
    (   Result == unsupported
    ->  Text = "",
        Term = none,
        Status = unsupported,
        Reason = none,
        Info = none,
        TokensOut = 0
    ;   Result = ok(Text0)
    ->  Text = Text0,
        Status = ok,
        Reason = none,
        Info = none,
        parse_proposal_term(Text, Term),
        tokens_count(Text, TokensOut)
    ;   Result = error(RawReason, Info)
    ->  Text = "",
        Term = none,
        Status = error,
        TokensOut = 0,
        error_reason(RawReason, Info, Reason)
    ),
    Proposal = proposal{text: Text,
                        term: Term,
                        provider: Provider,
                        status: Status,
                        reason: Reason,
                        time: Time,
                        usage: usage{tokens_in: TokensIn,
                                     tokens_out: TokensOut}},
    prlm_session:prlm_event_emit(Session, model_call,
        _{provider: Provider,
          model: Model,
          messages_count: Count,
          tokens_in: TokensIn,
          tokens_out: TokensOut,
          status: Status,
          time: Time}),
    (   Status == error
    ->  sanitize_info(Info, InfoC),
        FailureData0 = _{provider: Provider,
                         model: Model,
                         messages_count: Count,
                         tokens_in: TokensIn,
                         tokens_out: TokensOut,
                         status: error},
        FailureData = FailureData0.put(reason, Reason).put(info, InfoC),
        prlm_session:prlm_event_emit(Session, failure, FailureData)
    ;   true
    ).

% Event data must be a closed term (session contract): ground copies of
% adapter exception balls before they enter the event stream.
sanitize_info(Info, InfoC) :-
    (   term_variables(Info, [])
    ->  InfoC = Info
    ;   copy_term(Info, Info0),
        numbervars(Info0, 0, _),
        InfoC = Info0
    ).

error_reason(type_error, Info, fake_exhausted) :-
    is_dict(Info),
    get_dict(fake, Info, exhausted),
    !.
error_reason(Type, _, Type).

%! parse_proposal_term(+Text, -Term) is det
%
% Parse proposal text with the kernel's parse-only prlm_read_goal/3 — this
% NEVER executes anything.  A single parseable term yields Term; any parse
% failure or exception yields none.
parse_proposal_term(Text, Term) :-
    (   catch(prlm_read_goal(Text, Term0, _), _, fail)
    ->  Term = Term0
    ;   Term = none
    ).

% ============================================================
% The authority gate
% ============================================================

%! prlm_validate_proposal(+Session, +Proposal, -Op) is det
%
% THE AUTHORITY GATE for model output.  Parses Proposal.text with the
% kernel's parse-only prlm_read_goal/3 (never executes) and accepts it only
% when the parsed term unifies with a prlm_proposal_op/1 whitelist shape:
% Op is then the (instantiated) op term.  Otherwise Op is DATA:
% rejected(not_a_term) | rejected(not_whitelisted).  Never throws.
prlm_validate_proposal(_Session, Proposal, Op) :-
    (   text_of(Proposal, Text)
    ->  (   catch(prlm_read_goal(Text, Term, _), _, fail)
        ->  match_op(Term, Op)
        ;   Op = rejected(not_a_term)
        )
    ;   Op = rejected(not_a_term)
    ).

text_of(Proposal, Text) :-
    is_dict(Proposal),
    get_dict(text, Proposal, Text),
    (   atom(Text)
    ->  true
    ;   string(Text)
    ).

match_op(Term, Op) :-
    (   prlm_proposal_op(Pattern),
        Term = Pattern,
        !
    ->  Op = Pattern
    ;   Op = rejected(not_whitelisted)
    ).

%! prlm_proposal_op_add(+Op) is det
%
% Extend the whitelist with a new op shape.  Trusted host only.
prlm_proposal_op_add(Op) :-
    (   callable(Op)
    ->  assertz(prlm_proposal_op(Op))
    ;   throw(prlm_error(type_error, _{op: Op}))
    ).

% ============================================================
% Deterministic token estimates
% ============================================================

messages_tokens([], 0).
messages_tokens([msg(_, Content)|Ms], N) :-
    tokens_count(Content, N1),
    messages_tokens(Ms, N2),
    N is N1 + N2.

tokens_count(Text, N) :-
    (   atom(Text)
    ->  atom_string(Text, S)
    ;   S = Text
    ),
    split_string(S, " \t\r\n", "", Parts),
    count_nonempty(Parts, N).

count_nonempty([], 0).
count_nonempty([P|Ps], N) :-
    count_nonempty(Ps, N1),
    (   P == ""
    ->  N = N1
    ;   N is N1 + 1
    ).

% ============================================================
% Helpers
% ============================================================

last_user_content(Messages, Content) :-
    include_user(Messages, Contents),
    Contents = [_|_],
    last_element(Contents, Content).

include_user([], []).
include_user([msg(user, C)|Ms], [C|Rest]) :- !,
    include_user(Ms, Rest).
include_user([_|Ms], Rest) :-
    include_user(Ms, Rest).

last_element([X], X) :- !.
last_element([_|Ms], X) :-
    last_element(Ms, X).

render_messages(Messages, Text) :-
    render_each(Messages, Lines),
    atomic_list_concat(Lines, '\n', Text).

render_each([], []).
render_each([msg(Role, Content)|Ms], [Line|Lines]) :-
    format(atom(Line), "~w: ~w", [Role, Content]),
    render_each(Ms, Lines).
