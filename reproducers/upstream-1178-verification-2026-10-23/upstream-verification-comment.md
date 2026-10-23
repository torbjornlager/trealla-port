Thanks for the fix! Verified a separate, unmodified build of v3.14.8 at `42ebc2127e3f900036c6bcb54cfc11bec4762eb7` on macOS arm64, with its matching standard library (`NOSSL=1 NOFFI=1`, SDK 15.4). Our installed runtime was left unchanged.

Results, using fresh processes and external watchdogs:

- Standalone minimal and concurrent cancellation probes: **30/30 processes each**, ten cases per process, with no crashes.
- Strict cancellation-status check: **20/20 runs, 6,000 cancellations**, accepting `running` or `exited(cancelled)` while observable and rejecting the previously observed erroneous `status(true)`. Its inherited retirement-error handler accepts both `existence_error` and the older dispatch `uninstantiation_error`, so this is not certification of every retired-handle error classification.
- Full Web Prolog lifecycle group: **30/30 processes**; focused hard-cancel cases: **300/300**.
- Your new `thread_status_retirement` regression: **5/5 exact-output passes**; eight existing thread regression groups also pass.

**Qualification:** the unchanged exceptional-termination diagnostic with a tight 1,000-poll budget completed 18/20 runs. The other two exhausted that polling budget without SIGSEGV and exited 0 without the required completion marker; they remain recorded as failures. A separate version using a measured two-second retirement deadline, with no sleeps, completed **20/20 runs, 20,000 exceptional terminations**. No observed exception/cancellation SIGSEGV remains in these checks. The counts above are from the stated snapshot, not a full engine/platform certification.

[Full verification record and retained failures](https://github.com/torbjornlager/trealla-port/blob/539b334050a365ce51c44b442fe2a36d12b24bba/reproducers/upstream-1178-verification-2026-10-23/REPORT.md).

**Separate confirmation of the existing mutex-exit fix:** we also independently checked a v3.13.10-based separate build containing the cancellation/status backport plus upstream `2024825a`'s `do_unlock_all()`. Its C source differs from the control only in that function and comments; the function matches upstream v3.14.5 exactly. The repair passed **30/30 delivery-race processes and 30/30 full lifecycle processes**. The control lacking that function change failed **7/60**, with six mutex-ownership errors and one stall. The repaired build additionally passed **533/533 engine tests and 72/72 Web Prolog unit groups**. Those suite counts concern the separate backport build, not the unmodified v3.14.8 build. This supports the already-landed mutex-exit fix; no additional patch is proposed. The exact failing instruction interleaving was not observed directly.

[Independent mutex-exit verification and control results](https://github.com/torbjornlager/trealla-port/blob/c74f7c159327aa56b5cf08844208e86abd2342bb/reproducers/unlock-all-independent-verification-2026-10-23/REPORT.md).

Closing this reported status-payload crash as fixed, with the qualifications above. General lifecycle diagnostics remain separate; #1176 and #1177 remain open pending their own verification.
