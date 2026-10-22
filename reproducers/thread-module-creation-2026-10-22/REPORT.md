# Thread-time module creation: guard-only candidate verification

Date: 22 October 2026. The separate candidate repairs both confirmed null-parser
logging reads. Installed runtime, production port sources and live nodes are
unchanged. The report and candidate patch were submitted as [Trealla #1177](https://github.com/trealla-prolog/trealla-prolog/issues/1177).
The published diff matches the tested patch byte-for-byte.

## Builds and patch

Base: unmodified upstream v3.14.5,
`beed430deca9fa48adf028541ea4c3e2bd8d3641`.

Candidate checkout:
`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-http-timeout/null-parser-repair-2026-10-22`.

Build command:
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk make NOSSL=1 NOFFI=1 -j4`.
Each executable uses its matching adjacent standard library. The untouched base
checkout is clean; the candidate differs only in the two null guards and new
regression files. It does not include the separate module-import repair.

- [Submitted upstream report](../bug-029-thread-module-creation.md).
- [Candidate patch with regression tests](../bug-029-thread-module-creation.patch).
- [Provenance and hashes](provenance.json).
- `git apply --check` succeeds on the untouched base checkout.

## Evidence and results

- [Diagnosis](diagnosis.json): saved native crash fields and matching unmodified
  function disassembly identify the null `q->top` access before module creation.
- [Six-case initial corrected comparison](guard-checks.json).
- [Unmodified comparison](unmodified-checks.json): five fresh processes per case;
  both new-module thread paths crash 5/5; existing-module and command controls
  pass 5/5 each.
- [Candidate comparison](candidate-checks.json): twenty fresh processes per case,
  all six cases pass, **120/120**. Expected output includes informational messages
  only for the two command-query cases. Tests verify the child status and actual
  loaded/asserted predicate contents in the child and parent.
- [Original thread-import diagnostic](original-thread-import.json): all three
  runs print `status(true)`, exit 0 and have empty stderr.
- [Engine regressions](engine-regressions.json): the new regression crashes on
  unmodified and passes on candidate; five existing module-related groups also
  pass with exact stdout, exit 0 and empty stderr.

The original baseline thread-import crash evidence remains in
[the earlier investigation](../port-promise-callback-hang-2026-10-22/thread-file-import-unmodified.json).

The retained comparison runner deliberately records failing baseline trials;
its own successful exit is not an all-engines-pass assertion. Reproduce:

```sh
python3 reproducers/bug-029-thread-module-creation.py \
  --engine baseline=/path/to/unmodified/tpl --engine candidate=/path/to/guarded/tpl \
  --runs 20 --output /tmp/thread-module-results.json
```

The first draft test passed an unsupported interned atom to `load_text/2`.
That fixture was corrected to use a valid character list before the retained
complete comparisons. Variable module qualifiers ensure compilation does not
pre-create the destination and accidentally bypass the new-module branch.

## Boundaries

No source-loading policy, import/reconsult semantics, module ownership or general
thread lifecycle behavior is changed. The new source contains no Web Prolog
imports. Tests run native threads sequentially, not a stress audit of competing
module creators. #1176 and the intermittent lifecycle/property crash remain
separate. No combined guard-plus-import-patch build, full engine/application
suite, live interoperability run, TLS, WASM or other OS testing is claimed.

The pinned executable hash is still
`34cbf9796d4c4310b2f6bb122d2e820fc446089173b2ab39e5a6faa48ef56563`.
No installed engine was replaced. Review/report this bounded guard patch
separately; these passing checks alone do not approve an engine upgrade.

## Submission record

Duplicate search covered open and closed issues and related pull requests. #582
concerns the text-loading API; #1176 is the independent module-import issue.
No duplicate of this null-parser crash was found.

- [Published issue body](submitted-issue-body.md).
- [Submission screenshot](issue-1177-submitted.png).
- Published patch SHA256: `e867742d09fb011f43c3e86bc5cf7d8b1009134d3194c81a01884dc3cb72c5e0`.
