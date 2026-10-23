# Candidate: interruption-safe dequeue and thread-local snapshot for selective receive

## Request

Would an interruption-safe dequeue-and-save primitive be appropriate for Trealla? Attached is a small candidate implementation and standalone tests. This is a request for a handoff facility, **not a claim that ordinary `thread_get_message/2-3` promises to roll back a successful receive when a later goal throws**.

Our Web Prolog selective receive adapter removes a native message, evaluates guards, and retains non-matches in a thread-local deferred queue. A `thread_signal/2` exception can occur after native removal and before the Prolog code commits that message to non-backtrackable storage. Catching guard exceptions does not cover the whole handoff. `setup_call_cleanup/3` does not make its setup atomic against thread signals, and an exception unwinds the acquired message's binding.

The natural regression reproduces on the original pinned build (`36f512f595e407e330f6e1f6b4eb339da2b0675e`) and unmodified v3.14.8 (`42ebc2127e3f900036c6bcb54cfc11bec4762eb7`). Native selective-queue controls retain their unrelated message. The goal is an atomic handoff into Prolog-managed storage while leaving waits interruptible.

## Candidate interface (private, open to API revision)

```prolog
'$thread_get_message_saved'(+Queue, ?Message, +Options, +Key, +'$bb'(Template))
```

It uses the existing `thread_get_message/3` options, matching, and waiting machinery. Once `Message` matches, it copies the now-bound template into the caller's non-backtrackable thread-local global, then removes the native queue item, within the same builtin execution and queue lock. No Prolog goal or thread-signal checkpoint runs between those two operations.

The `$bb` wrapper deliberately reuses the existing `$gvar_put/3` value-image representation. This is a private candidate interface, not a proposed Web Prolog language predicate or a settled public Trealla API. It is useful for a template to share a variable with `Message`, so that the snapshot can include both existing deferred messages and the acquired message.

```prolog
append(Deferred, [Message], Pending),
'$thread_get_message_saved'(Mailbox, Message, Options,
                            '$actor_deferred', '$bb'(Pending)).
```

A timeout does not change the saved value. Validation occurs before acquisition. If saving reports an allocation error, native removal does not occur. Allocation-failure behavior has been reviewed in the code; we have not fault-injected allocation failures in this batch. The persistent value uses the existing copying/global-variable implementation; message sharing within a term is retained, without aliasing the caller's live variables.

The existing queue predicates keep their behavior. The global-variable setter is factored into an internal helper so the new path shares its storage semantics.

## Standalone tests

`standalone.pl` has no Web Prolog dependencies. It deliberately gates execution after acquisition and before a subsequent Prolog `nb_setval/2`, making this legal interruption schedule deterministic. Original engines lose the message in that exposed window; candidates have already saved it. This controlled gate is a test device, not a claim that the engine spontaneously stalls there. A tight uninstrumented two-goal acquire/store smoke probe did not reproduce in its initial 1,000 trials; the natural adapter regression and the controlled schedule should not be confused.

```sh
TPL_LIBRARY_PATH=/path/to/engine/library /path/to/engine/tpl -g \
  "(catch((consult('standalone.pl'),receive_handoff_standalone:run),E,(writeq(E),nl,fail))->halt;halt(1))"
```

Observed:

| Engine | Controlled standalone |
| --- | --- |
| Original pinned | exit 1, `interruption(failed(missing_unrelated))` |
| Original unmodified v3.14.8 | same |
| Candidate pinned | 1,000 trials pass, exit 0 |
| Candidate v3.14.8 | 1,000 trials pass, exit 0 |

`primitive_tests.pl` independently checks timeout preservation, invalid templates, selective matching, ordering, variable sharing, copy independence, and 1,000 ungated interrupted native receives. The patch includes both standalone test files in the engine test harness, with expected output.

## Integrated verification

On each separate candidate build:

- 1,500 natural adapter-interruption trials: no missing messages.
- 1,500 native selective-receive controls: no missing messages.
- 100 fresh-process complete worker-scope regression runs: all pass.
- Adapter regression: 1,000 interruptions covering blocking, polling, timed, and absolute-deadline receives, plus guard rejection/control exceptions, consumption before body exceptions/failure, bindings, and duplicate detection: pass.
- Existing global-variable and threaded global-variable engine regressions: pass.
- Full Web Prolog port unit suite: 74 groups pass.

Original engines still fail the natural missing-message negative control with the compatibility fallback. They pass ordinary receive semantics. No installed engine has been replaced.

## Attachments and provenance

- `upstream-candidate.patch`: based on exact unmodified v3.14.8 revision above; code and engine-harness tests.
- `pinned-candidate.patch`: equivalent change against the pinned source revision.
- `standalone.pl`, `primitive_tests.pl`: standalone checks, no application dependencies.
- `REPORT.md`, `provenance.json`: build commands, exact binary/source/patch hashes and result locations.

Tested on macOS arm64, SDK 15.4, `NOSSL=1 NOFFI=1`. Submitted on 2026-10-23 as [Trealla #1179](https://github.com/trealla-prolog/trealla-prolog/issues/1179), including the complete candidate patch and standalone tests. No performance benchmark or allocation-failure fault injection is claimed.
