## Summary

Polling `thread_property(T,status(_))` while a detached thread terminates with an
uncaught exception can segfault. A standalone reproducer crashes in 20/20 fresh
processes on both pinned v3.13.10 and unmodified v3.14.5 (`beed430deca9fa48adf028541ea4c3e2bd8d3641`), on macOS arm64.
There is no Web Prolog, module loading, network, callback or promise code in the
reproducer. Normal successful-thread retirement is a useful control: 20/20
processes on each engine complete 1,000 iterations without crashing.

## Standalone reproducer

```prolog
run :-
    forall(between(1,1000,_),
        (thread_create(throw(probe),T,[detached(true)]),poll(T,10000))),
    writeln(passed).
poll(_,0) :- throw(poll_exhausted).
poll(T,N) :-
    (catch(thread_property(T,status(_)),_,fail) ->
        Next is N-1,poll(T,Next)
    ; true).
```

Run in a fresh process with the matching standard library and an external
watchdog. A successful run must reach `passed`, not merely return exit status 0:

```sh
TPL_LIBRARY_PATH=/path/to/build/library /path/to/build/tpl \
  -g "consult('repro.pl'),(run->halt;halt(1))"
```

The checked-in diagnostic reproducer
also records the iteration and any retirement exception. Its fixed comparison
uses `run_property_race(exception,1000)`, 20 fresh processes per engine, each
with a 20-second watchdog. Catching an error here permits the expected race with
retirement; it does not turn SIGSEGV, poll exhaustion or a missing completion
marker into a pass. Existing dispatch sometimes reports `uninstantiation_error`
instead of `existence_error` for a retired handle; that separate inconsistency
is retained, not fixed by this candidate.

## Cause

`start_routine_thread_create()` publishes the exception ball and sets
`is_exception` and `is_finished`. Detached cleanup subsequently frees `t->ball`
and sets it to NULL while holding `t->guard`; the thread is retired afterwards.
The status readers tested `is_exception` and accessed `t->ball->num_cells` and
copied its cells without that guard. A reader can therefore see an exceptional
thread whose ball has already been freed or cleared. A null check alone does
not prevent freeing the ball between checking and copying it.

The saved native crash stacks identify `do_thread_property_pin_both`; fault
address 0x4 is consistent with reading the cell count through a NULL ball. The
same lifetime issue affects the duplicated status construction in property
enumeration. The lifecycle fixture reproduces matching stacks during worker
and timer disposal, including an explicitly traced entry into thread_property.

## Candidate repair

Candidate patch below, including regression tests,
based on the exact unmodified revision above:

- Take an owned status snapshot under the same per-thread guard used by detached
  cleanup, validating the active thread identity before reading it.
- Copy into the querying heap and unify after releasing the guard. Re-fetch the
  query arguments after heap allocation. Report a retired thread as a missing
  object and allocation failure as a resource error.
- Use the shared status helper for explicitly requested status and enumerated
  properties, and guard a missing result of the second thread lookup.
- Keep normal success, failure, exception and explicit-exit status vocabulary.

The engine regression checks direct status plus join results for all four
outcomes, and stresses detached exceptions through four property-query modes:
bound thread/status, bound thread with enumerated properties, enumerated threads
with status, and fully enumerated properties. It requires exact output and exit
status, rather than accepting a test script that prints an error and exits 0.

The exact short reproducer above was also executed separately: unmodified upstream
crashed 5/5; the final candidate printed `passed` and exited 0 in all five runs.

## Results

| Check | Unmodified | Final separate candidate |
|---|---|---|
| Standalone exceptional retirement, 20 fresh processes, up to 1,000 iterations each | Pinned: 20/20 SIGSEGV; upstream: 20/20 SIGSEGV | 20/20 pass, 20,000 completed iterations |
| New engine regression | Upstream: 5/5 SIGSEGV on the initial test revision | Final expanded regression: 5/5 exact passes |
| Eight existing engine regression groups | Not rerun for this comparison | All eight exact passes |
| Full instrumented port lifecycle group, 30 fresh processes | Pinned: 27 pass, 1 SIGSEGV, 2 incomplete runs; upstream: 27 pass, 2 SIGSEGV, 1 expiry wait failure | Final candidate: 30/30 pass, no crashes/timeouts |

The eight existing groups are `thread_join_exception`, `thread_detach_joining`,
`thread_signal_delivery`, `thread_signal_blocked`, `thread_cancel_blocked`,
`thread_exit_mutex`, `thread_option_errors` and `thread_mailbox`.

An earlier candidate batch passed 29/30 lifecycle runs with no crashes; one run
exhausted the bounded expiry wait. The final 30/30 does not resolve or erase that
failure. An unmodified upstream lifecycle crash had a different `do_signal`
stack; two pinned runs stopped without the required completion marker. Those
remain separate diagnostics, not claims that this patch fixes every lifecycle
failure. The baseline new-engine-test comparison preceded the added direct
status assertions; both regression versions reach the same detached-exception
stress, and the final candidate additionally passes the direct assertions.

## Build, scope and limitations

Separate macOS arm64 build with SDK 15.4, `NOSSL=1 NOFFI=1`, matching adjacent
library. No installed engine, live node or Web Prolog runtime source was changed.
The candidate does not include #1176's import repair or #1177's parser guards.
This is a focused status-payload lifetime repair, not a general proof of safe
concurrent thread-table reuse, alias enumeration, cancellation or signal
delivery. Full engine suites, application interop, TLS, WASM, other operating
systems and sanitizer builds were not tested. No runtime upgrade is proposed.

Verification results above refer to the stated revision and separate build.

## Duplicate check

I searched open and closed issues for `thread_property`, detached/exception,
`t->ball`, and status/exception/thread, plus related pull requests. #1026 has
older threading reports and a status-publication discussion, but I found no
report of this detached exception-payload lifetime trigger. #1176 mentions the
previously intermittent lifecycle crash without this reduction.

<details>
<summary>Candidate patch, including regression tests</summary>

```diff
diff --git a/src/bif_threads.c b/src/bif_threads.c
index 825c547c..21acc115 100644
--- a/src/bif_threads.c
+++ b/src/bif_threads.c
@@ -2017,6 +2017,74 @@ static bool bif_thread_exit_1(query *q)
 	return true;
 }
 
+// Detached cleanup frees ball/exit_code under t->guard. Take an owned
+// status image under that same guard, before allocating in the reader's heap.
+static cell *snapshot_thread_status(query *q, thread *t, int chan, bool *retired)
+{
+	*retired = false;
+	acquire_lock(&t->guard);
+	cell *tmp = NULL;
+
+	if (!t->is_active || t->chan != chan) {
+		*retired = true;
+		goto done;
+	}
+
+	if (!t->is_finished) {
+		tmp = TPL_calloc(2, sizeof(cell));
+		if (!tmp) goto done;
+		make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, 1);
+		make_atom(tmp+1, new_atom(q->pl, "running"));
+	} else if (t->is_exception) {
+		if (!t->ball) { // detached cleanup has already taken it
+			*retired = true;
+			goto done;
+		}
+		tmp = TPL_calloc(2+t->ball->num_cells, sizeof(cell));
+		if (!tmp) goto done;
+		make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, 1+t->ball->num_cells);
+		make_instr(tmp+1, new_atom(q->pl, "exception"), NULL, 1, t->ball->num_cells);
+		dup_cells(tmp+2, t->ball, t->ball->num_cells);
+	} else if (t->exit_code) {
+		tmp = TPL_calloc(1+t->exit_code->num_cells, sizeof(cell));
+		if (!tmp) goto done;
+		make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, t->exit_code->num_cells);
+		dup_cells(tmp+1, t->exit_code, t->exit_code->num_cells);
+	} else {
+		tmp = TPL_calloc(2, sizeof(cell));
+		if (!tmp) goto done;
+		make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, 1);
+		make_atom(tmp+1, t->is_failed?g_false_s:g_true_s);
+	}
+done:
+	release_lock(&t->guard);
+	return tmp;
+}
+
+static bool unify_thread_status(query *q, thread *t, int chan)
+{
+	bool retired;
+	cell *snapshot = snapshot_thread_status(q, t, chan, &retired);
+	if (!snapshot) {
+		if (!retired)
+			return throw_error(q, q->st.instr, q->st.cur_ctx, "resource_error", "memory");
+		GET_FIRST_ARG(p1,nonvar);
+		return throw_error(q, p1, p1_ctx, "existence_error", "thread_object");
+	}
+	cell *tmp = alloc_heap(q, snapshot->num_cells);
+	if (!tmp) {
+		unshare_cells(snapshot, snapshot->num_cells);
+		TPL_free(snapshot);
+		return throw_error(q, q->st.instr, q->st.cur_ctx, "resource_error", "memory");
+	}
+	dup_cells(tmp, snapshot, snapshot->num_cells);
+	unshare_cells(snapshot, snapshot->num_cells);
+	TPL_free(snapshot);
+	GET_FIRST_ARG(p1,nonvar);
+	GET_NEXT_ARG(p2,any);
+	return unify(q, p2, p2_ctx, tmp, q->st.cur_ctx);
+}
+
 static bool do_thread_property_pin_both(query *q)
 {
 	GET_FIRST_ARG(p1,nonvar);
@@ -2029,6 +2097,8 @@ static bool do_thread_property_pin_both(query *q)
 	}
 
 	thread *t = find_thread_by_id(q->pl, n);
+	if (!t)
+		return throw_error(q, p1, p1_ctx, "existence_error", "thread_object");
 
 	if (get_arity(p2) != 1)
 		return throw_error(q, p2, p2_ctx, "domain_error", "thread_property");
@@ -2056,37 +2126,7 @@ static bool do_thread_property_pin_both(query *q)
 		make_atom(tmp+1, t->is_detached?g_true_s:g_false_s);
 		return unify(q, c, c_ctx, tmp, q->st.cur_ctx);
 	} else if (!CMP_STRING_TO_CSTR(q, p2, "status")) {
-		if (!t->is_finished) {
-			cell *tmp = alloc_heap(q, 2);
-			make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, 1);
-			make_atom(tmp+1, new_atom(q->pl, "running"));
-			return unify(q, c, c_ctx, tmp, q->st.cur_ctx);
-		}
-
-		if (t->is_exception) {
-			cell *tmp = alloc_heap(q, 2+t->ball->num_cells);
-			make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, 1+t->ball->num_cells);
-			make_instr(tmp+1, new_atom(q->pl, "exception"), NULL, 1, t->ball->num_cells);
-			dup_cells(tmp+2, t->ball, t->ball->num_cells);
-			return unify(q, c, c_ctx, tmp, q->st.cur_ctx);
-		}
-
-		// thread_exit/1 stores its argument already wrapped as
-		// exited/1, so hand that back whole - this reported a bare
-		// `false` for it. And a goal that merely failed is is_failed,
-		// not exit_code, which made it report `true`; thread_join/2 has
-		// always read the right flag, so the two disagreed.
-		if (t->exit_code) {
-			cell *tmp = alloc_heap(q, 1+t->exit_code->num_cells);
-			make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, t->exit_code->num_cells);
-			dup_cells(tmp+1, t->exit_code, t->exit_code->num_cells);
-			return unify(q, c, c_ctx, tmp, q->st.cur_ctx);
-		}
-
-		cell *tmp = alloc_heap(q, 2);
-		make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, 1);
-		make_atom(tmp+1, t->is_failed?g_false_s:g_true_s);
-		return unify(q, c, c_ctx, tmp, q->st.cur_ctx);
+		return unify_thread_status(q, t, n);
 	} else
 		return throw_error(q, p2, p2_ctx, "domain_error", "thread_property");
 
@@ -2134,6 +2174,8 @@ static bool do_thread_property_pin_id(query *q)
 	}
 
 	thread *t = find_thread_by_id(q->pl, n);
+	if (!t)
+		return throw_error(q, p1, p1_ctx, "existence_error", "thread_object");
 	unsigned i = 0;
 
 	if (q->retry)
@@ -2168,37 +2210,7 @@ static bool do_thread_property_pin_id(query *q)
 		make_atom(tmp+1, t->is_detached?g_true_s:g_false_s);
 		return unify(q, p2, p2_ctx, tmp, q->st.cur_ctx);
 	} else {
-		if (!t->is_finished) {
-			cell *tmp = alloc_heap(q, 2);
-			make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, 1);
-			make_atom(tmp+1, new_atom(q->pl, "running"));
-			return unify(q, p2, p2_ctx, tmp, q->st.cur_ctx);
-		}
-
-		if (t->is_exception) {
-			cell *tmp = alloc_heap(q, 2+t->ball->num_cells);
-			make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, 1+t->ball->num_cells);
-			make_instr(tmp+1, new_atom(q->pl, "exception"), NULL, 1, t->ball->num_cells);
-			dup_cells(tmp+2, t->ball, t->ball->num_cells);
-			return unify(q, p2, p2_ctx, tmp, q->st.cur_ctx);
-		}
-
-		// thread_exit/1 stores its argument already wrapped as
-		// exited/1, so hand that back whole - this reported a bare
-		// `false` for it. And a goal that merely failed is is_failed,
-		// not exit_code, which made it report `true`; thread_join/2 has
-		// always read the right flag, so the two disagreed.
-		if (t->exit_code) {
-			cell *tmp = alloc_heap(q, 1+t->exit_code->num_cells);
-			make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, t->exit_code->num_cells);
-			dup_cells(tmp+1, t->exit_code, t->exit_code->num_cells);
-			return unify(q, p2, p2_ctx, tmp, q->st.cur_ctx);
-		}
-
-		cell *tmp = alloc_heap(q, 2);
-		make_instr(tmp, new_atom(q->pl, "status"), NULL, 1, 1);
-		make_atom(tmp+1, t->is_failed?g_false_s:g_true_s);
-		return unify(q, p2, p2_ctx, tmp, q->st.cur_ctx);
+		return unify_thread_status(q, t, n);
 	}
 }
 
diff --git a/tests/sundry/thread_status_retirement.expected b/tests/sundry/thread_status_retirement.expected
new file mode 100644
index 00000000..8978d7ba
--- /dev/null
+++ b/tests/sundry/thread_status_retirement.expected
@@ -0,0 +1,6 @@
+join_status_preserved
+passed(bound)
+passed(properties)
+passed(threads)
+passed(all)
+all regressions passed
diff --git a/tests/sundry/thread_status_retirement.pl b/tests/sundry/thread_status_retirement.pl
new file mode 100644
index 00000000..b0aa0de8
--- /dev/null
+++ b/tests/sundry/thread_status_retirement.pl
@@ -0,0 +1,44 @@
+% SPDX-License-Identifier: MIT
+% An owned exception snapshot must outlive detached-thread cleanup.
+require(Label,Goal) :- (call(Goal)->true;throw(failed(Label))).
+worker(success).
+worker(failure) :- fail.
+worker(exception) :- throw(probe([a,b],pair(1,2))).
+worker(exit) :- thread_exit(done).
+expected(success,true).
+expected(failure,false).
+expected(exception,exception(probe([a,b],pair(1,2)))).
+expected(exit,exited(done)).
+joinable(Kind) :-
+    thread_create(worker(Kind),T,[]),
+    expected(Kind,E),await_status(T,E,1000),
+    thread_join(T,S),require(join_status,S==E).
+await_status(T,E,N) :-
+    thread_property(T,status(S)),
+    (S==E -> true
+    ; N>0 -> sleep(0.001),Next is N-1,await_status(T,E,Next)
+    ; throw(status_wait_exhausted(T,E,S))).
+missing(error(existence_error(thread_object,_),_)).
+% Existing dispatch may report this if retirement races its kind lookup.
+missing(error(uninstantiation_error(_),_)).
+read_property(T,bound) :- thread_property(T,status(S)),valid_status(S).
+read_property(T,properties) :- findall(P,thread_property(T,P),Ps),member(status(S),Ps),valid_status(S).
+read_property(T,threads) :- findall(Id-S,thread_property(Id,status(S)),Pairs),
+    member(T-S,Pairs),valid_status(S).
+read_property(T,all) :- findall(Id-P,thread_property(Id,P),Pairs),
+    member(T-status(S),Pairs),valid_status(S).
+valid_status(running).
+valid_status(exception(probe([a,b],pair(1,2)))).
+poll(_,_,0) :- throw(poll_exhausted).
+poll(T,Mode,N) :-
+    catch((read_property(T,Mode)->Again=true;Again=false),E,
+          (missing(E)->Again=false;throw(E))),
+    (Again==true -> Next is N-1,poll(T,Mode,Next);true).
+retire(Mode) :- thread_create(worker(exception),T,[detached(true)]),poll(T,Mode,10000).
+run :-
+    forall(member(K,[success,failure,exception,exit]),joinable(K)),
+    writeln(join_status_preserved),
+    forall(member(Mode,[bound,properties,threads,all]),
+        (forall(between(1,200,_),retire(Mode)),writeln(passed(Mode)))),
+    writeln('all regressions passed').
+:- initialization((catch(run,E,(writeq(E),nl,halt(1)))->halt;halt(1))).
```

</details>
