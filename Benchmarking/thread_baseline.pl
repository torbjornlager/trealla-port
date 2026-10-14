% SPDX-License-Identifier: MIT

/** <module> Raw thread baselines for the actor comparison */

benchmark_raw_threads(Count) :-
    get_time(T0),
    benchmark_raw_threads_(Count),
    get_time(T1),
    benchmark_raw_report(thread_lifecycle, Count, T0, T1).

benchmark_raw_threads_(0) :- !.
benchmark_raw_threads_(N) :-
    thread_create(true, Thread, []),
    thread_join(Thread, _),
    N1 is N - 1,
    benchmark_raw_threads_(N1).

% Trealla-specific diagnostic: perform the private namespace/bootstrap work
% synchronously, without creating an actor thread.
benchmark_trealla_namespaces(Count) :-
    get_time(T0),
    benchmark_trealla_namespaces_(Count),
    get_time(T1),
    benchmark_raw_report(namespace_lifecycle, Count, T0, T1).

benchmark_trealla_namespaces_(0) :- !.
benchmark_trealla_namespaces_(N) :-
    isolation:prepare_actor(N, user, [], _),
    isolation:cleanup_actor(N),
    N1 is N - 1,
    benchmark_trealla_namespaces_(N1).

benchmark_raw_ping_pong(RoundTrips) :-
    thread_create(benchmark_raw_pong, Pong, []),
    benchmark_raw_ping_batch(Pong, 100),
    get_time(T0),
    benchmark_raw_ping_batch(Pong, RoundTrips),
    get_time(T1),
    thread_send_message(Pong, stop),
    thread_join(Pong, _),
    benchmark_raw_report(thread_ping_pong, RoundTrips, T0, T1).

benchmark_raw_ping_batch(Pong, RoundTrips) :-
    thread_self(Self),
    benchmark_raw_ping_rounds(RoundTrips, Pong, Self).

benchmark_raw_ping_rounds(0, _, _) :- !.
benchmark_raw_ping_rounds(N, Pong, Self) :-
    thread_send_message(Pong, ping(Self)),
    thread_get_message(pong),
    N1 is N - 1,
    benchmark_raw_ping_rounds(N1, Pong, Self).

benchmark_raw_pong :-
    thread_get_message(Message),
    ( Message = ping(From)
    -> thread_send_message(From, pong),
       benchmark_raw_pong
    ; Message == stop
    -> true
    ).

benchmark_raw_report(Name, Count, T0, T1) :-
    Microseconds is round((T1 - T0) * 1000000),
    format('BENCHMARK_RESULT(~q,~d,~d).~n',
           [Name, Count, Microseconds]).
