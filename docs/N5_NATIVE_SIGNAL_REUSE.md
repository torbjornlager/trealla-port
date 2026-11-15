# N5 native cancellation and WebSocket upgrades

A reduced test on the deployed v3.14.20 engine delivered a signal addressed to
an exited detached thread to a different thread that reused its native storage.
All ten raw trials reproduced the wrong recipient. Native thread identifiers
continue increasing, which lets the receiver reject that stale control goal.
The engine binary has not been changed.

RPC promise disposal previously signalled an unconditional
`throw('$rpc_promise_disposed')`. A late delivery can therefore terminate an
unrelated accepted HTTP worker before its upgrade response, or a browser relay
before startup acknowledgement. A controlled TLS → Caddy → Nginx → Trealla test
of that pre-upgrade failure returns HTTP 502 with no client watchdog firing.
The same controlled delivery with the receiver guard completes HTTP 101,
welcome, session creation, a query and halt.

`native_thread_control:signal/2` carries the intended native thread identifier
and checks it inside the receiving thread before running the control goal.
`cancel/1` uses the same check before the existing native `thread_exit(cancelled)`
unwind. Promise disposal, toplevel abort, connection shutdown, remote-reader
cancellation, standalone WebSocket listener stop and native fallback exit use
these guarded controls. Logical actor exit already checks its actor identity.
Public API availability, capabilities, wire formats, deadlines and limits are
unchanged. There is no retry or timeout increase.

The historical failed container's stderr was lost during its automatic rollback,
so its exact exception cannot be recovered. The engine race and matching HTTP
502 path are reproduced independently; attributing that particular historical
occurrence to this path remains an inference.

Run the focused regression with the matching engine/library:

```sh
/opt/trealla/tpl -g "consult(native_thread_control_tests),native_thread_control_tests:run,halt"
```

The unit group verifies intended delivery and cancellation, rejection in the
wrong receiver, sandbox denial of this internal module, and detached-thread
reuse. It is included in `tools/test.sh unit`. The standalone reproducer
`reproducers/n5-native-signal-reuse-2026-11-15.pl` compares raw and guarded
signals; raw misdelivery is reported, not required on future fixed engines.

This is a port-side safeguard for fatal control signals, not a general repair
of the engine's native message implementation. No upstream issue or comment
has been posted. An unrelated failing-source preparation hang remains separate;
its unfinished startup-acknowledgement prototype was archived during cleanup.
