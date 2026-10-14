% SPDX-License-Identifier: MIT

/** <module> Cross-engine actor microbenchmarks

This file deliberately contains no engine-specific loading directive.  Load the
composed actor implementation first, then consult this file and call
benchmark_run/2.  Lifecycle actors receive their program through
src_predicates/1.  Chain and ping-pong use the normal source-free local spawn
path, matching the established chained-spawning and steady-state experiments.

The emitted time is elapsed wall time in microseconds.  Lifecycle and chain
measure their complete operation.  Ping-pong creates and warms the actors
before starting the clock, so it measures steady-state messaging.
*/

benchmark_run(lifecycle, Actors) :-
    get_time(T0),
    benchmark_lifecycles(Actors),
    get_time(T1),
    benchmark_report(lifecycle, Actors, T0, T1).
benchmark_run(chain, Actors) :-
    get_time(T0),
    self(Root),
    benchmark_chain_proc(Actors, Root),
    get_time(T1),
    benchmark_report(chain, Actors, T0, T1).
benchmark_run(ping_pong, RoundTrips) :-
    spawn(benchmark_pong, Pong, [
        link(false),
        monitor(true)
    ]),
    spawn(benchmark_ping_server(Pong), Ping, [
        link(false),
        monitor(true)
    ]),
    benchmark_ping_batch(Ping, 100),
    get_time(T0),
    benchmark_ping_batch(Ping, RoundTrips),
    get_time(T1),
    send(Ping, stop),
    send(Pong, stop),
    receive({down(Ping, _, true) -> true}),
    receive({down(Pong, _, true) -> true}),
    benchmark_report(ping_pong, RoundTrips, T0, T1).

benchmark_lifecycles(0) :- !.
benchmark_lifecycles(N) :-
    spawn(benchmark_idle, Pid, [
        link(false),
        monitor(true),
        src_predicates([benchmark_idle/0])
    ]),
    send(Pid, stop),
    receive({down(Pid, _, true) -> true}),
    N1 is N - 1,
    benchmark_lifecycles(N1).

benchmark_idle :-
    receive({stop -> true}).

benchmark_chain_proc(0, Root) :-
    send(Root, benchmark_chain_token).
benchmark_chain_proc(N, Root) :-
    N1 is N - 1,
    spawn(benchmark_chain_proc(N1, Root), Child, [
        link(false)
    ]),
    send(Child, benchmark_chain_token),
    receive({benchmark_chain_token -> true}).

benchmark_ping_batch(Ping, RoundTrips) :-
    self(Self),
    send(Ping, run(RoundTrips, Self)),
    receive({benchmark_ping_done -> true}).

benchmark_ping_server(Pong) :-
    receive({
        run(RoundTrips, From) ->
            benchmark_ping_rounds(RoundTrips, Pong),
            send(From, benchmark_ping_done),
            benchmark_ping_server(Pong);
        stop ->
            true
    }).

benchmark_ping_rounds(0, _).
benchmark_ping_rounds(N, Pong) :-
    self(Self),
    send(Pong, ping(Self)),
    receive({pong -> true}),
    N1 is N - 1,
    benchmark_ping_rounds(N1, Pong).

benchmark_pong :-
    receive({
        ping(From) ->
            send(From, pong),
            benchmark_pong;
        stop ->
            true
    }).

benchmark_report(Name, Count, T0, T1) :-
    Microseconds is round((T1 - T0) * 1000000),
    format('BENCHMARK_RESULT(~q,~d,~d).~n',
           [Name, Count, Microseconds]).
