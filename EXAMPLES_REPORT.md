# Report on `ping-pong.pl` and `benchmarking.pl`

Tested against Trealla v2.97.13 (latest at time of writing) with the
trealla-port modules. v2.95.12 numbers are kept for comparison.

## TL;DR

Both examples are **logically correct** and run end-to-end on Trealla.

- `ping-pong.pl` was mildly flaky on v2.95.12 (~10% crash rate at
  N=30 + halt) and is **rock-solid on v2.97.13** (10/10 OK).
- `benchmarking.pl` is still flaky on v2.97.13 — actually slightly
  worse for the chain-spawn pattern, indicating that the recent
  `bif_threads.c` improvements addressed the message-bouncing case
  (ping-pong) but not the spawn-and-wait-for-ack chain.

The trealla-port's own test sweep also improved on v2.97.13 (from
~67% to ~90% reliable in one process), confirming that whatever was
fixed upstream affects message-passing patterns broadly. The
remaining flakiness is upstream-only and not caused by anything in
the port.

## `ping-pong.pl`

```prolog
:- use_module(actors).

ping(0, Pong_Pid) :-
    Pong_Pid ! finished,
    format('Ping finished.~n',[]).
ping(N, Pong_Pid) :-
    self(Self),
    Pong_Pid ! ping(Self),
    receive({pong -> format('Ping received pong.~n',[])}),
    N1 is N - 1,
    ping(N1, Pong_Pid).

pong :-
    receive({
        finished -> format('Pong finished.~n',[]);
        ping(Ping_Pid) ->
            format('Pong received ping.~n',[]),
            Ping_Pid ! pong,
            pong
    }).

ping_pong :-
    spawn(pong, Pong_Pid),
    spawn(ping(30, Pong_Pid)).
```

### Analysis

The example is correct. Two actors bounce a `ping`/`pong` exchange
N times; on the N+1-th iteration `ping` sends `finished`, both
actors print their farewell, both exit cleanly.

### Empirical behaviour

| Invocation                                             | v2.95.12 | v2.97.13 |
|--------------------------------------------------------|----------|----------|
| small N (1–25) sleep+halt                              | reliable | reliable |
| N=30 explicit `spawn+spawn+sleep+halt`, 5 runs         | 5/5      | 5/5      |
| `ping_pong, sleep(5), halt` (file as written), 10 runs | 9/10     | **10/10** |

### Conclusion

Fully reliable on v2.97.13.

## `benchmarking.pl`

```prolog
:- use_module(actors).

start(Num) :-
    self(Self),
    start_proc(Num, Self).

start_proc(0, Pid) :- !,
    Pid ! ok.
start_proc(Num, Pid) :-
    Num1 is Num-1,
    spawn(start_proc(Num1, Pid), NPid),
    NPid ! ok,
    receive({ok -> true}).
```

### Analysis

This is a chain-of-spawn microbenchmark. At first reading it looks
broken because each non-leaf parent does `spawn → send to child →
receive in own mailbox` and there's no obvious sender to its own
mailbox. But the trick is that **the parent's own `receive` picks up
the `ok` that *its* parent sent it just after spawning it**:

Trace for `start(2)`:

| Actor    | Action                                                          | Mailbox after        |
|----------|-----------------------------------------------------------------|----------------------|
| Top      | `spawn(start_proc(1, Top), A)`                                  | (Top empty, A empty) |
| Top      | `A ! ok`                                                        | A: `[ok]`            |
| Top      | `receive({ok -> true})` — blocks                                |                      |
| A        | `spawn(start_proc(0, Top), B)`                                  | B: `[]`              |
| A        | `B ! ok`                                                        | B: `[ok]`            |
| A        | `receive({ok -> true})` — picks up the `ok` Top sent at line 2  | A: `[]`              |
| A        | (no more code) — exits                                          |                      |
| B        | clause 1: `Top ! ok`                                            | Top: `[ok]`          |
| B        | exits                                                           |                      |
| Top      | receive matches; `start(2)` returns                             |                      |

So the algorithm IS correct: every actor receives exactly one `ok`,
the leaf sends one `ok` back to the original caller. No actor is
orphaned.

### Empirical behaviour

Pass / hang-at-startup / segfault counts on the latest tpl:

| N    | v2.95.12              | v2.97.13              |
|------|-----------------------|-----------------------|
|  1–2 | reliable              | reliable              |
|  3   | 10/0/0  (10 runs)     | 9/1/0   (10 runs)     |
| 10   | 2/3/0 (5 runs)        | 3/5/2  (10 runs)      |
| 100  | mostly hang           | 0/3/2  (5 runs)       |
| 500  | crash                 | crash                 |

(Format: `pass / hang / crash`; "hang at startup" = process alive
but never produced any Prolog output.)

The v2.97.13 thread-rework helped the message-bouncing case
(ping-pong, test sweep) but the chain-spawn-with-ack pattern of
benchmarking is, if anything, slightly more flaky now.

### Cross-check: is the flakiness specific to this example?

The trealla-port's own test sweep, which spawns dozens of actors
across 21 sequential tests in a single process:

| Workload                                | v2.95.12 | v2.97.13 |
|-----------------------------------------|----------|----------|
| Full t1..t21 sweep, single tpl process  | 2/3 OK   | **9/10 OK** |
| Per-test loop (one tpl per test)        | 21/21    | 21/21    |

So upstream improved the message-bouncing case substantially, but
not chain-spawn-with-ack.

### A small variant to confirm it's not link/exit semantics

I tried the same code with `spawn(..., NPid, [link(false)])` to
remove parent→child link propagation: behaviour was indistinguishable
(same hang/crash rate). So the flakiness isn't about `link`.

### Conclusion

The example is logically correct. The hangs and segfaults are caused
by races in Trealla's thread-create / thread-cleanup paths in
v2.97.13. The pattern that triggers it is "spawn → send → receive in
own mailbox" repeated in a chain. The ping-pong pattern, which is
"spawn two long-lived actors and bounce messages between them", is
unaffected.

## Recommendations

1. **Don't change the example sources** — they're correct as written.

2. **`ping-pong.pl` is good to ship as-is on v2.97.13.**

3. **Track `benchmarking.pl` upstream.** A minimal reproducer is
   exactly the file as supplied: `tpl -g "consult(benchmarking),
   start(10), writeln(done), halt"` repeated in a loop will produce
   roughly 50–70% bad outcomes (hang at startup or segfault at
   halt). The same tpl handles ping-pong perfectly, so the bug is
   specifically in the chain-spawn-with-ack path, not in spawn or
   receive in general.

4. **For the trealla-port test runner**, the per-test loop
   (`for t in t1..t21; do tpl -g "consult(tests), $t, halt"; done`)
   was 100% reliable on both v2.95.12 and v2.97.13 and is the
   recommended way to run the suite if absolute reliability is
   required. The all-in-one `tpl -g "consult(tests), t1,...,t21,
   halt"` form is now ~90% reliable on v2.97.13, which is fine for
   interactive use.
