Tested base: unmodified Trealla v3.14.10,
`4ef56e3bbbcc6ca44085a4aa5eae0e6848c70294`, macOS arm64. The candidate uses
that exact base with only the attached JSON-library and regression-test patch.
Build settings: SDK 15.4, `NOSSL=1 NOFFI=1`. At submission, upstream HEAD is
the same tested commit and its `library/json.pl` matches the tested control
byte-for-byte.

Related closed reports: #398 and #399 cover the Prolog reader / `json(true)`
path. This report concerns the separate `library(json)` DCG (`json_chars//1`),
with a library-only reproducer. I found no matching library-specific issue or
surrogate-related open/closed pull request.

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
that they are Unicode scalar values. Rejecting isolated surrogates is a proposed policy choice; I am not claiming
that the RFC mandates this particular rejection policy.

## Candidate patch

The candidate patch included below changes `library/json.pl` and adds `tests/sundry/json_unicode.pl` plus its
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

These are targeted checks, not a claim that the full engine suite, TLS/FFI,
every Unicode scalar or every codec has been tested. Installed runtimes and
running application nodes were not changed.

Thank you for maintaining Trealla!


<details>
<summary>Candidate patch with 37 regression checks and expected output</summary>

```diff
diff --git a/library/json.pl b/library/json.pl
index dac2788..6bb56cf 100644
--- a/library/json.pl
+++ b/library/json.pl
@@ -147,22 +147,48 @@ json_character(PrintChar)  -->
     { dif(PrintChar, '\\'),
       dif(PrintChar, '"'),
       char_code(PrintChar, PrintCharCode),
-      PrintCharCode >= 32 }.
+      PrintCharCode >= 32,
+      json_scalar_value(PrintCharCode) }.
+% A JSON \u escape denotes a UTF-16 code unit. Supplementary scalar values
+% require a high/low surrogate pair; neither surrogate is a character itself.
 json_character(EscapeChar) -->
-        "\\u",
-        json_hex(H1),
-        json_hex(H2),
-        json_hex(H3),
-        json_hex(H4),
-        { (   nonvar(H1) ->
-              EscapeCharCode is H1 * 16^3 + H2 * 16^2 + H3 * 16 + H4,
-              char_code(EscapeChar, EscapeCharCode)
-          ;   char_code(EscapeChar, EscapeCharCode),
-              H1 is (EscapeCharCode // 16^3) mod 16,
-              H2 is (EscapeCharCode // 16^2) mod 16,
-              H3 is (EscapeCharCode // 16^1) mod 16,
-              H4 is (EscapeCharCode // 16^0) mod 16
-          ) }.
+        { ( nonvar(EscapeChar) -> char_code(EscapeChar, Code) ; true ) },
+        json_escaped_scalar(Code),
+        { char_code(EscapeChar, Code) }.
+
+json_scalar_value(Code) :-
+        Code >= 0, Code =< 0x10ffff,
+        ( Code < 0xd800 ; Code > 0xdfff ).
+
+json_bmp_scalar(Code) :-
+        Code >= 0, Code =< 0xffff,
+        ( Code < 0xd800 ; Code > 0xdfff ).
+
+json_escaped_scalar(Code) -->
+        { ( nonvar(Code) -> json_bmp_scalar(Code) ; true ) },
+        "\\u", json_hex_code(Code),
+        { json_bmp_scalar(Code) }.
+json_escaped_scalar(Code) -->
+        { ( nonvar(Code) ->
+              Code >= 0x10000, Code =< 0x10ffff,
+              High is 0xd800 + ((Code - 0x10000) // 0x400),
+              Low is 0xdc00 + ((Code - 0x10000) mod 0x400)
+          ; true ) },
+        "\\u", json_hex_code(High),
+        { High >= 0xd800, High =< 0xdbff },
+        "\\u", json_hex_code(Low),
+        { Low >= 0xdc00, Low =< 0xdfff,
+          Code is 0x10000 + (High - 0xd800) * 0x400 + Low - 0xdc00 }.
+
+json_hex_code(Code) -->
+        { ( nonvar(Code) ->
+              H1 is (Code // 16^3) mod 16,
+              H2 is (Code // 16^2) mod 16,
+              H3 is (Code // 16^1) mod 16,
+              H4 is Code mod 16
+          ; true ) },
+        json_hex(H1), json_hex(H2), json_hex(H3), json_hex(H4),
+        { Code is H1 * 16^3 + H2 * 16^2 + H3 * 16 + H4 }.
 
 json_hex(Digit) --> json_digit(Digit).
 json_hex(10)    --> "a".
diff --git a/tests/sundry/json_unicode.expected b/tests/sundry/json_unicode.expected
new file mode 100644
index 0000000..2eaf495
--- /dev/null
+++ b/tests/sundry/json_unicode.expected
@@ -0,0 +1,38 @@
+pass-ascii
+pass-bmp_escape
+pass-raw_supplementary
+pass-surrogate_pair
+pass-uppercase_pair
+pass-first_supplementary
+pass-last_scalar
+pass-before_surrogates
+pass-after_surrogates
+pass-noncharacter_scalar
+pass-nul_escape
+pass-adjacent_pairs
+pass-mixed_raw_escaped
+pass-literal_backslashes
+pass-quote_backslash
+pass-empty
+pass-high_alone
+pass-low_alone
+pass-high_then_bmp
+pass-low_then_high
+pass-two_highs
+pass-two_lows
+pass-truncated_pair
+pass-separated_pair
+pass-nonhex_escape
+pass-bound_pair_match
+pass-bound_wrong_scalar
+pass-no_truncated_generation
+pass-generate_ascii
+pass-generate_bmp
+pass-generate_nul
+pass-generate_first_supplementary
+pass-generate_emoji
+pass-generate_last_scalar
+pass-object_key_value
+pass-array
+pass-prolog_reader
+JSON Unicode: 37 passed, 0 failed
diff --git a/tests/sundry/json_unicode.pl b/tests/sundry/json_unicode.pl
new file mode 100644
index 0000000..2e11cdd
--- /dev/null
+++ b/tests/sundry/json_unicode.pl
@@ -0,0 +1,70 @@
+% JSON Unicode scalar and UTF-16 escape regressions.
+:- use_module(library(json)).
+:- initialization(main).
+
+codes([], []).
+codes([C|Cs], [N|Ns]) :- char_code(C,N), codes(Cs,Ns).
+parsed(Wire, Codes) :-
+    phrase(json_chars(string(Chars)), Wire), codes(Chars, Actual), Actual == Codes.
+rejected(Wire) :- \+ phrase(json_chars(_), Wire).
+scalar_round_trip(Code) :-
+    char_code(Char,Code),
+    once(phrase(json_chars(string([Char])), Wire)), parsed(Wire,[Code]).
+
+test(ascii, parsed("\"ab\"", [97,98])).
+test(bmp_escape, parsed("\"\\u00e5\"", [229])).
+test(raw_supplementary, parsed("\"😀\"", [128512])).
+test(surrogate_pair, parsed("\"\\ud83d\\ude00\"", [128512])).
+test(uppercase_pair, parsed("\"\\uD83D\\uDE00\"", [128512])).
+test(first_supplementary, parsed("\"\\ud800\\udc00\"", [65536])).
+test(last_scalar, parsed("\"\\udbff\\udfff\"", [1114111])).
+test(before_surrogates, parsed("\"\\ud7ff\"", [55295])).
+test(after_surrogates, parsed("\"\\ue000\"", [57344])).
+test(noncharacter_scalar, parsed("\"\\uffff\"", [65535])).
+test(nul_escape, parsed("\"\\u0000\"", [0])).
+test(adjacent_pairs, parsed("\"\\ud83d\\ude00\\ud83d\\udcbb\"", [128512,128187])).
+test(mixed_raw_escaped, parsed("\"aé\\ud83d\\ude00\\n\"", [97,233,128512,10])).
+test(literal_backslashes, parsed("\"\\\\ud83d\\\\ude00\"", [92,117,100,56,51,100,92,117,100,101,48,48])).
+test(quote_backslash, parsed("\"\\\"\\\\\"", [34,92])).
+test(empty, parsed("\"\"", [])).
+test(high_alone, rejected("\"\\ud800\"")).
+test(low_alone, rejected("\"\\udc00\"")).
+test(high_then_bmp, rejected("\"\\ud800\\u0061\"")).
+test(low_then_high, rejected("\"\\udc00\\ud800\"")).
+test(two_highs, rejected("\"\\ud800\\udbff\"")).
+test(two_lows, rejected("\"\\udc00\\udfff\"")).
+test(truncated_pair, rejected("\"\\ud800\\udc0\"")).
+test(separated_pair, rejected("\"\\ud800x\\udc00\"")).
+test(nonhex_escape, rejected("\"\\uZZZZ\"")).
+test(bound_pair_match, phrase(json_chars(string(['😀'])), "\"\\ud83d\\ude00\"")).
+test(bound_wrong_scalar, \+ phrase(json_chars(string(['😀'])), "\"\\uf600\"")).
+test(no_truncated_generation,
+    \+ phrase(json_chars(string(['😀'])), ['"','\\',u,_,_,_,_,'"'])).
+test(generate_ascii, scalar_round_trip(97)).
+test(generate_bmp, scalar_round_trip(229)).
+test(generate_nul, scalar_round_trip(0)).
+test(generate_first_supplementary, scalar_round_trip(65536)).
+test(generate_emoji, scalar_round_trip(128512)).
+test(generate_last_scalar, scalar_round_trip(1114111)).
+test(object_key_value, (
+    phrase(json_chars(pairs([string(Key)-string(Value)])),
+           "{\"\\ud83d\\ude00\":\"\\ud83d\\udcbb\"}"),
+    codes(Key,[128512]),codes(Value,[128187]))).
+test(array, (
+    phrase(json_chars(list([string(Chars),number(7),boolean(true)])),
+           "[\"\\ud83d\\ude00\",7,true]"),codes(Chars,[128512]))).
+test(prolog_reader, (
+    phrase(json_chars(string(Chars)), "\"\\\"\\ud83d\\ude00\\\"==['\\ud83d\\ude00']\""),
+    atom_chars(Goal,Chars),read_term_from_atom(Goal,Term,[]),call(Term))).
+
+run([], 0, 0).
+run([Label-Goal|Cases], Passed, Failed) :-
+    ( catch(call(Goal), Error, (writeq(error(Label,Error)),nl,fail)) ->
+        Result=pass, P=1, F=0
+    ; Result=fail, P=0, F=1 ),
+    writeq(Result-Label),nl,
+    run(Cases,Ps,Fs),Passed is Ps+P,Failed is Fs+F.
+main :-
+    findall(Label-Goal,test(Label,Goal),Cases),run(Cases,Passed,Failed),
+    format('JSON Unicode: ~d passed, ~d failed~n',[Passed,Failed]),
+    (Failed=:=0 -> halt ; halt(1)).
```

</details>
