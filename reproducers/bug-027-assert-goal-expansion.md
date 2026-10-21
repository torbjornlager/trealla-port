# BUG-027: Assertion goal expansion misprints runtime variables and disables later expansion

**Status:** Submitted on 2026-10-21 as [Trealla issue #1175](https://github.com/trealla-prolog/trealla-prolog/issues/1175), including the complete candidate diff. The candidate engine patch
is experimental, tested only in a separate v3.13.26 build. No installed engine,
port runtime source or live node was changed.

## Report background and local evidence

Assertion from a helper loaded with `load_text/2` can generate a malformed
internal `goal_expansion/2` query. The assertion still succeeds, but subsequent
expansion can remain disabled, leaving a call to a predicate that the hook should
have replaced. The attached standalone program uses only Trealla built-ins:
no Web Prolog code, network, threads, or sleeps.

### Standalone reproducer

Save the following as `assert_expansion.pl`:

```prolog
% SPDX-License-Identifier: MIT
% Standalone Trealla assertion/expansion reproducer; no Web Prolog code.
:- module(assert_goal_expansion_reproducer,[run/0, control/0]).
run :- fixture(assert_goal_expansion_reproducer:check).
control :- fixture(assert_goal_expansion_reproducer:check_ground).
fixture(Goal) :-
    Source = 'goal_expansion(eq(_,_),_) :- fail. goal_expansion(mark(X,Y),(Local=added,target(X,Y,Local))). goal_expansion(ground_marker,true). target(a,b,added). store((Head:-Body)) :- assertz((Head:-Body)).',
    atom_chars(Source,Chars),
    in_temporary_module(probe_module,
       load_text(Chars,[module(probe_module)]),
       Goal).
check :-
    read_term_from_atom('probe(X,X,Y) :- eq(X,Y).',Clause,[]),
    probe_module:store(Clause),
    probe_module:assertz(eq(a,a)),
    findall(A-B-C,probe_module:probe(A,B,C),Rows),
    writeq(first(Rows)),nl,
    ground_result(Ground),
    read_term_from_atom('after(X,X,Y) :- mark(X,Y).',Next,[]),
    probe_module:store(Next),
    catch(findall(A-B-C,probe_module:after(A,B,C),After),E,After=error(E)),
    writeq(after(After)),nl,
    After == [a-a-b], Ground == ok.

check_ground :- ground_result(Result), Result == ok.
ground_result(Result) :-
    probe_module:store((ground_recovery :- ground_marker)),
    catch((probe_module:ground_recovery -> Result=ok ; Result=failed),
          Error, Result=error(Error)),
    writeq(ground(Result)),nl.

```

Run with the executable's matching library:

```sh
TPL_LIBRARY_PATH=/path/to/trealla/library /path/to/tpl -g "consult('assert_expansion.pl'),(assert_goal_expansion_reproducer:run->halt;halt(1))"
```

Expected output and exit 0:

```text
first([a-a-a])
ground(ok)
after([a-a-b])
```

On both tested unmodified builds, exit 1 with:

```text
first([a-a-a])
ground(error(error(existence_error(procedure,ground_marker/0),ground_marker/0)))
after(error(error(existence_error(procedure,mark/2),mark/2)))
```

and stderr:

```text
Error: syntax error, near 'match', operator expected, probe_module:1
```

The original application cases instead print `missing arg` or `start of rule
expected`. Tracing only in a separate diagnostic build showed internally
generated text such as `goal_expansion((self()),_TermOut), !.` and
`goal_expansion((prove(,)),_TermOut), !.`. The actual submitted clauses are valid.
The particular malformed text depends on the runtime variable fields.

The `control/0` entry runs the ground expansion in a fresh fixture without the
preceding problematic assertion:

```sh
TPL_LIBRARY_PATH=/path/to/trealla/library /path/to/tpl -g "consult('assert_expansion.pl'),(assert_goal_expansion_reproducer:control->halt;halt(1))"
```

It prints `ground(ok)` and exits 0 on both unmodified builds and the candidate.
This distinguishes disabled later expansion from another variable-printing
failure: the ground query contains no variables to misprint.

### Tested revisions and results

Native macOS arm64, each executable with its matching library, fresh process for
each trial. No engine installation was performed.

| Check | Pinned v3.13.10 | Upstream v3.13.26 | Candidate v3.13.26 |
| --- | --- | --- | --- |
| Standalone reproducer | 20/20 reproduce defect | 20/20 reproduce defect | 20/20 correct |
| Ground-only control | 5/5 correct | 5/5 correct | 5/5 correct |
| New assertion regressions | 0/24 pass | 0/24 pass | 24/24 pass |
| Selected existing upstream tests | not run | 44/44 pass | 44/44 pass |
| Port isolation/sandbox/toplevel groups | not rerun | all exit 0; first two emit parser diagnostics | all exit 0; no stderr |

Pinned revision: `36f512f595e407e330f6e1f6b4eb339da2b0675e`.
Upstream/candidate base: `7af2b53c4eaa219c5f74b716f37e4f5e1b1917a6`.
The latter still matched upstream `refs/heads/main` when checked after the
candidate tests on 2026-10-21.

The 24 new regression invocations are eight cases repeated in three fresh
processes each. They exercise `asserta/1-2` and `assertz/1-2`, repeated/distinct
variables, quoted atoms, expansion-created local variables, cut commitment,
clause references and unchanged input variables. Invalid unbound expansion
results must reject assertion, leave its output reference unbound, publish no
clause, and allow a subsequent valid expansion. Original failures remain in the
raw results; no waiver or stderr suppression is used to count a pass.

The 44 selected upstream `tests/sundry` Prolog tests cover assertion/mutation,
term/goal expansion, variable renaming, meta-calls, DCGs, tabling and temporary
modules. Each must exit 0 and match its `.expected` stdout; both builds also had
empty stderr in these checks. This is a bounded selection, not the full upstream
suite, and the selection rule is recorded in the runner.

### Cause found in the engine

`assign_vars(..., rebase=true)` assigns synthetic variable identities in the
parser table, but retains `c->val_off` from the incoming cell. For a runtime
reference that union field is `val_ctx`, not a source-name atom offset. Later,
the reference flag is cleared. The non-running canonical printer then interprets
that field as a variable's source name, producing an empty or unrelated name.

The goal-expansion driver reparses that output. Its initial parse-error path
sets the parser error and returns the original goal without clearing
`pl->in_goal_expansion`. Subsequent expansions are therefore skipped. Finally,
the four assertion implementations call `term_to_body(p)` and proceed to
publish the clause without checking the new parser error. This accounts for
both the diagnostics and apparently successful assertions with missed expansion.

### Candidate repair

The adjacent `.patch`, based on unmodified v3.13.26, changes only
`src/parser.c` and `src/bif_database.c`:

1. Assign a real interned synthetic source name while rebasing each variable,
   keeping the same identity for repeated occurrences. This replaces the
   runtime context field before canonical printing can interpret it as a name.
2. Clear expansion-in-progress state and release temporary resources on the
   early parser/table-allocation and initial parse-error paths.
3. Check parser failure after `term_to_body` in all four assertion variants,
   before database publication.

The candidate currently reports these compilation failures as
`error(syntax_error(goal_expansion),asserta/1)` (or the corresponding assertion
variant). That diagnostic classification is provisional for upstream review;
it is not an ISO claim or a proposed Web Prolog language change. The patch does
not overhaul expansion-hook exception propagation or the engine's other loaders.

The candidate preserves the original passing tests while eliminating the
reported diagnostics in the affected source-loading groups. It has not been
adopted by the port, patched into the pinned engine, or installed for live nodes.

### Reproduction assets and build

- `bug-027-assert-goal-expansion.pl`: standalone symptom and ground-only control.
- `bug-027-assert-goal-expansion-tests.pl`: bounded semantic regression cases.
- `bug-027-assert-goal-expansion.py`: fresh-process comparison runner.
- `bug-027-assert-goal-expansion.patch`: candidate engine diff.
- `bug-027-assert-expansion-results.json`: raw outputs, statuses and hashes.

The runner records failures rather than using its own exit status as a pass
gate. Inspect each build's `correct`/`passed` counts and stderr. Each subprocess
has a 60-second external timeout; no timeout occurred in the recorded run.

Build the separate candidate after applying the patch:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk make NOSSL=1 NOFFI=1 -j4
```

TLS/optional FFI are disabled; threads remain enabled. Neither optional facility
is involved in the reproducer. The clean upstream build is retained separately
at `~/.local/share/trinity-runtime-tests/trealla-output-capture/upstream-2026-10-21`;
the candidate is at `~/.local/share/trinity-runtime-tests/trealla-assert-expansion-candidate`.
For example, from the port repository:

```sh
python3 reproducers/bug-027-assert-goal-expansion.py \
  --engine upstream=/path/to/clean/tpl \
  --engine candidate=/path/to/patched/tpl \
  --upstream-checks upstream --upstream-checks candidate \
  --output /tmp/assert-expansion-results.json
```

The installed v3.13.10 binary's SHA-256 was unchanged before and after:
`34cbf9796d4c4310b2f6bb122d2e820fc446089173b2ab39e5a6faa48ef56563`.
No PATH changes or live-node restarts were made.

A focused duplicate search on 2026-10-21 for `goal_expansion` with `assertz`,
`load_text`, and variable-related titles found no exact match. The output-capture
issue #1174 and concurrent module-map issue #1173 have independent reproducers
and causes. The report and complete candidate diff were subsequently submitted
as issue #1175; no engine installation was performed.

The reduction and candidate were developed with Codex. All counts above are
from program execution; the raw evidence includes the failing unmodified runs.
