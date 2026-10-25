# library(json): combine UTF-16 surrogate escapes into Unicode scalar values

Submitted with the complete candidate patch and regressions as
[Trealla #1181](https://github.com/trealla-prolog/trealla-prolog/issues/1181).

Tested base: unmodified Trealla v3.14.10,
`4ef56e3bbbcc6ca44085a4aa5eae0e6848c70294`, macOS arm64. The candidate uses
that exact base with only the attached JSON-library and regression-test patch.
Build settings: SDK 15.4, `NOSSL=1 NOFFI=1`. At submission, upstream HEAD
was the exact tested commit and its JSON library matched the control byte-for-byte.
The duplicate search found related closed reader issues #398/#399; they are
cross-linked in the new library-specific issue. See [submission.json](submission.json)
and the exact published [issue body](ISSUE_BODY.md).

## Minimal reproducer

No Web Prolog code is needed:

```prolog
:- use_module(library(json)).
:- use_module(library(lists)).

probe(Codes) :-
    phrase(json_chars(string(Chars)), "\"\\uD83D\\uDE00\""),
    maplist(char_code, Chars, Codes).
```

Expected `Codes = [128512]` (U+1F600). Actual on the control build:
`Codes = [55357,56832]` (two surrogate values). Raw UTF-8 `"😀"` decodes to
the expected scalar, so the failure depends on JSON spelling, not the character.

When the decoded string is subsequently passed to `read_term_from_atom/3`,
Trealla rejects the resulting malformed text with
`error(representation_error(character),read_term_from_atom/3)`. Python's normal
`json.dumps` output exposes this in JSON-carried Prolog goals, but the bug is
independent of that application or the choice of Prolog double-quote semantics.

[RFC 8259 section 7](https://www.rfc-editor.org/rfc/rfc8259#section-7)
describes the paired UTF-16 escape representation for supplementary characters.
The proposed treatment of *unpaired* surrogates is a separate scalar-text
policy: fail to parse them rather than manufacture malformed character atoms.
[Section 8.2](https://www.rfc-editor.org/rfc/rfc8259#section-8.2) discusses those
non-Unicode sequences; their presence in the JSON grammar does not establish
that they are Unicode scalar values. The patch should not be presented as a
claim that the RFC mandates this particular rejection policy.

## Candidate patch

[`trealla-json-surrogate-pairs.patch`](trealla-json-surrogate-pairs.patch)
changes `library/json.pl` and adds `tests/sundry/json_unicode.pl` plus its
expected output. It applies cleanly to the exact unmodified base above.

- Decode a valid high/low surrogate pair as one scalar.
- Retain BMP and ordinary/raw UTF-8 handling.
- Reject isolated/reversed/mismatched surrogate escapes and raw surrogate values.
- Support the valid paired spelling when matching a supplied character, and
  generation of escaped supplementary scalars without truncating them to 16 bits.
- Preserve the library's relational parsing/generation alternatives. Instantiation
  checks only schedule arithmetic for known values; no cuts select one spelling.

The patch changes no C engine source, exports, runtime flags or Web Prolog code.

## Verification

| Check | Control | Candidate |
|---|---|---|
| Standalone raw/escaped ASCII, BMP, U+1F600 and U+10FFFF controls | 6 pass; 2 reader errors | 8 pass; 0 reader errors |
| New JSON regressions | 20 pass; 17 fail | 37 pass; 0 fail |
| Expected-output comparison using upstream test command convention | mismatch | exact match |
| Existing Web Prolog WebSocket regressions | not rerun in this batch | pass |
| Four previously blocked portable-text cases, TXT-008/020/025/026 | fail in prior committed run | all pass |

The regression coverage includes first/last supplementary scalars, boundaries
around the surrogate range, case-insensitive hex, adjacent pairs, literal
backslashes, ordinary escapes, object keys, arrays, matching bound characters,
generation and a subsequent Prolog-reader call.

The upstream harness's `-g halt` command convention exits zero for the failing
control initialization as well, so verification checks the expected output and
explicit assertion counts, not exit status alone. The attached expected output
distinguishes the control's 17 failures from the candidate's passing output.

The complete finite supplementary-character reproduction and all evidence are
described in [`REPORT.md`](REPORT.md). These are targeted checks, not a claim
that the full engine suite, TLS/FFI, every Unicode scalar or every codec has been
tested. Installed runtimes and the user's running nodes were not changed.
