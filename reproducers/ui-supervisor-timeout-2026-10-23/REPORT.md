# UI supervisor timeout diagnosis — 23 October 2026

No production runtime source or installed executable changed. Tests use the
separate unmodified v3.14.8 build `42ebc21` and its matching library.

## Confirmed chain

The inline child `start(receive({stop -> true}))` resolves receive/1 to the
actors framework module. supervisor_actor:child_source_module/5 then treats
that library definition as a local source predicate and materializes this clause:

```prolog
receive(Clauses) :- receive(Clauses, []).
```

[Spawn trace](trace-root-upstream.log) records this exact src_list in the child
spawn request. The child enters private-source preparation. Its generated
`'$actor_qualify_goal'/2` processes the receive/2 body, passing the unbound
Clauses into `'$actor_qualify_receive'/2`. That helper's first clause matches
`{Clauses0}` without first checking for a variable, recursively inventing brace
wrappers rather than preserving a runtime-supplied variable.

The [direct qualification probe](qualification-probe.pl) reaches its before
marker, then hits the two-second external watchdog (exit 124), with no after
marker: [log](qualification.log), [process record](qualification.json).
The [observer trace](trace-observer.log) finds the child's actor namespace but
no source-ready namespace, consistent with preparation not completing.
The supervisor is waiting for the child's startup handshake and never reaches
its request loop, so count_children times out. The requesting UI is not the
cause. Earlier public comparisons reproduce it on both pinned and upstream.

A [test-only no-copy adapter](no-copy-control.pl) intercepts this one child spawn
and removes only the copied receive clause, leaving the framework implementation
available through the ordinary bootstrap. The otherwise same child/count/halt/
monitor computation then returns:

```text
success(...,[[specs-1,active-1,supervisors-0,workers-1]-true],false)
```

[Control output](no-copy-control.log), [process record](no-copy-control.json).
This is a single diagnostic control, not a completed production patch or suite.

## Proposed bounded repair

1. Exclude framework-provided entry predicates from automatic supervisor source
   copying while retaining genuine user-defined helpers and source context.
   Apply the check wherever this automatic child source selection occurs.
2. Add a variable case before structural matching in the generated receive
   qualifier so deferred receive clauses cannot produce an infinite brace loop.
3. Regress inline receive children, helper-based children, dynamic additions,
   variable receive clauses, ordinary source copying, shutdown and independent
   monitors. Rerun supervisor/isolation groups and the exact public UI case.

This is a port adapter/source-selection repair, not an established upstream
engine defect. It needs no protocol, timeout-policy, supervisor shutdown-policy
or book-example change. The unrelated lost handshakes and temporary-node exit
137 from acceptance are not explained or declared fixed by this diagnosis.

Initial trusted probe runs from the fixture directory produced missing-library
warnings; the retained trace-root/observer/control runs execute from the required
port root. An initial qualification probe imported isolation alone and lacked
its actor dependencies; the retained direct probe imports web_prolog. Return
code 0 from the diagnostic wrapper alone is not interpreted as correctness.

## Implemented repair and verification

The preceding diagnosis is the pre-repair record. Production source is now
changed in the working tree (the installed engine remains unchanged):

- `supervisor_actor.pl`: automatic source selection excludes framework defining
  modules at the shared local-predicate check. The check uses module identity,
  not predicate names; ordinary user helpers retain their copying path. Initial,
  nested and dynamic source collection reuse this check.
- `isolation.pl`: receive qualification preserves clause-set variables rather
  than inventing brace structures. Source bodies using receive/1 or receive/2
  with a variable defer qualification through a local bootstrap bridge until
  execution. That bridge is available again in copied private source, so body
  helpers and timeout callbacks resolve in the child rather than the sender.
- `supervisor_source_tests.pl` and `tools/test.sh`: add eight focused checks for
  framework/user selection, initial and dynamic inline children, user helpers,
  variable receive/1 and receive/2 callbacks, unrelated/default/additional
  monitors, and variable identity. README records the runtime details.

All focused cases pass in the completed unit run. An earlier guard-only draft
loaded variable receive source but lost its callback context (`missing_body`);
[that draft's result](focused-fixed-final.log) is retained to explain the deferred
qualification bridge. It was corrected before final verification.

### Verification against the separate unmodified v3.14.8 engine

- Canonical supervisor behaviour: **20/20** pass; private source isolation:
  **20/20** pass in the same bounded process. [Log](supervisor-isolation.log),
  [exit record](supervisor-isolation.json).
- Full `tools/test.sh unit` rerun: **73/73 invocation groups pass**, exit 0,
  including the new regression group, startup/restart/intensity/monitor and
  sandbox/source checks. [Log](units-repeat.log), [record](units-repeat.json).
- The preceding full run stopped at worker-scope interruption with
  `coordinator_failed(exception(missing_unrelated))`. [Log](units-final.log),
  [record](units-final.json). No worker code or assertion was changed; it passed
  in the full rerun. This intermittent observation is retained, not declared
  repaired or proved independent of every change. An earlier unit draft run
  stopped at the then-incomplete new variable receive case; its log remains
  `units-after-fix.log`.
- Original public-WebSocket reproduction with ping-pong source: **3/3 pass**,
  deterministic counts for one active child, supervisor halt and termination
  delivery. [Raw results](public-fixed.json) and per-trial logs.
- Real UI, same temporary N5-style fixture and unchanged ping-pong source loaded
  through the examples drawer: the original query passes with one active child
  and `Reason=true`. A second query dynamically adds the inline child, returns
  `Added=ok`, then halts and consumes its down notification; the before/after
  actor lists are identical. [Transcript](ui-fixed-transcript.txt),
  [screenshot](ui-supervisor-fixed.png).

The temporary UI fixture was stopped after testing. The installed executable
hash is unchanged and original N3/N5 processes remain. See
[repair provenance](repair-provenance.json). No book examples, shutdown policy,
wire protocol or installed engine changed. The acceptance checkpoint's earlier
process exit 137 and lost-handshake observations are not declared fixed by this
repair; the three completed public probes and UI checks do not certify absence
of intermittent failures. Native interoperability/conformance and full engine
suites from the acceptance checkpoint were not rerun after these source edits;
the requested supervisor/isolation regressions and UI example were rerun.
