# BUG-025: Concurrent module-table growth and lookup

**Closure verification (2026-10-22):** [Trealla #1173](https://github.com/trealla-prolog/trealla-prolog/issues/1173) is now closed as completed. The original standalone module-map stress reproducer passed 100/100 fresh-process trials. These checks use unmodified upstream v3.14.5 (`beed430`), not our candidate engine patches. Installed runtimes are unchanged. [Results and closure comments](upstream-closure-verification-2026-10-22/REPORT.md). Earlier observations below are retained as history.

**Status:** Submitted on 2026-10-21 as [Trealla issue #1173](https://github.com/trealla-prolog/trealla-prolog/issues/1173).

The following is the submitted report. The adjacent `.pl` and `.py` files
provide the standalone reproducer and fresh-process stress runner. The `.patch`
contains the candidate engine change; it applies to both tested revisions.
`bug-025-module-map-results.json` records counts, binary hashes and trial outcomes.
The patched v3.13.26 build is retained separately at
`~/.local/share/trinity-runtime-tests/trealla-module-map/patched-v3.13.26`.
The installed runtime is unchanged (its SHA-256 matches the pre-stress snapshot).
The patch is experimental and has not been adopted by the port.

---

Concurrent creation of modules can crash another thread executing ordinary Prolog predicates. This was reduced from a multi-connection WebSocket client failure; the program below needs no Web Prolog code or networking.

### Tested revisions and results

macOS 26.6.2 / Darwin arm64, native builds with `NOSSL=1`, each with its matching standard library. Each trial starts a fresh process and has a 15-second external watchdog.

| Revision | Unmodified | With candidate locking patch |
| --- | --- | --- |
| v3.13.10, `36f512f595e407e330f6e1f6b4eb339da2b0675e` | 70 SIGSEGVs, 30 completions / 100 | 100 completions / 100 |
| v3.13.26, `7af2b53c4eaa219c5f74b716f37e4f5e1b1917a6` | 40 SIGSEGVs, 10 completions / 50 | 100 completions / 100 |

The v3.13.26 revision still matched upstream `main` when checked on 2026-10-21. There were no watchdog timeouts or Prolog failures in these four batches. These are observed counts, not a deterministic failure-rate claim. The patched builds contain only the candidate synchronization changes below, with no diagnostic printing. They were built separately using Apple Clang and the installed macOS 15.4 SDK.

### Standalone reproducer

Save as `module_map_reproducer.pl`:

```prolog
% Standalone Trealla module-table growth/lookup race. No Web Prolog code.
:- module(module_map_reproducer, [run/0]).
:- use_module(library(lists)).

worker_loop(0) :- !.
worker_loop(N) :-
    append([a,b], [c,d], List),
    length(List, 4),
    Next is N-1,
    worker_loop(Next).

run :-
    thread_self(Main),
    thread_create((thread_send_message(Main, ready), worker_loop(200000)),
                  Worker, []),
    thread_get_message(ready),
    forall(between(1, 300, N),
           (format(atom(Module), 'grow_~w', [N]), '$create_module'(Module))),
    thread_join(Worker, true).
```

`'$create_module'/1` is Trealla's internal module-creation primitive. It is used here deliberately to exercise table growth without source loading, temporary-module cleanup, or application code. Only the main thread creates modules; the worker runs list predicates. The ready message ensures that the worker has started before creation begins.

Run repeatedly, for example:

```sh
for i in $(seq 1 100); do
  /path/to/tpl -g "(catch((consult('module_map_reproducer.pl'),module_map_reproducer:run),E,(writeq(E),nl,halt(2)))->writeln(passed),halt;halt(1))"
done
```

For a source build, set `TPL_LIBRARY_PATH=/path/to/source/library` to its matching library. Expected: each process prints `passed` and exits successfully. Actual: intermittent native SIGSEGV, without a Prolog exception. The completed runs do print `passed`; the worker status is explicitly checked by `thread_join(Worker,true)`.

### Diagnosis

`src/module.c:modmap_set()` grows `pl->modmap` with `TPL_realloc`. Meanwhile `module_by_id()` reads `pl->modmap_alloc` and indexes `pl->modmap` without synchronization. A concurrent reader can therefore use the old storage while it is being reallocated. Module-ID allocation/table publication also need to be serialized with other creators.

In the original application, a separate instrumented build caught:

```text
NULL LOOKUP return_frame id=46 alloc=64 key=append/3
```

Here module 46 was `websocket`, an ordinary loaded module, and creation of module 64 was growing the table. The uninstrumented macOS crash was in `match_head`, inlined `commit_frame`, at `f->mid = q->st.m->id`, reading address `0x128` through a null module pointer. Another instrumented run caught the same lookup failure after `utf8_code/2`, so this is not specific to `append/3` itself.

The source race and the reduced test strongly support this diagnosis. I have not run ThreadSanitizer or tested other operating systems.

### Candidate patch

The following small experimental patch takes the existing instance lock around the two query-side module lookups and around module-ID allocation/table growth. It fixes both reduced stress batches above. It is offered as a candidate rather than a complete audit of concurrent module creation/destruction or a performance claim.

```diff
--- a/src/module.c
+++ b/src/module.c
@@ -3852,8 +3852,10 @@
 
 		init_lock(&m->guard);
 		m->pl = pl;
+		prolog_lock(pl);
 		m->id = ++pl->next_mod_id;
 		modmap_set(pl, m->id, m);
+		prolog_unlock(pl);
 	}
 
 	m->filename = set_known(m, name);
--- a/src/query.c
+++ b/src/query.c
@@ -2242,7 +2242,9 @@
 	q->st.instr = f->instr;
 	q->st.cur_ctx = f->prev;
 	f = GET_CURR_FRAME();
+	prolog_lock(q->pl);
 	q->st.m = module_by_id(q->pl, f->mid);
+	prolog_unlock(q->pl);
 	return true;
 }
 
@@ -2268,7 +2270,9 @@
 	do {
 		frame *f = GET_CURR_FRAME();
 		f->chgen = q->st.instr->chgen;
+		prolog_lock(q->pl);
 		q->st.m = module_by_id(q->pl, q->st.instr->mid);
+		prolog_unlock(q->pl);
 		q->st.instr = q->st.instr->ret_instr;
 	} while (is_end(q->st.instr) && q->st.instr->ret_instr);
 }
```

The original overlapping-connection sequence also passed 20/20 fresh-process checks with the separate patched v3.13.26 client: ten against native SWI and ten against an unmodified Trealla v3.13.10 peer. Local actor/receive, remote-demonitor, notification-frame, synchronous-wrapper, correlated-writer and namespace regression groups passed with the patched client as well. The installed runtime has not been replaced.

I checked open/closed issues for `modmap`, `module_by_id`, `match_head`, `create_module`, and module/thread/race reports. I found no direct duplicate. #1026 contains older application-level threading failures, but does not establish this module-table trigger; #1171 concerns abolished-clause reclamation, a different trigger.
