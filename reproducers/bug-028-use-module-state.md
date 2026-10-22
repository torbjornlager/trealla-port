# Upstream report: file-path use_module reconsults an existing module and erases runtime state

Submitted 22 October 2026 as [Trealla #1176](https://github.com/trealla-prolog/trealla-prolog/issues/1176).
The issue includes the complete candidate patch and tests inline. Its patch was
fetched back and verified byte-for-byte against the tested local patch.
The [submitted body](port-promise-callback-hang-2026-10-22/submitted-issue-body.md)
preserves the published text. No direct duplicate was found in the open/closed
issues and import-related PRs checked. Installed runtimes remain unchanged.

## Summary

On Trealla v3.14.5 at `beed430deca9fa48adf028541ea4c3e2bd8d3641`, importing
an already-loaded module by file path into another module removes facts asserted
into the first module's dynamic predicates. The corresponding module-name import
preserves them. Trealla v3.13.10 preserves them in both cases.

In the Web Prolog port this clears actor registrations and promises during actor
bootstrap. The child then raises a missing-promise error and the parent cannot
receive its startup acknowledgement. The reduction below does not use Web Prolog,
threads, sockets, queues or callbacks.

## Minimal reproducer

`state-library.pl`:

```prolog
:- module(callback_probe_state,[state/1]).
:- dynamic state/1.
```

`import-state.pl`:

```prolog
:- use_module('state-library.pl').
run(Path) :-
    assertz(callback_probe_state:state(kept)),
    format(atom(Text),':- use_module(~q).',[Path]),
    load_text(Text,[module(callback_probe_importer)]),
    findall(X,callback_probe_state:state(X),After),
    writeq(After),nl.
```

Run with each executable's matching standard library:

```sh
TPL_LIBRARY_PATH=/path/to/build/library /path/to/build/tpl \
  -g "consult('import-state.pl'),run('/absolute/path/state-library.pl'),halt"
```

Expected: `[kept]`. Actual on unmodified v3.14.5: `[]`.
Replacing the path argument with `callback_probe_state` returns `[kept]`.

The [checked reproducer and runner](port-promise-callback-hang-2026-10-22/REPORT.md)
add explicit assertions, bounded fresh-process runs and raw output. Five trials
per case confirm the difference on each engine.

## Candidate repair

[Candidate patch](bug-028-use-module-state.patch), based on `beed430`:

- Carry an import/reload distinction through the private file-loading helpers to
  the parser. Keep the public C `load_file` and `load_fp` signatures unchanged.
- For an ordinary file-path `use_module` (including the existing selective,
  reexport and autoload dispatch), reuse an existing module at its `module/2`
  declaration instead of entering the explicit-reconsult unload branch.
- Leave explicit `consult/1` and `make/0` reload behavior on the existing path.
- Add `tests/sundry/use_module_state.sh` and its expected output.

The candidate deliberately does not repair general preservation of runtime
clauses during an explicitly requested reload, introduce global loader locking,
or change path resolution and Web Prolog promise handling. No installed engine
or application runtime source was changed.

## Verification

Separate macOS arm64 build, SDK 15.4, `NOSSL=1 NOFFI=1`; no installation or live-node
restart. This is a candidate on the stated revision, not a claim about later
upstream changes. TLS, WASM and other operating systems were not tested.

- Original callback check: pinned passes 5/5; unmodified v3.14.5 times out 5/5;
  candidate passes 5/5. Candidate stage trace shows startup return, callback
  answer `waiting`, normal termination notification and final cleanup.
- Standalone file-import preservation: candidate passes 5/5; both engines retain
  state in the module-name control. Both actual actor and promise tables survive
  the candidate's import probes.
- New engine regression fails on unmodified (`failed(full)`) and passes on the
  candidate. It covers full/selective imports, the existing reexport path, an
  import into a pre-created module from a native thread, unchanged state when
  the source file changes, and subsequent explicit consult reloading the file.
  The thread test mirrors the port's pre-created temporary modules; it does not
  claim coverage of creating a new module inside `load_text/2` in a thread.
- Existing engine regressions `reconsult_module`, `make_module_state`,
  `make_same_second`, `make_failed_load` and `runtime_consult_base` all pass with
  exact expected output and zero exit status.
- Complete port promise correctness group and focused HTTP timeout/cleanup,
  callback and retry fixture pass on the candidate.

### Separate diagnostics and limits

A supplemental lifecycle group crashed once in `do_thread_property_pin_both`
while testing delivery/cleanup races, then passed three repeat runs. Three
unmodified-build runs also passed. The initial crash is retained; these results
neither attribute it to this patch nor establish that it is unrelated.

A different standalone diagnostic creating a new importer module inside a native
thread crashes 3/3 with SIGSEGV on both unmodified and candidate engines. It is
outside this repair; pre-creating the destination module avoids that diagnostic
path in the import regression. Its reproducer and raw results are retained
separately. These findings are reasons not to treat the candidate as an approved
upgrade, rather than waivers for failing import assertions.

Evidence and build/patch hashes:
[repair results](port-promise-callback-hang-2026-10-22/CANDIDATE.md).
