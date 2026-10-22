# BUG-026: Output capture mixes text between threads

**Closure verification (2026-10-22):** [Trealla #1174](https://github.com/trealla-prolog/trealla-prolog/issues/1174) is now closed as completed. The original message-controlled capture reproducer returned the expected result in 20/20 fresh-process trials. These checks use unmodified upstream v3.14.5 (`beed430`), not our candidate engine patches. Installed runtimes are unchanged. [Results and closure comments](upstream-closure-verification-2026-10-22/REPORT.md). Earlier observations below are retained as history.

**Status:** Submitted on 2026-10-21 as [Trealla issue #1174](https://github.com/trealla-prolog/trealla-prolog/issues/1174).
Retested on 2026-10-21 against a fresh,
unmodified current-upstream checkout. The duplicate search found no exact match.
The installed runtime and live nodes were left unchanged.

## Current-upstream retest

| Build | Revision | Fresh-process outcomes |
| --- | --- | --- |
| Pinned Trealla v3.13.10 | `36f512f595e407e330f6e1f6b4eb339da2b0675e` | 20/20 reproduced |
| Current-upstream Trealla v3.13.26 | `7af2b53c4eaa219c5f74b716f37e4f5e1b1917a6` | 20/20 reproduced |
| SWI-Prolog 10.1.17 control | installed executable | 5/5 correct |

Both Trealla builds printed `actual(betaomega,alpha)` and exited 1 in every
trial. The expected result is `actual(beta,alphaomega)` and exit 0. There were
no stderr diagnostics, native crashes or watchdog timeouts in these trials.
The message-controlled interleaving uses no sleeps. Each process had a
15-second external timeout.

The fresh upstream checkout was confirmed equal to `refs/heads/main` using
`git ls-remote` after testing, and its working tree remained clean. It is
retained at
`~/.local/share/trinity-runtime-tests/trealla-output-capture/upstream-2026-10-21`.
Build command, from that directory:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk make NOSSL=1 NOFFI=1 -j4
```

This is an unpatched native macOS arm64 build with threads enabled. TLS and
optional FFI are disabled; neither is exercised by the reproducer. The initial
build attempt without `NOFFI=1` stopped because `ffi.h` was unavailable. A clean
rebuild with the flags above completed. No installation command was run.
Each Trealla test process used the library directory adjacent to its executable
through its own `TPL_LIBRARY_PATH`; the shell environment was not changed.

The adjacent [fresh-process runner](bug-026-concurrent-output-capture.py) records
exact outputs, statuses and hashes in
[bug-026-capture-results.json](bug-026-capture-results.json). For example:

```sh
python3 reproducers/bug-026-concurrent-output-capture.py /path/to/tpl --runs 20 --output /tmp/capture-results.json
```

Runner exit 0 means all observations were classified as either reproduced or
correct; inspect the counts to distinguish them. The underlying reproducer
itself exits 1 when the defect is observed.
The pinned runtime's SHA-256 was checked before and after and is unchanged.
No engine patch, PATH change or live-node restart was performed.

## Duplicate search

Searched the upstream GitHub issue tracker on 2026-10-21 across open and closed
reports for `with_output_to`, `capture`, `current_output`, `capture thread`,
`output thread`, and `with_output_stream`, with additional title/comment searches.
No exact duplicate was found in the returned results. Closest related reports:

- [#51: Memory streams](https://github.com/trealla-prolog/trealla-prolog/issues/51)
  introduced output capture and discusses backtracking; its comments do not
  describe cross-thread capture isolation.
- [#595: Memory stream create/delete](https://github.com/trealla-prolog/trealla-prolog/issues/595)
  requests independently named/nested memory streams. Related design history,
  but no reproducer for two native threads contaminating `with_output_to/2`.
- [#1029: Issue with threading & stream output](https://github.com/trealla-prolog/trealla-prolog/issues/1029)
  concerns interleaving of multiple ordinary writes. Its comments note that
  SWI also interleaves those writes. Here SWI keeps the two captures separate,
  and explicit messages establish exactly which capture should own each write.

All three are closed. These findings support a separate report, with the related
issues linked for context; they cannot prove that no differently worded report
exists.

## Report background

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

Actual on both tested Trealla builds: `actual(betaomega,alpha)` and exit status 1.
SWI-Prolog 10.1.17 returns the expected result and status 0 on the same machine.
The standalone test leaves both threads joined before checking the results.

In both tested revisions, `library/builtins.pl` implements `with_output_to/2` using
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
