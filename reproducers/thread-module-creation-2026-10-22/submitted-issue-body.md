## Summary and tested revision

Creating a previously absent module inside a native thread can raise SIGSEGV
before module creation. Both `load_text/2` with `module(Name)` and the internal
`'$module'/1` path assume the query has a top-level parser when deciding whether
to print an informational message. A native-thread query can legitimately have
`q->top == NULL`.

Tested on separate, unmodified Trealla v3.14.5 at
`beed430deca9fa48adf028541ea4c3e2bd8d3641`, on macOS arm64 with the matching
standard library. The separate candidate build contains only the two guards and
regression tests below. Both builds use SDK 15.4, `NOSSL=1 NOFFI=1`. No installed
runtime, Web Prolog production source or live node was changed.

## Minimal standalone reproducer

Save as `thread_module.pl`:

```prolog
:- module(thread_module,[run/0,load/1]).
run :-
    thread_create(thread_module:load(fresh_thread_module),T,[]),
    thread_join(T,true),
    M=fresh_thread_module,call(M:probe(ok)),
    writeln(passed).
load(M) :-
    atom_chars('probe(ok).',Chars),
    load_text(Chars,[module(M)]),
    call(M:probe(ok)).
```

```sh
TPL_LIBRARY_PATH=/path/to/build/library /path/to/build/tpl \
  -g "consult('thread_module.pl'),(thread_module:run->halt;halt(1))"
```

Expected: `passed`, exit 0, with the predicate loaded and callable in both child
and parent. Actual on the unmodified build: SIGSEGV. No Web Prolog modules,
imports, sockets, queue fixture, timers or concurrent module creators are needed.

Use a variable module qualifier as above. A literal `fresh_thread_module:Goal`
elsewhere in the source may cause the compiler to pre-create that module and
bypass the failing new-module branch. Source is supplied as a character list;
this avoids the separate unsupported-interned-atom input path in this build.

The same crash is triggered by replacing the worker body with:

```prolog
load(M) :-
    '$module'(M),assertz(M:probe(ok)),call(M:probe(ok)).
```

`'$module'/1` is an internal primitive; it is included deliberately because its
new-module branch has the same unchecked parser access.

## Cause and candidate patch

Both locations in `src/bif_predicates.c` have this logging condition:

```c
if (q->top->is_command && !q->run_init)
```

The query structure documents `top` as the parser that read the query text.
`thread_create/3` creates its own threaded query; it does not necessarily have
such a parser. Existing-module paths skip this branch, explaining why explicitly
pre-creating the module avoids the crash.

The saved native crash is in `bif_load_text_2`, offset +1748. ARM64 register x8 is
zero; disassembly loads `q->top` into x8, then reads the parser flags at +0x612.
The reported fault address is exactly 0x612. This is a null dereference in
message-printing code, before `module_create`, rather than evidence of a race
inside allocation or module-table growth.

Candidate patch below: guard both reads with
`q->top &&`. Module creation, source loading and existing interactive messages
are otherwise unchanged. No dummy parser is allocated or borrowed from another
thread. The patch also adds `tests/sundry/thread_module_creation.pl` and its
expected output.

## Verification

| Case, each in a fresh process | Unmodified, five trials | Guard-only candidate, twenty trials |
|---|---|---|
| Thread `load_text/2`, absent module | 5 SIGSEGVs | 20/20 pass |
| Thread `load_text/2`, pre-existing module | 5/5 pass | 20/20 pass |
| Thread `'$module'/1`, absent module | 5 SIGSEGVs | 20/20 pass |
| Thread `'$module'/1`, pre-existing module | 5/5 pass | 20/20 pass |
| Command query `load_text/2`, absent module | 5/5 pass, existing informational message retained | 20/20 pass, same message |
| Command query `'$module'/1`, absent module | 5/5 pass, existing informational message retained | 20/20 pass, same message |

The tests require successful worker termination and query the loaded/asserted
fact from the parent as well as the worker. Return status, exact stdout and empty
stderr are checked; a zero process exit alone is not treated as correctness.
There were no candidate crashes or watchdog timeouts in these 120 runs.

The original three-run thread/file-import diagnostic also now returns
`status(true)` and exits 0 in all three runs. The new engine regression fails
with SIGSEGV on the unmodified executable and matches its complete expected
output on the candidate. Existing `temporary_module`, `module_qualifier_errors`,
`meta_goal_module`, `retract_module_scope` and `op_module_visibility` regressions
all match expected output with exit 0 and no stderr.

## Scope and limits

This candidate is based on the stated revision, not a claim about later upstream
changes. It is separate from the file-path re-import/state-loss report #1176;
that candidate patch is not included here. It does not repair the other observed
intermittent lifecycle/property crash, certify general concurrent module
creation, or approve a runtime upgrade. Full engine/application suites, TLS,
WASM and other operating systems were not tested.

## Related reports and duplicate check

I searched open and closed issues for `load_text`, `q->top`, module/SIGSEGV and null/parser, and related pull requests. I found no report of this specific native-thread null-parser dereference. #582 is the earlier text-loading API discussion; #1176 concerns file re-import/state loss and only mentions this separate crash as a limitation.

<details>
<summary>Candidate patch, including regression tests</summary>

```diff
diff --git a/src/bif_predicates.c b/src/bif_predicates.c
index d6441a95..6d81a298 100644
--- a/src/bif_predicates.c
+++ b/src/bif_predicates.c
@@ -4319,7 +4319,7 @@ static bool bif_load_text_2(query *q)
 				m = find_module(q->pl, name_s);
 
 				if (!m) {
-					if (q->top->is_command && !q->run_init)
+					if (q->top && q->top->is_command && !q->run_init)
 						fprintf(stdout, "Info: created module '%s'\n", name_s);
 
 					m = module_create(q->pl, name_s);
@@ -6755,7 +6755,7 @@ bool bif_sys_module_1(query *q)
 		return true;
 
 	if (!m) {
-		if (q->top->is_command && !q->run_init)
+		if (q->top && q->top->is_command && !q->run_init)
 			fprintf(stdout, "Info: created module '%s'\n", name);
 
 		m = module_create(q->pl, name);
diff --git a/tests/sundry/thread_module_creation.expected b/tests/sundry/thread_module_creation.expected
new file mode 100644
index 00000000..87781b48
--- /dev/null
+++ b/tests/sundry/thread_module_creation.expected
@@ -0,0 +1,6 @@
+passed(load_new)
+passed(load_existing)
+passed(module_new)
+passed(module_existing)
+passed(command_load)
+passed(command_module)
diff --git a/tests/sundry/thread_module_creation.pl b/tests/sundry/thread_module_creation.pl
new file mode 100644
index 00000000..d5f2cd70
--- /dev/null
+++ b/tests/sundry/thread_module_creation.pl
@@ -0,0 +1,38 @@
+% SPDX-License-Identifier: MIT
+% Standalone: use variable module qualifiers so compilation cannot pre-create
+% the new destination and accidentally bypass the crashing path.
+:- module(thread_module_creation_tests,[run/1]).
+
+run(load_new) :-
+    worker_load(tmc_new),writeln(passed(load_new)).
+run(load_existing) :-
+    '$create_module'(tmc_existing),
+    worker_load(tmc_existing),writeln(passed(load_existing)).
+run(module_new) :-
+    worker_switch(tmc_switch),writeln(passed(module_new)).
+run(module_existing) :-
+    '$create_module'(tmc_switch_existing),
+    worker_switch(tmc_switch_existing),writeln(passed(module_existing)).
+run(command_load) :-
+    load(tmc_command),verify(tmc_command),writeln(passed(command_load)).
+run(command_module) :-
+    switch(tmc_command_switch),verify(tmc_command_switch),writeln(passed(command_module)).
+
+worker_load(Module) :-
+    thread_create(thread_module_creation_tests:load(Module),T,[]),
+    thread_join(T,true),verify(Module).
+worker_switch(Module) :-
+    thread_create(thread_module_creation_tests:switch(Module),T,[]),
+    thread_join(T,true),verify(Module).
+load(Module) :-
+    atom_chars('probe(ok).',Chars),
+    load_text(Chars,[module(Module)]),
+    call(Module:probe(ok)).
+switch(Module) :-
+    '$module'(Module),assertz(Module:probe(ok)),call(Module:probe(ok)).
+verify(Module) :- findall(X,call(Module:probe(X)),Xs),Xs==[ok].
+
+:- initialization(main).
+main :-
+    forall(member(Case,[load_new,load_existing,module_new,module_existing,command_load,command_module]),
+           run(Case)).
```

</details>
