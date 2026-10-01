% SPDX-License-Identifier: MIT

:- module(observability,
    [ configure_observability/2,
      reset_observability/0,
      observe_request/4,
      observe_rejection/4,
      observe_activity_start/4,
      observe_activity_end/3,
      current_observability_snapshot/1,
      node_metrics_text/1,
      node_runtime_json/1
    ]).

/** <module> Native node audit events and aggregate metrics

This module provides the small Trealla counterpart of Trinity's node log,
metric counters, and Prometheus renderer.  It retains a bounded event window
in memory and can append the same sanitized records to a rotating JSONL audit
file.  Goals, source text, request headers, bearer tokens, and message payloads
are never recorded.

The implementation is process-wide, matching the current one-node-per-process
Trealla port. Aggregate metrics contain no principal identifiers. The detailed
runtime snapshot does, and is intended only for the authenticated admin route.
*/

:- use_module(library(json), [json_chars//1]).
:- use_module(actors, [live_actor_count/1]).
:- use_module(auth_policy, [principal_id/2]).
:- use_module(governance_policy,
              [current_governance_policy/1,current_governance_usage/1]).
:- use_module(resource_policy, [current_resource_policy/1]).
:- use_module(node_tokens, [token_count/1,current_tokens_file/1]).
:- use_module(ip_policy, [current_ip_policy/1,current_ip_usage/1]).

:- meta_predicate observe_request(+, +, +, 0).

:- dynamic observability_config/5.
:- dynamic observability_counter/2.
:- dynamic observability_event/2.
:- dynamic observability_sequence/1.
:- dynamic observability_activity/6.

:- catch(mutex_create(_, [alias('$node_observability')]),
         error(permission_error(create, mutex, '$node_observability'), _),
         true).

default_observability_config(500, off, 10485760, 5).

reset_observability :-
    default_observability_config(Capacity, File, MaxBytes, Backups),
    get_time(Started),
    with_mutex('$node_observability',
        reset_observability_locked(Capacity, File, MaxBytes, Backups, Started)).

configure_observability(Options,
                        observability_config(Capacity,File,MaxBytes,Backups)) :-
    default_observability_config(DCapacity, DFile, DMaxBytes, DBackups),
    option(log_capacity(Capacity0), Options, DCapacity),
    compatible_option(audit_log_file, interaction_log_file,
                      Options, DFile, File0),
    compatible_option(max_audit_log_bytes, max_interaction_log_bytes,
                      Options, DMaxBytes, MaxBytes0),
    compatible_option(max_audit_log_backups, max_interaction_log_backups,
                      Options, DBackups, Backups0),
    normalize_positive(log_capacity, Capacity0, Capacity),
    normalize_audit_file(File0, File),
    normalize_limit(max_audit_log_bytes, MaxBytes0, MaxBytes),
    normalize_nonnegative(max_audit_log_backups, Backups0, Backups),
    get_time(Started),
    with_mutex('$node_observability',
        reset_observability_locked(Capacity, File, MaxBytes, Backups, Started)).

compatible_option(Preferred, _, Options, _, Value) :-
    Option =.. [Preferred,Value], memberchk(Option, Options), !.
compatible_option(_, Compatible, Options, Default, Value) :-
    Option =.. [Compatible,Value],
    ( memberchk(Option, Options) -> true ; Value = Default ).

reset_observability_locked(Capacity, File, MaxBytes, Backups, Started) :-
    retractall(observability_config(_,_,_,_,_)),
    assertz(observability_config(Capacity,File,MaxBytes,Backups,Started)),
    retractall(observability_counter(_,_)),
    retractall(observability_event(_,_)),
    retractall(observability_sequence(_)),
    assertz(observability_sequence(0)),
    retractall(observability_activity(_,_,_,_,_,_)).

normalize_positive(_, Value, Value) :- integer(Value), Value > 0, !.
normalize_positive(Name, Value, _) :-
    throw(error(domain_error(Name, Value), observability)).

normalize_nonnegative(_, Value, Value) :- integer(Value), Value >= 0, !.
normalize_nonnegative(Name, Value, _) :-
    throw(error(domain_error(Name, Value), observability)).

normalize_limit(_, unlimited, unlimited) :- !.
normalize_limit(Name, Value, Value) :- normalize_positive(Name, Value, Value).

normalize_audit_file(off, off) :- !.
normalize_audit_file(File, File) :- atom(File), File \== '', !.
normalize_audit_file(Name, _) :-
    throw(error(domain_error(audit_log_file, Name), observability)).

%! observe_request(+Principal, +Transport, +Operation, :Goal) is semidet.

observe_request(Principal, Transport, Operation, Goal) :-
    get_time(Started),
    with_mutex('$node_observability', increment_counter_locked(requests_total)),
    catch(( call(Goal) -> Outcome = success ; Outcome = failure ), Error,
          ( finish_observed_request(Principal, Transport, Operation, Started,
                                    error, Error),
            throw(Error) )),
    finish_observed_request(Principal, Transport, Operation, Started,
                            Outcome, none),
    Outcome == success.

finish_observed_request(Principal, Transport, Operation, Started,
                        Status, Detail0) :-
    get_time(Finished), DurationMs is max(0, round((Finished-Started)*1000)),
    ( Status == error
    -> with_mutex('$node_observability',
          ( increment_counter_locked(errors_total),
            increment_error_rejection_locked(Detail0) ))
    ; true
    ),
    event_detail(Detail0, Detail),
    principal_text(Principal, PrincipalText),
    append_event(request, Status, PrincipalText, Transport, Operation,
                 DurationMs, Detail).

observe_rejection(Principal, Transport, Operation, Error) :-
    rejection_reason(Error, Reason),
    with_mutex('$node_observability',
        ( increment_counter_locked(rejections_total),
          increment_counter_locked(rejection(Reason)) )),
    event_detail(Error, Detail),
    principal_text(Principal, PrincipalText),
    append_event(rejection, denied, PrincipalText, Transport, Operation,
                 0, Detail).

observe_activity_start(Kind, Key, Principal, Transport) :-
    principal_text(Principal, PrincipalText),
    get_time(Started),
    with_mutex('$node_observability',
        ( retractall(observability_activity(Kind,Key,_,_,_,_)),
          assertz(observability_activity(Kind,Key,PrincipalText,Transport,
                                         Started,active)),
          append_event_locked(activity, started, PrincipalText, Transport,
                              Kind, 0, '') )).

observe_activity_end(Kind, Key, Reason) :-
    with_mutex('$node_observability',
        ( retract(observability_activity(Kind,Key,Principal,Transport,
                                         Started,active))
        -> get_time(Finished),
           DurationMs is max(0, round((Finished-Started)*1000)),
           event_detail(Reason, Detail),
           append_event_locked(activity, stopped, Principal, Transport,
                               Kind, DurationMs, Detail)
        ; true )).

principal_text(Principal, Text) :-
    ( principal_id(Principal, Id) -> term_text(Id, Text)
    ; term_text(Principal, Text)
    ).

event_detail(none, '') :- !.
event_detail(error(rate_limit_exceeded(_,Resource,Limit,Window), _), Detail) :- !,
    format(atom(Detail), 'rate_limit_exceeded(~q,~q,~q)',
           [Resource,Limit,Window]).
event_detail(error(resource_limit_exceeded(_,Resource,Limit), _), Detail) :- !,
    format(atom(Detail), 'resource_limit_exceeded(~q,~q)', [Resource,Limit]).
event_detail(error(authentication_required(Route), _), Detail) :- !,
    format(atom(Detail), 'authentication_required(~q)', [Route]).
event_detail(error(authorization_error(_,Capability), _), Detail) :- !,
    format(atom(Detail), 'authorization_error(~q)', [Capability]).
event_detail(error(permission_error(_,sandboxed,_), _), sandbox_denied) :- !.
event_detail(error(permission_error(_,sandboxed_directive,_), _), sandbox_denied) :- !.
event_detail(error(Form, _), Detail) :- !,
    functor(Form, Name, Arity), format(atom(Detail), 'error(~w/~w)', [Name,Arity]).
event_detail(Detail0, Detail) :-
    term_text(Detail0, Full), atom_chars(Full, Chars),
    prefix_chars(Chars, 512, Prefix), atom_chars(Detail, Prefix).

prefix_chars(_, 0, []) :- !.
prefix_chars([], _, []).
prefix_chars([C|Cs], N, [C|Rest]) :-
    N1 is N-1, prefix_chars(Cs, N1, Rest).

term_text(Term, Text) :- atom(Term), !, Text = Term.
term_text(Term, Text) :- format(atom(Text), '~q', [Term]).

rejection_reason(error(authentication_required(_), _), auth) :- !.
rejection_reason(error(authorization_error(_, _), _), auth) :- !.
rejection_reason(error(profile_violation(_, _), _), profile) :- !.
rejection_reason(error(rate_limit_exceeded(_,_,_,_), _), rate_limit) :- !.
rejection_reason(error(resource_limit_exceeded(_,_,_), _), resource) :- !.
rejection_reason(error(resource_error(_), _), resource) :- !.
rejection_reason(error(permission_error(access, client_ip, _), _), ip_policy) :- !.
rejection_reason(error(permission_error(_, sandboxed, _), _), sandbox) :- !.
rejection_reason(error(permission_error(_, sandboxed_directive, _), _), sandbox) :- !.
rejection_reason(_, other).

increment_error_rejection_locked(Error) :-
    rejection_reason(Error, Reason),
    ( Reason == other -> true
    ; increment_counter_locked(rejections_total),
      increment_counter_locked(rejection(Reason))
    ).

increment_counter_locked(Name) :-
    ( retract(observability_counter(Name, Count0)) -> Count is Count0+1
    ; Count = 1
    ),
    assertz(observability_counter(Name, Count)).

append_event(Type, Status, Principal, Transport, Operation, Duration, Detail) :-
    with_mutex('$node_observability',
        append_event_locked(Type, Status, Principal, Transport, Operation,
                            Duration, Detail)).

append_event_locked(Type, Status, Principal, Transport, Operation,
                    Duration, Detail) :-
    retract(observability_sequence(Seq0)), Seq is Seq0+1,
    assertz(observability_sequence(Seq)), get_time(Timestamp),
    Event = event(Seq,Timestamp,Type,Status,Principal,Transport,Operation,
                  Duration,Detail),
    assertz(observability_event(Seq, Event)),
    enforce_event_capacity_locked,
    catch(append_audit_event_locked(Event), _,
          increment_counter_locked(audit_write_errors_total)).

enforce_event_capacity_locked :-
    observability_config(Capacity,_,_,_,_),
    findall(Seq, observability_event(Seq,_), Seqs), length(Seqs, Count),
    Excess is Count-Capacity,
    drop_old_events(Excess).

drop_old_events(N) :- N =< 0, !.
drop_old_events(N) :-
    retract(observability_event(_,_)), N1 is N-1, drop_old_events(N1).

append_audit_event_locked(_) :-
    observability_config(_,off,_,_,_), !.
append_audit_event_locked(Event) :-
    observability_config(_,File,MaxBytes,Backups,_),
    rotate_audit_if_needed(File, MaxBytes, Backups),
    event_json(Event, JSON), phrase(json_chars(JSON), Chars),
    setup_call_cleanup(open(File, append, Stream, [encoding(utf8)]),
        ( format(Stream, '~s', [Chars]), nl(Stream) ), close(Stream)).

rotate_audit_if_needed(_, unlimited, _) :- !.
rotate_audit_if_needed(File, MaxBytes, Backups) :-
    exists_file(File), size_file(File, Size), Size >= MaxBytes, !,
    rotate_audit_backups(File, Backups).
rotate_audit_if_needed(_, _, _).

rotate_audit_backups(File, Backups) :-
    ( Backups =:= 0 -> catch(delete_file(File), _, true)
    ; audit_backup_name(File, Backups, Oldest),
      ( exists_file(Oldest) -> catch(delete_file(Oldest), _, true) ; true ),
      Previous is Backups-1, shift_audit_backups(File, Previous),
      audit_backup_name(File, 1, First),
      catch(rename_file(File, First), _, true)
    ).

shift_audit_backups(_, N) :- N =< 0, !.
shift_audit_backups(File, N) :-
    audit_backup_name(File, N, From), Next is N+1,
    audit_backup_name(File, Next, To),
    ( exists_file(From) -> catch(rename_file(From, To), _, true) ; true ),
    N1 is N-1, shift_audit_backups(File, N1).

audit_backup_name(File, Number, Backup) :-
    format(atom(Backup), '~w.~w', [File,Number]).

%! current_observability_snapshot(-Snapshot) is det.

current_observability_snapshot(
    observability_snapshot(Started,Counters,Activities,Events)) :-
    with_mutex('$node_observability',
        ( observability_config(_,_,_,_,Started),
          findall(Name-Count, observability_counter(Name,Count), Counters),
          findall(activity(Kind,Key,Principal,Transport,Since),
                  observability_activity(Kind,Key,Principal,Transport,Since,active),
                  Activities),
          findall(Event, observability_event(_,Event), Events) )).

activity_count(Kind, Activities, Count) :-
    findall(Key, member(activity(Kind,Key,_,_,_), Activities), Keys),
    length(Keys, Count).

%! node_metrics_text(-Text) is det.

node_metrics_text(Text) :-
    current_observability_snapshot(
        observability_snapshot(Started,Counters,Activities,Events)),
    get_time(Now), Uptime is max(0, Now-Started),
    live_actor_count(LiveActors),
    activity_count(ws_connection, Activities, WSConnections),
    activity_count(isotope_session, Activities, Sessions),
    activity_count(ws_actor, Activities, WSActors),
    length(Events, Retained),
    counter_from(Counters, requests_total, Requests),
    counter_from(Counters, errors_total, Errors),
    counter_from(Counters, audit_write_errors_total, AuditErrors),
    current_governance_policy(
        governance_policy(_,CallRate,SpawnRate,WSRate,InflightLimit,WSActorLimit)),
    current_resource_policy(resource_policy(_,_,ActorLimit,_,_,_,_)),
    limit_metric_value(InflightLimit, InflightMetric),
    limit_metric_value(WSActorLimit, WSActorMetric),
    limit_metric_value(ActorLimit, ActorMetric),
    limit_metric_value(CallRate, CallRateMetric),
    limit_metric_value(SpawnRate, SpawnRateMetric),
    limit_metric_value(WSRate, WSRateMetric),
    metric_blocks([
        gauge(web_prolog_uptime_seconds, 'Seconds since this node started.', Uptime),
        gauge(web_prolog_live_actors, 'Live actors in this Trealla process.', LiveActors),
        gauge(web_prolog_active_ws_connections, 'Active ACTOR WebSocket connections.', WSConnections),
        gauge(web_prolog_active_sessions, 'Active ISOTOPE sessions.', Sessions),
        gauge(web_prolog_active_ws_actors, 'Active WebSocket-owned actors.', WSActors),
        gauge(web_prolog_log_retained_events, 'Audit events currently retained.', Retained),
        counter(web_prolog_requests_total, 'Execution requests admitted and processed.', Requests),
        counter(web_prolog_errors_total, 'Admitted execution requests that raised an error.', Errors),
        counter(web_prolog_audit_write_errors_total, 'Failed durable audit-log appends.', AuditErrors),
        gauge(web_prolog_limit_max_inflight_calls, 'Max concurrent HTTP calls; 0 means unlimited.', InflightMetric),
        gauge(web_prolog_limit_max_actors, 'Global live-actor cap; 0 means unlimited.', ActorMetric),
        gauge(web_prolog_limit_max_ws_actors_per_principal, 'WebSocket actor cap per principal; 0 means unlimited.', WSActorMetric),
        gauge(web_prolog_limit_call_requests_per_window, 'HTTP call rate ceiling; 0 means unlimited.', CallRateMetric),
        gauge(web_prolog_limit_session_spawns_per_window, 'Session-spawn rate ceiling; 0 means unlimited.', SpawnRateMetric),
        gauge(web_prolog_limit_ws_commands_per_window, 'WebSocket command rate ceiling; 0 means unlimited.', WSRateMetric)
    ], Lines0),
    rejection_metric_lines(Counters, RejectionLines),
    append(Lines0, RejectionLines, Lines),
    atomic_list_concat(Lines, '\n', Body), atom_concat(Body, '\n', Text).

counter_from(Counters, Name, Count) :-
    ( memberchk(Name-Count, Counters) -> true ; Count = 0 ).

limit_metric_value(unlimited, 0) :- !.
limit_metric_value(Value, Value).

metric_blocks([], []).
metric_blocks([Spec|Specs], Lines) :-
    metric_block(Spec, Block), metric_blocks(Specs, Rest), append(Block, Rest, Lines).

metric_block(gauge(Name, Help, Value), Lines) :- metric_block(Name,Help,gauge,Value,Lines).
metric_block(counter(Name, Help, Value), Lines) :- metric_block(Name,Help,counter,Value,Lines).
metric_block(Name, Help, Type, Value, [HelpLine,TypeLine,Sample]) :-
    format(atom(HelpLine), '# HELP ~w ~w', [Name,Help]),
    format(atom(TypeLine), '# TYPE ~w ~w', [Name,Type]),
    format(atom(Sample), '~w ~w', [Name,Value]).

rejection_metric_lines(Counters, [Help,Type|Samples]) :-
    Help = '# HELP web_prolog_rejections_total Requests refused, by reason.',
    Type = '# TYPE web_prolog_rejections_total counter',
    rejection_reasons(Reasons), rejection_samples(Reasons, Counters, Samples).

rejection_reasons([auth,profile,sandbox,rate_limit,resource,ip_policy,other]).
rejection_samples([], _, []).
rejection_samples([Reason|Reasons], Counters, [Sample|Samples]) :-
    counter_from(Counters, rejection(Reason), Count),
    format(atom(Sample), 'web_prolog_rejections_total{reason="~w"} ~w',
           [Reason,Count]),
    rejection_samples(Reasons, Counters, Samples).

%! node_runtime_json(-JSONAtom) is det.

node_runtime_json(JSONAtom) :-
    current_observability_snapshot(
        observability_snapshot(Started,Counters,Activities,Events)),
    get_time(Now), Uptime is max(0, Now-Started),
    live_actor_count(LiveActors),
    activity_count(ws_connection, Activities, WSConnections),
    activity_count(isotope_session, Activities, Sessions),
    activity_count(ws_actor, Activities, WSActors),
    length(Events, Retained),
    recent_error_count(Events, RecentErrors),
    current_governance_policy(GovernancePolicy),
    current_resource_policy(ResourcePolicy),
    current_ip_policy(IPPolicy),
    current_ip_usage(IPUsage),
    current_governance_usage(GovernanceUsage),
    token_count(TokenCount),
    ( current_tokens_file(TokenFile)
    -> TokenStoreJSON = string_atom(TokenFile), TokensPersistent = true
    ; TokenStoreJSON = null, TokensPersistent = false
    ),
    counters_json(Counters, CountersJSON), events_json(Events, EventsJSON),
    governance_usage_json(GovernanceUsage, UsageJSON),
    GovernanceUsage = governance_usage(Rates, _), rates_json(Rates, RatesJSON),
    activities_json(ws_connection, Activities, ConnectionsJSON),
    activities_json(isotope_session, Activities, SessionsJSON),
    activities_json(ws_actor, Activities, ActorsJSON),
    term_text(GovernancePolicy, GovernanceText),
    term_text(ResourcePolicy, ResourceText),
    term_text(IPPolicy, IPPolicyText),
    term_text(IPUsage, IPUsageText),
    json_object([active_sessions-number(Sessions),
                 active_ws_connections-number(WSConnections),
                 active_ws_actors-number(WSActors),
                 retained_events-number(Retained),
                 recent_errors-number(RecentErrors)], ActivitySummaryJSON),
    json_object([live_actors-number(LiveActors),
                 resource_policy-string_atom(ResourceText)], LimitUsageJSON),
    json_object([
        started_at-number(Started), uptime_seconds-number(Uptime),
        live_actors-number(LiveActors),
        active_ws_connections-number(WSConnections),
        active_ws_actors-number(WSActors), retained_events-number(Retained),
        governance_policy-string_atom(GovernanceText),
        resource_policy-string_atom(ResourceText),
        ip_policy-string_atom(IPPolicyText),
        ip_usage-string_atom(IPUsageText),
        token_count-number(TokenCount),
        tokens_persistent-boolean(TokensPersistent),
        tokens_file-TokenStoreJSON,
        counters-CountersJSON, governance-UsageJSON,
        sessions-list(SessionsJSON), ws_connections-list(ConnectionsJSON),
        ws_actors-list(ActorsJSON), limit_usage-LimitUsageJSON,
        rate_limits-list(RatesJSON), activity_summary-ActivitySummaryJSON,
        recent_events-list(EventsJSON)
    ], JSON),
    phrase(json_chars(JSON), Chars), atom_chars(JSONAtom, Chars).

counters_json(Counters, JSON) :-
    counters_json_fields(Counters, Fields), json_object(Fields, JSON).
counters_json_fields([], []).
counters_json_fields([Name-Count|Counters], [Key-number(Count)|Fields]) :-
    term_text(Name, Key), counters_json_fields(Counters, Fields).

events_json([], []).
events_json([Event|Events], [JSON|JSONEvents]) :-
    event_json(Event, JSON), events_json(Events, JSONEvents).

recent_error_count(Events, Count) :-
    findall(Seq,
            ( member(event(Seq,_,_,Status,_,_,_,_,_), Events),
              memberchk(Status, [error,denied]) ),
            Errors),
    length(Errors, Count).

activities_json(_, [], []).
activities_json(Kind, [activity(Kind0,Key,Principal,Transport,Since)|Activities],
                JSONActivities) :-
    ( Kind0 == Kind
    -> term_text(Key, KeyText),
       json_object([kind-string_atom(Kind),key-string_atom(KeyText),
                    principal-string_atom(Principal),
                    transport-string_atom(Transport),since-number(Since)], JSON),
       JSONActivities = [JSON|Rest]
    ; JSONActivities = Rest
    ),
    activities_json(Kind, Activities, Rest).

event_json(event(Seq,Timestamp,EventType,Status,Principal,Transport,Operation,
                 Duration,Detail), JSON) :-
    json_object([
        seq-number(Seq), ts-number(Timestamp), event_type-string_atom(EventType),
        status-string_atom(Status), principal-string_atom(Principal),
        transport-string_atom(Transport), operation-string_atom(Operation),
        duration_ms-number(Duration), detail-string_atom(Detail)
    ], JSON).

governance_usage_json(governance_usage(Rates, Capacities), JSON) :-
    rates_json(Rates, RateJSON), capacities_json(Capacities, CapacityJSON),
    json_object([rate_limits-list(RateJSON), capacities-list(CapacityJSON)], JSON).

rates_json([], []).
rates_json([rate(Kind,Identity,Count,Limit)|Rates], [JSON|JSONRates]) :-
    term_text(Identity, IdentityText), term_text(Limit, LimitText),
    json_object([kind-string_atom(Kind),identity-string_atom(IdentityText),
                 count-number(Count),limit-string_atom(LimitText)], JSON),
    rates_json(Rates, JSONRates).

capacities_json([], []).
capacities_json([capacity(Kind,Identity,Reserved,Active,Limit)|Capacities],
                [JSON|JSONCapacities]) :-
    term_text(Identity, IdentityText), term_text(Limit, LimitText),
    json_object([kind-string_atom(Kind),identity-string_atom(IdentityText),
                 reserved-number(Reserved),active-number(Active),
                 limit-string_atom(LimitText)], JSON),
    capacities_json(Capacities, JSONCapacities).

json_object(Fields, pairs(Pairs)) :- json_fields(Fields, Pairs).
json_fields([], []).
json_fields([Key-Value0|Fields], [string(KeyChars)-Value|Pairs]) :-
    atom_chars(Key, KeyChars), json_value(Value0, Value),
    json_fields(Fields, Pairs).

json_value(string_atom(Atom), string(Chars)) :- !, term_text(Atom, Text), atom_chars(Text, Chars).
json_value(Value, Value).

:- initialization(reset_observability).
