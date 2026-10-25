# Supplementary Unicode JSON repair — 25 October 2026

Status: candidate verified in a **separate build**; report and complete patch
submitted as [Trealla #1181](https://github.com/trealla-prolog/trealla-prolog/issues/1181). The installed Trealla/SWI runtimes, their launchers, runtime
source working files and n3/n5 remain unchanged. Pending Boolean/URI work is
preserved and excluded from the disposable-node source archives.

## Cause and repair

`library(json)` reads each `\uXXXX` as an independent character. A supplementary
scalar such as U+1F600 therefore becomes surrogate values 55357 and 56832;
passing that decoded text to Trealla's reader produces a character representation
error. Raw UTF-8 works. The standalone probe uses only the engine's JSON library
and reader, with no Web Prolog modules.

The candidate combines UTF-16 surrogate pairs, rejects unpaired/malformed ones,
and preserves ordinary escapes, BMP characters and raw UTF-8. It handles paired
escaped generation and supplied-character matching, while retaining relational
alternatives. Rejecting lone surrogates is an explicit scalar-text policy,
qualified in the [upstream report](UPSTREAM.md), not a statement that JSON's
grammar excludes them.

No Web Prolog adapter or installed library is patched. The changed engine
checkout is:

`/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-supplementary-json-2026-10-25/engine`

Its base is exact v3.14.10 commit
`4ef56e3bbbcc6ca44085a4aa5eae0e6848c70294`. It was cloned without hard links
from the clean separate acceptance checkout. Build command:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
  make -j4 NOSSL=1 NOFFI=1
```

These match the control's optional-feature settings; TLS/FFI are unmeasured.
The first default build lacked optional FFI headers and was followed by a clean
build with these settings. No system package installation was needed.

## Results

| Check | Result |
|---|---|
| Standalone spelling controls, unchanged engine | 6 pass, 2 representation errors |
| Standalone spelling controls, candidate | 8 pass, no representation errors |
| Decoder regressions, unchanged engine | 20 pass, 17 fail |
| Decoder regressions, candidate | **37 pass, 0 fail** |
| Existing `websocket_tests` | pass |
| Supplementary TXT-008/020/025/026 | **4/4 pass** |
| Complete experimental pack, Trealla caller → SWI peer | **24 pass, 2 fail**, formerly 20 pass, 6 fail |
| Complete experimental pack, SWI caller → Trealla peer | 4 pass, 22 fail, unchanged |
| Result schema/count validation | both reports valid |
| Candidate whitespace and patch application checks | pass |

The two remaining Trealla-side configuration failures are unchanged and separate:
TXT-014 encounters an admission/instantiation error, and TXT-023's default SWI
peer does not implement the experimental character-list source convention.
SWI TXT-015's DCG sandbox block also remains. No required-profile pass/fail
claim is changed; the text draft remains experimental. The new candidate has
not been installed or substituted for historical coverage records.

The input case now reaches the input prompt and passes its Unicode reply
assertion; the round-trip case now reaches serialized-answer resubmission and
passes. This resolves the earlier report's uncertainty about those blocked
boundaries for the selected supplementary examples.

An initial test-harness experiment tried to enumerate every JSON rendering;
JSON whitespace permits unbounded alternatives, so that harness timed out.
It was replaced by bounded generation round trips and explicit escaped-form
matching. No node assertion or existing timeout was relaxed. Hex generation
also computes known digits before traversing alternatives. The final checks
finish normally and their exact commands/results are recorded.

## Files and reproduction

- [Minimal library-only example](minimal.pl), [minimal results](minimal-results.json).
- [Standalone probe](supplementary-json-controls.pl),
  [control/candidate results](standalone-results.json).
- [New regressions](json_unicode.pl), [expected output](json_unicode.expected),
  [assertion results](json-regression-results.json) and
  [upstream-harness comparison](upstream-harness-check.json).
- [Existing transport result](websocket-result.json).
- [Experimental raw reports and commands](conformance-candidate/provenance.json).
- [Candidate patch](trealla-json-surrogate-pairs.patch),
  [upstream report](UPSTREAM.md), [provenance](provenance.json).
- [Preservation checks](preservation.json).
- [Final verification summary](validation.json).
- [Submission record](submission.json), [published body](ISSUE_BODY.md) and
  [browser confirmation](submission.png). The body and exact patch were verified
  against GitHub after submission; prepared-stage provenance remains historical.

Run the regressions with the candidate and its adjacent library:

```sh
TPL_LIBRARY_PATH=/path/to/candidate/engine/library \
  /path/to/candidate/engine/tpl -q -f -g halt json_unicode.pl
```

Compare stdout exactly with `json_unicode.expected`: the control initialization
reports failures but its final `-g halt` exits zero, so exit status alone is
insufficient. `json-regression-results.json` records the parsed counts/status.
For the standalone spelling probe, use `-f supplementary-json-controls.pl -g main`.
The disposable conformance adapter's exact commands and archived source hashes
are in its provenance. It does not change reader flags or public-node settings.

Only candidate JSON code and focused tests were built/run here. Full engine,
full Web Prolog lifecycle, browser and GNU suites were not run. Both owned
disposable nodes were stopped; preservation compares sources, engines/libraries,
installed targets/hashes, dependency pin and original n3/n5 process identities.
