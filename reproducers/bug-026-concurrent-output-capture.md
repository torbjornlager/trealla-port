# BUG-026: Output capture mixes text between threads

**Status:** Prepared on 2026-10-21; not submitted. Reproduced with the port's
pinned Trealla v3.13.10 build, revision
`36f512f595e407e330f6e1f6b4eb339da2b0675e`, on macOS arm64. Current upstream
has not been tested for this report. No engine changes were made.

## Proposed upstream report

Two overlapping `with_output_to(atom(...), Goal)` calls in different threads
share captured output. Text written by one thread appears in the other thread's
result. The attached `bug-026-concurrent-output-capture.pl` needs no application
modules, networking, source loading or timing-dependent sleeps. Messages force
the relevant interleaving:

1. The child begins capturing, writes `alpha`, then signals `ready`.
2. The main thread begins capturing, writes `beta`, then signals `go`.
3. The child writes `omega` and signals `wrote`.
4. The main thread ends its capture and lets the child finish its capture.

Run from this repository, or copy the adjacent Prolog file elsewhere:

```sh
/path/to/tpl -g "consult('reproducers/bug-026-concurrent-output-capture.pl'),(concurrent_output_capture:run->halt;halt(1))"
```

Expected: `actual(beta,alphaomega)` and exit status 0.

Actual on the tested Trealla build: `actual(betaomega,alpha)` and exit status 1.
SWI-Prolog 10.1.17 returns the expected result and status 0 on the same machine.
The standalone test leaves both threads joined before checking the results.

In this revision, `library/builtins.pl` implements `with_output_to/2` using
`'$capture_output'/0` and `'$capture_output_to_atom'/1`. In
`src/bif_streams.c`, both select `q->pl->streams[q->pl->current_output]`.
`begin_capture` puts captures on that shared stream's capture stack and buffer.
Consequently a write by the child while the main thread's capture is on top
belongs to the main thread's capture. This reproducer shows incorrect output
without concurrent module creation or parsing, independently of issue #1173.

Application impact: our actor loader generated bootstrap Prolog text using
output capture. In a separate application-level test, two concurrent calls,
each expected to return the same 20,829-character bootstrap, instead returned
40,951 and 299 characters. This provides a plausible explanation for an earlier
intermittent actor-startup parsing failure. That original failure did not recur
in 30 complete repeat runs, so its attribution is not conclusive.

Our bounded application workaround builds source using query-local
`format(atom(...), ...)` fragments and serializes replies using
`write_term_to_atom/3`. We have not patched the engine or changed public
`with_output_to/2` semantics.

Tested Trealla executable SHA-256:
`34cbf9796d4c4310b2f6bb122d2e820fc446089173b2ab39e5a6faa48ef56563`.
