# Trealla actor write/1 routing — 25 October 2026

Sandboxed `write/1` now follows the same trusted rewrite as `writeln/1`:
`actors:terminal_output(Term,[source(io)])`. It is admitted in actor whitelist
mode and removed from the blacklist; `write/2` remains explicitly forbidden.
No other I/O permission is widened. Source validation and runtime guarded calls
still run before execution. The term is data, not an executable formatting goal.
No engine or unification change is involved.

## Tests

- [New unit regressions](regressions.log) pass in blacklist and whitelist modes:
  term-variable sharing is preserved, output uses the inherited target, complete
  calls through `call/1` work, and stream access is denied at admission/runtime.
  Internal tests protect nested helper qualification with `call/1`, as the
  existing Trealla adapter requires; general outer qualification is unchanged.
- [Existing sandbox/isolation/toplevel groups](related-checks.json) all pass.
- Identical public assertions on disposable SWI/Trealla nodes: 18/18 shared output
  cases pass; two separate Trealla stream-denial checks also pass. They cover
  atoms, explicit character lists, Unicode, compounds, complete computed goals,
  private source, copied child helpers and output while backtracking.
- Temporary deployment preflight and actual public n5: 11/11 checks each pass.
- [Actual UI](n5-write-verified.png): `write(abc)` prints `abc`; `write("abc")`
  prints `[a,b,c]`, then succeeds. Double-quote reading has not changed.

The shared matrix and exact candidate source/binary hashes are in
`trinity-conformance/reports/2026-10-25-write-output/`. The selected engine is
unmodified Trealla v3.14.10 with matching separate libraries. The SWI reference
uses the separate verified 10.1.18 build and its current source candidate.
No full-suite, GNU, WASM or experimental SWI text-mode claim is made.

## n5 activation

After preflight, only the n5 backend was restarted, from PID 91435 to PID 94384.
The public URL remains <http://localhost:3060/portal> with backend port 3062.
Its configuration/node information is identical. The n3 PID 91992, frontend PID
91509 and auxiliary 3061 PID 97669 retain their original commands/start times.
The installed Trealla binary/hash and matching library selection are unchanged.

Active frozen source:

```
~/.local/share/trinity-local-nodes/write-output-2026-10-25/trealla-active-source
```

This copies the previous frozen n5 source, adding only the tested
`sandbox_policy.pl` repair. The active durable entry remains
`~/.local/share/trinity-local-nodes/n5/start.sh`. Rollback is retained at:

```
~/.local/share/trinity-local-nodes/write-output-2026-10-25/rollback-start.sh
```

Stop the recorded current backend before starting that rollback launcher. Keep
the existing frontend running. Do not start a second listener on 3062.
[Deployment record](deployment.json), [preflight](preflight.json) and
[live answers](live-n5.json) retain configuration, process and source hashes.
The restart uses the existing installed engine, without changing its target.

The shared manual documents this actor output path and the retained stream
restriction. Book examples, dependency pin, native SWI source and text-reading
modes are unchanged by this batch. Cyclic message/exception limitations and
other existing I/O differences remain separate. No commit or push was made.
