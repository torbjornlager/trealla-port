# Native SWI receive-handoff check — 2026-10-23

## Answer

Our native SWI Web Prolog adapter also has an acquire-to-deferred-record interruption window. It should not be described as already interruption-safe. This is a defect in the adapter's handoff, not evidence that SWI's native `thread_get_message/2-3` violates its contract.

| Check | Installed SWI 10.1.17 | Separate SWI 10.1.18 build containing Jan's 09b6299 fix |
| --- | --- | --- |
| Controlled interruption between native acquire and deferred record | 20/20 missing-message assertions | 20/20 missing-message assertions |
| Ungated native selective-receive control | 5,000/5,000 pass | 5,000/5,000 pass |

The controlled processes exit 0 because the probe reports every observed outcome rather than asserting that all are successes. `results.json` records both process exits and the 20 `failed(missing_unrelated,absent,absent)` records per engine. These are failures of message preservation, not passes inferred from an exit code.

## Source and controlled schedule

The native adapter is `trinity-demonstrator/prolog/web_prolog/actors.pl`. `receive_scan/4` calls `receive_message/3`, then separately executes `assertz(deferred(Msg),Ref)`. Recording precedes guards, which preserves a message when a guard throws, but does not cover the earlier dequeue-to-record interval. The zero-time special case protects only peek/get with `sig_atomic/1`; it does not encompass deferred recording either.

The standalone check loads that unchanged adapter and uses SWI's `library(prolog_wrap)` to install a process-local wrapper around `actors:receive_message/3`. After native acquisition returns, before the existing `assertz/2`, the wrapper notifies the parent and waits at a gate. The parent signals the same `$abort_goal` control exception. After catching it, the owner checks both native and deferred storage and runs the original exact `down(unrelated,probe,killed)` receive assertion with timeout zero. Both storage locations are empty in every controlled failure.

The wrapper is test instrumentation, deliberately exposing a legal interruption point. No production file is edited and no live node is restarted. These counts demonstrate the gap; they are not a natural failure-rate measurement. An initial ungated adapter probe produced incomplete waits/late-signal diagnostics and is not counted as confirmed message-loss evidence. The controlled probe avoids relying on those ambiguous outcomes.

The native control uses the engine's selective receive for `never`, leaving the unrelated message in the native queue. Its final preservation assertion still goes through our actual Web Prolog adapter. All 5,000 controls on each engine finish with the expected message.

## Implication

Jan's earlier fix concerned zero-time native polling during cleanup. It does not close this separate adapter handoff gap. SWI provides signal-masking mechanisms that could support an adapter repair, but simply wrapping the whole blocking read in `sig_atomic/1` could postpone interruption indefinitely while no message arrives. A bounded repair must protect ownership transfer while keeping the wait interruptible and preserving guards, ordering, timeout behavior and accounting.

No native SWI repair or new upstream SWI bug attribution is claimed here. No installed SWI or Trealla engine was changed, and no runtime source file was changed for this comparison. The Trealla engine candidate and report were committed/pushed separately as `1423a50675efd93f742e3f1202dd8c35ce0af738`.

## Reproduction

From the trealla-port repository root:

```sh
python3 reproducers/swi-receive-handoff-check-2026-10-23/run.py
```

- `probe.pl`: process-local gated adapter check and ungated native control.
- `run.py`: exact executables, commands, 30-second subprocess watchdogs.
- `results.json`: complete output, versions, exit codes and missing-message counts.

The probe uses an absolute path to the sibling demonstrator checkout. It does not change that checkout. The installed SWI is `/Applications/swipl-win.app/Contents/MacOS/swipl`; the separate Jan-fix build is `/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299/build/src/swipl`.
