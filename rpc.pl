% SPDX-License-Identifier: MIT

:- module(rpc,
       [ rpc/2,                  % +URI, :Goal
         rpc/3,                  % +URI, :Goal, +Options
         promise/3,              % +URI, :Goal, -Reference
         promise/4,              % +URI, :Goal, -Reference, +Options
         dispose_namespace_promises/1, % internal WebSocket teardown
         promise_cleanup/1,      % +Reference
         yield/2,                % +Reference, -Answer
         yield/3,                % +Reference, -Answer, +Options
         runtime_property/1      % ?Property
       ]).

/** <module> RPC -- simple HTTP-based remote Prolog calls

Client-side wrapper around the node `/call` endpoint.  A goal is
serialised into URL query parameters, sent to a remote node, and its
solutions are yielded back to the caller one by one on backtracking.

When the first answer reports that more solutions exist, rpc/2-3
automatically fetches the next page (with an incremented offset) until
all solutions have been consumed or the caller stops backtracking.

## Examples {#rpc-examples}

```prolog
?- rpc('http://localhost:3060', member(X, [a,b,c])).
X = a ;
X = b ;
X = c.

% The following example tests whether server-side caching is in effect:
% the sleep/1 should only fire once regardless of how many pages are fetched.

?- rpc('http://localhost:3060', (sleep(2), X=a ; X=b), [limit(1)]).
X = a ;
X = b.
```

## Protocol {#rpc-protocol}

rpc/2,3 extracts the variables from Goal, wraps them in a `v(...)` template,
and sends both `goal` and `template` as URL-encoded atoms to the node.
The node returns `success(Slice, More)`, `failure`, or `error(E)` as a
quoted Prolog term.  rpc/2,3 then unifies the template with each element of
Slice in turn, yielding solutions one by one.  When More=true the next page
is fetched automatically on backtracking.

## Trealla port notes {#rpc-trealla}

  - The request URL is assembled from the base URI and handed directly to
    the current `http_open/3`. This avoids Trealla's removed private
    `'$parse_url'/2` predicate.
  - The response body is read with getline/2, which reads one line.
    This works because the node sends the entire answer on a single
    line ending with `.\n`.  Multi-line terms in the response would be
    truncated.
  - Goal and template atoms are encoded with Trealla's `www_form_encode/2`.

@author Torbjorn Lager
*/


%! runtime_property(?Property) is nondet.
% Host capabilities, matching the native SWI surface. Forced termination
% does not guarantee execution of Prolog cleanup handlers.
runtime_property(implementation(trealla_native)).
runtime_property(persistent(true)).
runtime_property(inbound_addressable(true)).
runtime_property(dom(false)).
runtime_property(actor_isolation(native_thread)).
runtime_property(hard_termination(true)).

:- use_module(library(http)).
:- use_module(library(uri), [www_form_encode/2]).
:- use_module(actors, [self/1,make_ref/1]).
:- use_module(isolation, [actor_source_module/2,actor_module/2,load_options_text/3]).

% State is local to this process; client ownership is recorded explicitly.
:- multifile hook_promise_owner/1.
:- dynamic closed_promise_owner/1.
:- dynamic promise_state/7. % Ref, Queue, Worker, Timer, Collector, Result, Owner
:- catch(mutex_create(_, [alias('$rpc_promise_lifecycle')]),
         error(permission_error(create, mutex, '$rpc_promise_lifecycle'), _), true).

:- meta_predicate
    rpc(+, :),
    rpc(+, :, +),
    promise(+, :, -),
    promise(+, :, -, +),
    yield(+, -, :).

:- meta_predicate promise_worker_run(0, ?, +).
:- meta_predicate start_promise(+, 0, +).
:- meta_predicate start_promise_setup(+, 0).
:- meta_predicate promise_transaction(0).


% Validate the complete list before source loading, I/O, resource creation,
% or collection. Extraction remains first-match; invalid duplicates still
% fail validation. Template and callback variables are never copied.
validate_client_options(Kind, Options) :-
    client_option_context(Kind,Context),
    catch((must_be(list,Options),validate_client_option_list(Kind,Options)),
          error(Formal,_),
          throw(error(Formal,context(Context,'invalid client option')))).
client_option_context(rpc,rpc:rpc/3).
client_option_context(promise,rpc:promise/4).
client_option_context(yield,rpc:yield/3).

validate_client_option_list(_,[]).
validate_client_option_list(Kind,[Option|Options]) :-
    must_be(nonvar,Option),
    (compound(Option),functor(Option,Name,1),client_option_type(Kind,Name,Type) ->
        arg(1,Option,Value),validate_client_value(Type,Value)
    ; atom_concat(Kind,'_option',Domain),
      throw(error(domain_error(Domain,Option),validate_client_options/2))),
    validate_client_option_list(Kind,Options).

client_option_type(yield,timeout,timeout).
client_option_type(yield,on_timeout,callable).
client_option_type(promise,template,template).
client_option_type(promise,offset,nonnegative_integer).
client_option_type(Kind,Name,Type) :-
    (Kind==rpc;Kind==promise),request_option_type(Name,Type).
request_option_type(limit,positive_integer).
request_option_type(once,boolean).
request_option_type(timeout,timeout).
request_option_type(http_timeout,number).
request_option_type(src_text,source_text).
request_option_type(src_list,list).
request_option_type(src_predicates,predicate_indicators).
request_option_type(src_uri,source_text).
request_option_type(request_header,request_header).
request_option_type(authorization,authorization).
request_option_type(user_agent,http_text).
request_option_type(redirect,boolean).
request_option_type(max_redirect,nonnegative_integer).
request_option_type(cacert_file,source_text).

validate_client_value(template,_) :- !.
validate_client_value(number,N) :- !, must_be(number,N).
validate_client_value(positive_integer,N) :- !,
    must_be(integer,N),
    (N>0 -> true ; throw(error(domain_error(positive_integer,N),client_option/1))).
validate_client_value(nonnegative_integer,N) :- !,
    must_be(integer,N),
    (N>=0 -> true ; throw(error(domain_error(not_less_than_zero,N),client_option/1))).
validate_client_value(timeout,T) :- !,
    (T==infinite -> true
    ; must_be(number,T),
      (T>=0 -> true ; throw(error(domain_error(not_less_than_zero,T),client_option/1)))).
validate_client_value(source_text,Text) :- !,
    must_be(nonvar,Text),isolation:source_text_atom(Text,_).
validate_client_value(http_text,Text) :- !,
    must_be(nonvar,Text),
    (number(Text) -> true ; validate_client_value(source_text,Text)).
validate_client_value(predicate_indicators,PIs) :- !,
    must_be(list,PIs),validate_client_pis(PIs).
validate_client_value(request_header,Header) :- !,
    must_be(nonvar,Header),
    (Header=(Name=Value) ->
        validate_client_value(http_text,Name),validate_client_value(http_text,Value)
    ; throw(error(type_error(request_header,Header),client_option/1))).
validate_client_value(authorization,Auth) :- !,
    must_be(nonvar,Auth),
    (Auth=basic(User,Password) ->
        validate_client_value(http_text,User),validate_client_value(http_text,Password)
    ; throw(error(domain_error(authorization,Auth),client_option/1))).
validate_client_value(Type,Value) :- must_be(Type,Value).
validate_client_pis([]).
validate_client_pis([PI|PIs]) :-
    isolation:source_predicate_indicator(PI,_,_),validate_client_pis(PIs).


                /*******************************
                *         URL ENCODING        *
                *******************************/

%!  url_encode(+Plain, -Encoded) is det.
%
%   Encode an atom as an UTF-8 HTML form/query value using the native URI
%   library.

url_encode(Plain, Encoded) :-
    www_form_encode(Plain, Encoded).


                /*******************************
                *         URI PARSING         *
                *******************************/

%!  base_path_prefix(+ParseUrlPath, -Prefix) is det.
%
%   Convert the `path(...)` element returned by parse_url/2 (which
%   always begins with `/`) into the prefix that precedes
%   `call?...` in the request path, with no leading `/` (http_open
%   adds it back) and a trailing `/` when non-empty.
%
%     '/'        -> ''        (root: just "call?...")
%     '/api'     -> 'api/'
%     '/api/'    -> 'api/'
%     '/a/b/c'   -> 'a/b/c/'

base_path_prefix('/', '') :- !.
base_path_prefix(BasePath, Prefix) :-
    atom_chars(BasePath, ['/'|Cs]),
    (   append(_, ['/'], Cs)
    ->  atom_chars(Prefix, Cs)
    ;   atom_chars(P0, Cs), atom_concat(P0, '/', Prefix)
    ).


                /*******************************
                *             RPC             *
                *******************************/

%!  rpc(+URI, :Goal) is nondet.
%!  rpc(+URI, :Goal, +Options) is nondet.
%
%   Call Goal against the node identified by URI, yielding solutions
%   one at a time on backtracking.  URI is an atom such as
%   `'http://localhost:3060'`.  Options:
%
%     - limit(+Positive)
%       Maximum number of solutions to fetch per HTTP request (page
%       size).  Smaller values yield more requests but lower latency
%       per solution.  Default: a very large number (effectively no
%       paging).
%     - once(+Boolean)
%       Yield the whole first slice without fetching later pages when true.
%       Default false. Forwarded to the peer as a query parameter.
%     - http_timeout(+Number), timeout(+SecondsOrInfinite),
%       request_header(+Name=Value),
%       authorization(basic(User,Password)), user_agent(+Text),
%       redirect(+Boolean), max_redirect(+Nonnegative), cacert_file(+File).
%       Explicit http_timeout/1 overrides legacy timeout/1; negatives become zero.
%       Read-timeout enforcement depends on the underlying runtime.
%       Only this documented Trealla HTTP subset is forwarded.
%       The HTTP library parses `https://` when Trealla is built with TLS and
%       v3.13.2 verifies the certificate chain and host name by default.
%     - src_text(+Text), src_list(+Terms), src_predicates(+PIs), src_uri(+URI)
%       Materialize application code locally and send it as the request's
%       src_text payload. src_uri fetching remains subject to source_policy.
%
%   The goal's free variables are collected with term_variables/2 and
%   wrapped in a `v(...)` template.  Both goal and template are
%   pretty-printed with `~q` (quoted, wrapped in parentheses to
%   preserve operator structure) and URL-encoded before embedding in
%   the query string.

rpc(URI, Goal) :-
    rpc(URI, Goal, []).

rpc(URI, Goal0, Options) :-
    validate_client_options(rpc,Options),
    strip_module(Goal0, _, Goal),
    term_variables(Goal, Vars),
    Template =.. [v|Vars],
    format(atom(GoalAtom),     "(~q)", [Goal]),
    format(atom(TemplateAtom), "(~q)", [Template]),
    option(limit(Limit), Options, 10000000000),
    rpc_source_module(SourceModule),
    load_options_text(SourceModule, Options, LoadText),
    rpc_page(Template, 0, Limit, GoalAtom, TemplateAtom, URI, Options,
             LoadText).

rpc_source_module(Module) :-
    self(Pid),
    actor_source_module(Pid, Module),
    !.
rpc_source_module(user).


%!  rpc_page(+Template, +Offset, +Limit, +GoalAtom, +TemplateAtom,
%!           +BaseURI, +Options) is nondet.
%
%   Fetch one page of results from the node and yield each solution.
%   On backtracking after the last solution on this page, fetches the
%   next page (if More=true) by recursing with Offset incremented by
%   the number of returned solutions.

rpc_page(Template, Offset, Limit, GoalAtom, TemplateAtom, BaseURI, Options,
         LoadText) :-
    url_encode(GoalAtom,     GoalEnc),
    url_encode(TemplateAtom, TemplEnc),
    strip_trailing_slash(BaseURI, RootURI),
    option(once(Once), Options, false),
    format(atom(URL0),
           '~w/call?goal=~w&template=~w&offset=~w&limit=~w&format=prolog&once=~w',
           [RootURI, GoalEnc, TemplEnc, Offset, Limit, Once]),
    rpc_source_url(URL0, LoadText, URL),
    rpc_http_options(Options, HTTPOptions),
    http_open(URL, S, HTTPOptions),
    setup_call_cleanup(true, getline(S, BodyChars), close(S)),
    atom_chars(BodyAtom, BodyChars),
    read_term_from_atom(BodyAtom, Answer, []),
    rpc_answer(Answer, Template, Offset, Limit,
               GoalAtom, TemplateAtom, BaseURI, Options, LoadText).

rpc_source_url(URL, '', URL) :- !.
rpc_source_url(URL0, LoadText, URL) :-
    url_encode(LoadText, Encoded),
    format(atom(URL), '~w&src_text=~w', [URL0, Encoded]).

strip_trailing_slash(URI, Root) :-
    atom_concat(Root0, '/', URI), !,
    strip_trailing_slash(Root0, Root).
strip_trailing_slash(URI, URI).

% Explicit transport spelling overrides the legacy timeout/1 independently
% of list order. Public validation has already checked every occurrence.
rpc_http_options(Options, HTTPOptions) :-
    rpc_transport_options(Options, Transport),
    (memberchk(http_timeout(T),Options) ->
        Timeout is max(0,T),
        without_legacy_timeouts(Transport, Rest),
        HTTPOptions=[timeout(Timeout)|Rest]
    ; HTTPOptions=Transport).

without_legacy_timeouts([], []).
without_legacy_timeouts([timeout(_)|Options], Rest) :- !,
    without_legacy_timeouts(Options,Rest).
without_legacy_timeouts([Option|Options], [Option|Rest]) :-
    without_legacy_timeouts(Options,Rest).

rpc_transport_options([http_timeout(_)|Options], HTTPOptions) :- !,
    rpc_transport_options(Options, HTTPOptions).
rpc_transport_options([], []).
rpc_transport_options([limit(_)|Options], HTTPOptions) :- !,
    rpc_transport_options(Options, HTTPOptions).
rpc_transport_options([template(_)|Options], HTTPOptions) :- !,
    rpc_transport_options(Options, HTTPOptions).
rpc_transport_options([offset(_)|Options], HTTPOptions) :- !,
    rpc_transport_options(Options, HTTPOptions).
rpc_transport_options([once(_)|Options], HTTPOptions) :- !,
    rpc_transport_options(Options, HTTPOptions).
rpc_transport_options([src_text(_)|Options], HTTPOptions) :- !,
    rpc_transport_options(Options, HTTPOptions).
rpc_transport_options([src_list(_)|Options], HTTPOptions) :- !,
    rpc_transport_options(Options, HTTPOptions).
rpc_transport_options([src_predicates(_)|Options], HTTPOptions) :- !,
    rpc_transport_options(Options, HTTPOptions).
rpc_transport_options([src_uri(_)|Options], HTTPOptions) :- !,
    rpc_transport_options(Options, HTTPOptions).
rpc_transport_options([Option|Options], [Option|HTTPOptions]) :-
    rpc_transport_options(Options, HTTPOptions).


%!  rpc_answer(+Answer, +Template, +Offset, +Limit, ...) is nondet.
%
%   Dispatch on the answer term received from the node:
%
%     - `success(Slice, true)` -- yield each solution in Slice via
%       member/2, then on backtracking fetch the next page.
%     - `success(Slice, false)` -- yield each solution in Slice via
%       member/2; no further pages.
%     - `failure` -- no solutions; fail.
%     - `error(Error)` -- re-throw Error.

rpc_answer(success(Slice, true), Template, Offset, Limit,
           GoalAtom, TemplateAtom, BaseURI, Options, LoadText) :- !,
    (   member(Template, Slice)
    ;   option(once(Once), Options, false), Once == false,
        length(Slice, Count),
        NewOffset is Offset + Count,
        rpc_page(Template, NewOffset, Limit,
                 GoalAtom, TemplateAtom, BaseURI, Options, LoadText)
    ).
rpc_answer(success(Slice, false), Template, _, _, _, _, _, _, _) :-
    member(Template, Slice).
rpc_answer(failure, _, _, _, _, _, _, _, _) :-
    fail.
rpc_answer(error(Error), _, _, _, _, _, _, _, _) :-
    throw(Error).


                /*******************************
                *       PROMISE AND YIELD      *
                *******************************/

%!  promise(+URI, :Goal, -Reference) is det.
%!  promise(+URI, :Goal, -Reference, +Options) is det.
%
%   Start one stateless HTTP RPC request in a detached Trealla thread. The
%   complete protocol answer is placed in a private message queue and can be
%   collected later with yield/2-3. A timed-out yield deliberately retains
%   the mapping so a later yield can still collect the answer. once(true) asks
%   the peer to stop after this slice; the complete peer answer is preserved.

promise(URI, Goal, Reference) :-
    promise(URI, Goal, Reference, []).

promise(URI, Goal0, Reference, Options) :-
    validate_client_options(promise,Options),
    strip_module(Goal0, _, Goal),
    option(template(Template), Options, Goal),
    option(offset(Offset), Options, 0),
    option(limit(Limit), Options, 10000000000),
    option(once(Once), Options, false),
    integer(Offset), Offset >= 0,
    integer(Limit), Limit > 0,
    format(atom(GoalAtom), "(~q)", [Goal]),
    format(atom(TemplateAtom), "(~q)", [Template]),
    rpc_source_module(SourceModule),
    load_options_text(SourceModule, Options, LoadText),
    rpc_http_options(Options, HTTPOptions),
    make_ref(Reference),
    start_promise(Reference,
        rpc:promise_worker(URI, GoalAtom, TemplateAtom, Offset, Limit,
                           LoadText, HTTPOptions, Once, Reference), 300).

% Owner identity is resolved before lifecycle locking. Namespace actors share
% within their client; standalone trusted actors retain process-wide sharing.
promise_owner_context(Owner) :-
    actors:current_actor_namespace(Namespace),
    (Namespace \== none ->
        (ground(Namespace) -> Owner=client_namespace(Namespace) ; Owner=unavailable)
    ; hook_promise_owner(Context) ->
        (ground(Context) -> Owner=Context ; Owner=unavailable)
    ; Owner=trusted_local).

promise_owned(Ref,Owner) :-
    Owner \== unavailable,
    promise_state(Ref,_,_,_,_,_,Stored),Stored == Owner.

promise_accessible(Ref,Owner) :-
    Owner \== unavailable,
    promise_state(Ref,_,_,_,_,Result,Stored),
    Result \== disposed,Stored == Owner.

% Setup is rollback-safe even if the second thread cannot be created.
start_promise(Reference, Goal, Seconds) :-
    start_promise_setup(Reference,
        rpc:start_promise_threads(Reference,Goal,Seconds)).

start_promise_setup(Reference, Setup) :-
    promise_owner_context(Owner),
    setup_call_cleanup(true,
        (promise_transaction((new_promise_state(Reference,_,Owner),call(Setup))),
         Started = true),
        (var(Started) -> dispose_promise(Reference) ; true)).

% Short bookkeeping operations are protected from asynchronous interruption.
% HTTP reads, queue waits and thread cancellation are outside this mutex.
promise_transaction(Goal) :-
    setup_call_cleanup(with_mutex('$rpc_promise_lifecycle', Goal), true, true).

new_promise_state(Ref, Queue) :-
    promise_owner_context(Owner),new_promise_state(Ref,Queue,Owner).

new_promise_state(Ref, Queue,Owner) :-
    (Owner == unavailable ->
        throw(error(permission_error(create,promise,client_context),rpc:promise/4))
    ; true),
    must_be(ground,Owner),
    (closed_promise_owner(Owner) ->
        throw(error(permission_error(create,promise,Owner),
                    context(rpc:promise/4,'client namespace has ended')))
    ; true),
    message_queue_create(Queue),
    catch(assertz(promise_state(Ref,Queue,none,none,none,pending,Owner)), Error,
          (message_queue_destroy(Queue),throw(Error))).

start_promise_threads(Ref, Goal, Seconds) :-
    thread_create(rpc:promise_thread(Ref,Goal), Worker, [detached(true)]),
    retract(promise_state(Ref,Q,none,none,C,R,Owner)),
    assertz(promise_state(Ref,Q,Worker,none,C,R,Owner)),
    thread_create(rpc:promise_thread(Ref,rpc:promise_auto_cleanup(Ref,Seconds)),
                  Timer, [detached(true)]),
    retract(promise_state(Ref,Q,Worker,none,C,R,Owner)),
    assertz(promise_state(Ref,Q,Worker,Timer,C,R,Owner)).

promise_thread(Ref, Goal) :-
    catch((promise_transaction(promise_active(Ref)),call(Goal)),
          '$rpc_promise_disposed',true).

promise_active(Ref) :- promise_state(Ref,_,_,_,_,Result,_), Result \== disposed.

% Store the answer before waking a collector. If it is interrupted after
% reading the wakeup, the next collector can still retrieve the answer.
deliver_promise_answer(Ref, Answer) :-
    promise_transaction(
        (retract(promise_state(Ref,Q,W,T,C,pending,Owner)) ->
            assertz(promise_state(Ref,Q,W,T,C,ready(Answer),Owner)),
            thread_send_message(Q,ready)
        ; true)).

promise_worker(URI, GoalAtom, TemplateAtom, Offset, Limit, LoadText,
               HTTPOptions, Once, Reference) :-
    promise_worker_run(
        rpc_fetch_answer(URI, GoalAtom, TemplateAtom, Offset, Limit,
                         LoadText, HTTPOptions, Once, Result), Result, Reference).

% A local request failure is distinct from a remote protocol 'failure'.
promise_worker_run(Goal, Result, Reference) :-
    catch((once(call(Goal)) -> Answer = Result
          ; Answer = error(error(promise_worker_failed,
                                  context(rpc:promise/4, 'request produced no answer')))),
          Error, Answer = error(Error)),
    deliver_promise_answer(Reference, Answer).

rpc_fetch_answer(BaseURI, GoalAtom, TemplateAtom, Offset, Limit, LoadText,
                 HTTPOptions, Once, Answer) :-
    url_encode(GoalAtom, GoalEnc),
    url_encode(TemplateAtom, TemplateEnc),
    strip_trailing_slash(BaseURI, RootURI),
    format(atom(URL0),
           '~w/call?goal=~w&template=~w&offset=~w&limit=~w&format=prolog&once=~w',
           [RootURI, GoalEnc, TemplateEnc, Offset, Limit, Once]),
    rpc_source_url(URL0, LoadText, URL),
    setup_call_cleanup(
        http_open(URL, Stream, HTTPOptions),
        (getline(Stream, BodyChars),
         atom_chars(BodyAtom, BodyChars),
         read_term_from_atom(BodyAtom, Answer, [])),
        close(Stream)).

promise_auto_cleanup(Reference, Seconds) :-
    sleep(Seconds), dispose_promise(Reference).

% Retirement excludes late delivery immediately. A waiting collector holds
% the queue alive until it has unwound; only wakeups are sent to that queue.
promise_cleanup(Reference) :-
    must_be(integer, Reference),promise_owner_context(Owner),
    dispose_accessible_promise(Reference,Owner).

dispose_accessible_promise(Reference,Owner) :-
    setup_call_cleanup(
        promise_transaction(
            (promise_owned(Reference,Owner) ->
                retire_promise(Reference,Threads),Dispose=true
            ; Threads=[],Dispose=false)),
        true,
        (stop_promise_threads(Threads),
         (Dispose == true -> finish_promise_disposal(Reference,200) ; true))).

% Closing admission and retiring the owner's full snapshot share the creation
% mutex. Signal workers and wait for collector release only after unlocking.
dispose_namespace_promises(Namespace) :-
    must_be(ground,Namespace),
    ((Namespace=ws_client(_);Namespace=ws_lineage(_,_)) -> true
    ; throw(error(domain_error(websocket_namespace,Namespace),dispose_namespace_promises/1))),
    setup_call_cleanup(
        promise_transaction(retire_namespace_promises(Namespace,Jobs)),
        true,
        finish_namespace_disposal(Jobs)).

retire_namespace_promises(Namespace,Jobs) :-
    Owner=client_namespace(Namespace),
    (closed_promise_owner(Owner) -> true ; assertz(closed_promise_owner(Owner))),
    findall(Ref,(promise_state(Ref,_,_,_,_,_,Stored),Stored==Owner),Refs),
    retire_namespace_references(Refs,Jobs).
retire_namespace_references([],[]).
retire_namespace_references([Ref|Refs],[job(Ref,Threads)|Jobs]) :-
    retire_promise(Ref,Threads),retire_namespace_references(Refs,Jobs).

finish_namespace_disposal(Jobs) :-
    stop_namespace_workers(Jobs,StopError),
    finish_namespace_queues(Jobs,QueueError),
    (StopError=error(E) -> throw(E)
    ; QueueError=error(E) -> throw(E)
    ; true).
stop_namespace_workers([],ok).
stop_namespace_workers([job(_,Threads)|Jobs],Result) :-
    catch((stop_promise_threads(Threads),Here=ok),E,Here=error(E)),
    stop_namespace_workers(Jobs,Rest),first_disposal_error(Here,Rest,Result).
finish_namespace_queues([],ok).
finish_namespace_queues([job(Ref,_)|Jobs],Result) :-
    catch((finish_promise_disposal(Ref,200),Here=ok),E,Here=error(E)),
    finish_namespace_queues(Jobs,Rest),first_disposal_error(Here,Rest,Result).
first_disposal_error(error(E),_,error(E)) :- !.
first_disposal_error(ok,Rest,Rest).

% Internal expiry/rollback disposal is independent of the worker's context.
dispose_promise(Reference) :-
    setup_call_cleanup(
        promise_transaction(retire_promise(Reference, Threads)),
        true,
        (stop_promise_threads(Threads),finish_promise_disposal(Reference,200))).

% A collector cancelled with raw thread_cancel/1 may skip its cleanup. Wait
% outside the mutex so normal release or observed thread retirement can free
% the retained queue. An unresponsive collector leaves an explicit retryable
% disposal error, rather than authorizing destruction underneath a reader.
finish_promise_disposal(Ref, Attempts) :-
    promise_transaction(
        (reap_stale_promise_claim(Ref),destroy_retired_promise(Ref),
         (promise_state(Ref,_,_,_,_,_,_) -> Done=false ; Done=true))),
    (Done == true -> true
    ; Attempts > 0 -> sleep(0.005),Next is Attempts-1,
        finish_promise_disposal(Ref,Next)
    ; throw(error(resource_error(promise_cleanup_timeout(Ref)),promise_cleanup/1))).

retire_promise(Ref, Threads) :-
    reap_stale_promise_claim(Ref),
    (retract(promise_state(Ref,Q,W,T,C,Result,Owner)) ->
        (Result == disposed -> Threads = []
        ; Threads = [W,T], thread_send_message(Q,disposed)),
        assertz(promise_state(Ref,Q,none,none,C,disposed,Owner)),
        destroy_retired_promise(Ref)
    ; Threads = []).

destroy_retired_promise(Ref) :-
    (retract(promise_state(Ref,Q,none,none,none,disposed,_)) ->
        message_queue_destroy(Q)
    ; true).

stop_promise_threads([]).
stop_promise_threads([Thread|Threads]) :-
    (Thread == none -> true
    ; thread_self(Self),
      (Thread == Self -> true
      ; catch(thread_signal(Thread,throw('$rpc_promise_disposed')),
              error(existence_error(thread_object,_),_),true))),
    stop_promise_threads(Threads).

%!  yield(+Reference, -Answer) is det.
%!  yield(+Reference, -Answer, :Options) is det.
%
%   Timeouts retain the promise for retry. A callback may supply Answer;
%   otherwise timeout is returned. Missing references raise an existence error.

yield(Reference, Answer) :-
    yield(Reference, Answer, []).

yield(Reference, Answer, Options0) :-
    must_be(integer, Reference),
    strip_module(Options0, Caller0, Options),
    validate_client_options(yield,Options),
    ( nonvar(Caller0) -> Caller = Caller0
    ; promise_callback_module(Caller) ),
    promise_owner_context(Owner),
    thread_self(CollectorThread),Claim=collector(CollectorThread),
    setup_call_cleanup(
        promise_transaction(claim_promise(Reference,Claim,Queue,Ready,Owner)),
        (option(timeout(Timeout), Options, infinite),
         (Ready == true -> true ; once(yield_wait(Timeout,Queue,_))),
         setup_call_cleanup(
             promise_transaction(finish_promise_wait(Reference,Claim,Outcome,Threads)),
             true, stop_promise_threads(Threads))),
        promise_transaction(release_promise_claim(Reference,Claim))),
    !,
    (Outcome = answer(Message) -> Answer = Message
    ; yield_timeout(Reference,Answer,Caller,Options)).

% Callback execution also needs the actor's bootstrap module when there is no
% supplied source. Keep source selection for outgoing RPCs independent of this.
promise_callback_module(Module) :-
    self(Pid),
    ( actor_source_module(Pid, Module) -> true
    ; actor_module(Pid, Module) -> true
    ; Module = user
    ).

claim_promise(Ref, Claim, Queue, Ready,Owner) :-
    (promise_accessible(Ref,Owner) -> true ; missing_promise(Ref)),
    reap_stale_promise_claim(Ref),
    (promise_state(Ref,Queue,W,T,C,R,Owner), R \== disposed ->
        (C == none ->
            retract(promise_state(Ref,Queue,W,T,C,R,Owner)),
            assertz(promise_state(Ref,Queue,W,T,Claim,R,Owner)),
            (R = ready(_) -> Ready = true ; Ready = false)
        ; throw(error(permission_error(collect,promise,Ref),
                      context(rpc:yield/3,'collection already in progress'))))
    ; missing_promise(Ref)).

finish_promise_wait(Ref, Claim, Outcome, Threads) :-
    (promise_state(Ref,_,_,_,Claim,R,_), R \== disposed ->
        (R = ready(Answer) -> retire_promise(Ref,Threads),Outcome=answer(Answer)
        ; Threads=[],Outcome=timeout)
    ; missing_promise(Ref)).

release_promise_claim(Ref, Claim) :-
    (retract(promise_state(Ref,Q,W,T,Claim,R,Owner)) ->
        assertz(promise_state(Ref,Q,W,T,none,R,Owner)),destroy_retired_promise(Ref)
    ; true).

% Trealla's raw thread_cancel/1 bypasses Prolog cleanup. A later collector
% or expiry can release a claim left by such a thread after it has retired.
reap_stale_promise_claim(Ref) :-
    (promise_state(Ref,Q,W,T,C,R,Owner), C \== none,
     C=collector(Thread),
     \+ catch(thread_property(Thread,status(_)),_,fail) ->
        retract(promise_state(Ref,Q,W,T,C,R,Owner)),
        assertz(promise_state(Ref,Q,W,T,none,R,Owner))
    ; true).

missing_promise(Ref) :-
    throw(error(existence_error(promise,Ref),
                context(rpc:yield/3,'unknown, consumed, or expired promise'))).

yield_timeout(Reference, Answer, Caller, Options) :-
    option(on_timeout(OnTimeout), Options, true),
    ( once(call(Caller:OnTimeout)) ->
        ( var(Answer) -> Answer = timeout ; true )
    ; throw(error(timeout_callback_failed(Reference),
                  context(rpc:yield/3, 'on_timeout goal failed')))
    ).

% Trealla signals do not wake an indefinitely blocked queue read.
% Short bounded reads let it observe cancellation without changing the
% caller's overall deadline or exposing the internal polling as a timeout.
yield_wait(infinite, Queue, Outcome) :- !,
    promise_queue_wait(Queue,infinite,Outcome).
yield_wait(Timeout, Queue, Outcome) :-
    number(Timeout), Timeout >= 0,
    get_time(Now), Deadline is Now+Timeout,
    promise_queue_wait(Queue,Deadline,Outcome).

promise_queue_wait(Queue, Deadline, Outcome) :-
    (Deadline == infinite -> Slice=0.05
    ; get_time(Now),Slice is max(0,min(0.05,Deadline-Now))),
    (thread_get_message(Queue,Message,[timeout(Slice)]) -> Outcome=answer(Message)
    ; (Deadline == infinite -> Again=true
      ; get_time(After),(After < Deadline -> Again=true ; Again=false)),
      (Again == true -> promise_queue_wait(Queue,Deadline,Outcome)
      ; Outcome=timeout)).
