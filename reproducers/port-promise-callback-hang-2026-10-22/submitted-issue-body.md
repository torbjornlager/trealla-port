On Trealla v3.14.5 (`beed430deca9fa48adf028541ea4c3e2bd8d3641`), importing an already-loaded module by file path into another module removes facts asserted into its dynamic predicates. Importing by the existing module name preserves them. Trealla v3.13.10 preserves them in both cases.

This caused a Web Prolog actor startup to hang: bootstrap imports erased actor registrations and a promise record. The reduction below uses no Web Prolog, threads, sockets, queues or callbacks.

### Minimal reproducer

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

Run with the matching standard library:
```sh
TPL_LIBRARY_PATH=/path/to/build/library /path/to/build/tpl \
  -g "consult('import-state.pl'),run('/absolute/path/state-library.pl'),halt"
```

Expected `[kept]`; actual on unmodified v3.14.5: `[]`. Replacing the path argument with `callback_probe_state` returns `[kept]`. Five fresh-process trials per case confirmed the difference on each engine.

### Candidate patch

The full candidate patch below is based on `beed430` and includes regression tests. SHA256: `076bac9fe39f15fed8f02db3aadc1f31fbed3b85c7052d2bfdec822451032dcc`.

It carries an import/reload distinction through private file-loading helpers to the parser. Ordinary file-path imports reuse the existing module at its `module/2` declaration instead of entering the explicit-reconsult unload branch. Public C `load_file` and `load_fp` signatures remain unchanged. Explicit `consult/1` and `make/0` keep the existing reload path. No callback workaround or global loader locking is added.

### Verification

Separate macOS arm64 build, SDK 15.4, `NOSSL=1 NOFFI=1`, matching adjacent libraries. The installed runtime was not replaced. This is tested on the stated revision, not a claim about later upstream changes.

- Original callback test: pinned v3.13.10 passes 5/5; unmodified v3.14.5 times out 5/5; candidate passes 5/5. Its stage trace now includes startup return, callback answer `waiting`, termination notification and cleanup.
- Standalone file-import preservation: candidate passes 5/5; module-name controls pass on both engines.
- New `use_module_state` engine regression fails on unmodified (`failed(full)`) and passes on candidate. It covers full/selective imports, the existing reexport loader path, a native-thread import into a pre-created module, retaining state after a source file changes, and subsequent explicit consult reloading the file.
- Existing `reconsult_module`, `make_module_state`, `make_same_second`, `make_failed_load` and `runtime_consult_base` regressions pass with exact expected output and zero exit status.
- Complete port promise correctness group and focused HTTP timeout/cleanup/callback/retry checks pass on candidate.

### Separate diagnostics and limits

This is a bounded candidate, not an approved runtime upgrade. A supplemental lifecycle test crashed once in `do_thread_property_pin_both`, then passed three candidate repeats; three unmodified runs also passed. This neither attributes that intermittent crash to the patch nor establishes independence.

A separate standalone diagnostic creating a new importer module inside a native thread crashes 3/3 with SIGSEGV on both unmodified and candidate engines. The new import regression pre-creates the destination module, matching existing actor startup, and makes no claim to fix thread-time module creation. Full engine/application suites, TLS, WASM and other operating systems have not been tested for this candidate.

### Duplicate check

I checked open and closed issues for `use_module`, `reconsult`, `reimport`, `runtime state`, module/asserted-state reports and import-related PRs. No direct duplicate found. #89 and #825 concern explicit reconsult behavior; #1175 concerns assertion goal expansion rather than this import trigger.


<details>
<summary>Candidate patch, including regression tests</summary>

```diff
diff --git a/src/internal.h b/src/internal.h
index 5df4eb37..5d9755cf 100644
--- a/src/internal.h
+++ b/src/internal.h
@@ -1254,6 +1254,7 @@ struct parser_ {
 	bool did_getline:1;
 	bool already_loaded_error:1;
 	bool v_owned:1;						// v holds a bigint or rational no cell has taken yet
+	bool is_module_import:1;				// use_module/reexport, not an explicit reconsult
 	bool switched_module:1;				// a module/2 directive set p->m->reading_file
 	bool do_read_term:1;
 	bool internal:1;
diff --git a/src/module.c b/src/module.c
index a0ba98f6..8105f0c8 100644
--- a/src/module.c
+++ b/src/module.c
@@ -26,6 +26,8 @@ struct loaded_file_ {
 	bool is_loaded:1;
 };
 
+static module *load_module_file(module *m, const char *filename, bool including, bool init, bool importing);
+
 static const op_table g_ops[] =
 {
 	{":-", OP_XFX, 1200, false, false},
@@ -1564,7 +1566,7 @@ static bool do_use_module(module *cur_m, cell *c, module **mptr)
 	char *filename = is_library ? TPL_strdup(dstbuf) : relative_to(loading_base(cur_m), name);
 	ENSURE(filename);
 
-	if (!(m = load_file(cur_m, filename, false, true))) {
+	if (!(m = load_module_file(cur_m, filename, false, true, true))) {
 		fprintf(stderr, "Warning: module file not found: %s\n", filename);
 		TPL_free(filename);
 		return false;
@@ -3561,10 +3563,11 @@ bool unload_file(module *m, const char *filename)
 #endif
 }
 
-module *load_fp(module *m, FILE *fp, const char *filename, bool including, bool init)
+static module *load_module_fp(module *m, FILE *fp, const char *filename, bool including, bool init, bool importing)
 {
 	parser *p = parser_create(m);
 	if (!p) return NULL;
+	p->is_module_import = importing;
 	const char *save_filename = m->filename;
 	const char *save_base = g_load_base;
 	if (!including) m->filename = set_known(m, filename);
@@ -3632,13 +3635,19 @@ module *load_fp(module *m, FILE *fp, const char *filename, bool including, bool
 	return save_m;
 }
 
-module *load_file(module *m, const char *filename, bool including, bool init)
+module *load_fp(module *m, FILE *fp, const char *filename, bool including, bool init)
+{
+	return load_module_fp(m, fp, filename, including, init, false);
+}
+
+static module *load_module_file(module *m, const char *filename, bool including, bool init, bool importing)
 {
 #if !TPL_FEATURE_FILESYSTEM
 	(void)m;
 	(void)filename;
 	(void)including;
 	(void)init;
+	(void)importing;
 	return NULL;
 #else
 	const char *orig_filename = filename;
@@ -3686,7 +3695,7 @@ module *load_file(module *m, const char *filename, bool including, bool init)
 				parser_destroy(p);
 			}
 
-			module *save_m = load_fp(m, str->fp, filename, including, init);
+			module *save_m = load_module_fp(m, str->fp, filename, including, init, importing);
 			clearerr(str->fp);
 			return save_m;
 		}
@@ -3713,7 +3722,7 @@ module *load_file(module *m, const char *filename, bool including, bool init)
 		ENSURE(tmpbuf);
 		strcpy(tmpbuf, orig_filename);
 		strcat(tmpbuf, ".pl");
-		m = load_file(m, tmpbuf, including, init);
+		m = load_module_file(m, tmpbuf, including, init, importing);
 		TPL_free(tmpbuf);
 		TPL_free(realbuf);
 		return m;
@@ -3746,13 +3755,18 @@ module *load_file(module *m, const char *filename, bool including, bool init)
 		fseek(fp, 0, SEEK_SET);
 
 	clearerr(fp);
-	module *save_m = load_fp(m, fp, filename, including, init);
+	module *save_m = load_module_fp(m, fp, filename, including, init, importing);
 	fclose(fp);
 	TPL_free(realbuf);
 	return save_m;
 #endif
 }
 
+module *load_file(module *m, const char *filename, bool including, bool init)
+{
+	return load_module_file(m, filename, including, init, false);
+}
+
 static void module_save_fp(module *m, FILE *fp, int canonical, int dq)
 {
 	(void) dq;
diff --git a/src/parser.c b/src/parser.c
index 92307634..c5e8b27f 100644
--- a/src/parser.c
+++ b/src/parser.c
@@ -1795,7 +1795,9 @@ static bool directive_term(parser *p, cell *c)
 
 		// Its own file read again, by make/0 or consult/1, and not from within itself
 
-		bool reload = tmp_m && !tmp_m->reading_file && is_known(tmp_m, file);
+		// Importing an existing module must not reconsult its file: that
+		// can discard runtime state shared with other importers.
+		bool reload = !p->is_module_import && tmp_m && !tmp_m->reading_file && is_known(tmp_m, file);
 
 		if (reload) {
 			unload_file(tmp_m, file);			// what the old copy put there, not what was asserted since
diff --git a/tests/sundry/use_module_state.expected b/tests/sundry/use_module_state.expected
new file mode 100644
index 00000000..5afdef2c
--- /dev/null
+++ b/tests/sundry/use_module_state.expected
@@ -0,0 +1,10 @@
+Info: created module 'tmp_ums_full'
+full_import_kept_state
+Info: created module 'tmp_ums_select'
+selective_import_kept_state
+Info: created module 'tmp_ums_reexport'
+reexport_kept_state
+thread_import_kept_state
+Info: created module 'tmp_ums_changed'
+import_ignores_file_change
+explicit_consult_reloads
diff --git a/tests/sundry/use_module_state.sh b/tests/sundry/use_module_state.sh
new file mode 100755
index 00000000..5d38ed0d
--- /dev/null
+++ b/tests/sundry/use_module_state.sh
@@ -0,0 +1,55 @@
+#!/bin/sh
+
+# Importing an already loaded module file must not reconsult it or erase
+# asserted state. Exercise full/selective/re-export imports and a thread,
+# then ensure explicit consult/1 still reads a changed module file.
+TPL=${TPL:-./tpl}
+MOD=tmp_ums_state.pl
+DRV=tmp_ums_driver.pl
+trap 'rm -f "$MOD" "$DRV"' EXIT
+
+cat > "$MOD" <<'PL'
+:- module(tmp_ums_state, [state/1, version/1]).
+:- dynamic state/1.
+version(1).
+PL
+
+cat > "$DRV" <<'PL'
+:- use_module(tmp_ums_state).
+
+require(Label, Goal) :-
+    (call(Goal) -> true ; throw(failed(Label))).
+state_kept :- findall(X,tmp_ums_state:state(X),Xs),Xs==[kept].
+import_text(Directive, Path, Suffix, Module) :-
+    format(atom(Text),':- ~w(~q~w).',[Directive,Path,Suffix]),
+    load_text(Text,[module(Module)]).
+
+main :- catch(checks,Error,(writeq(Error),nl,halt(1))),halt.
+checks :-
+    assertz(tmp_ums_state:state(kept)),
+    absolute_file_name('tmp_ums_state.pl',Path,[]),
+    import_text(use_module,Path,'',tmp_ums_full),
+    require(full,state_kept),require(full_export,tmp_ums_full:version(1)),
+    writeln(full_import_kept_state),
+    import_text(use_module,Path,', [state/1]',tmp_ums_select),
+    require(selective,state_kept),require(selective_export,tmp_ums_select:state(kept)),
+    writeln(selective_import_kept_state),
+    import_text(reexport,Path,', [state/1]',tmp_ums_reexport),
+    require(reexport,state_kept),require(reexport_call,tmp_ums_reexport:state(kept)),
+    writeln(reexport_kept_state),
+    '$create_module'(tmp_ums_thread),
+    thread_create(import_text(use_module,Path,', [state/1]',tmp_ums_thread),Thread,[]),
+    thread_join(Thread,Status),require(thread_status,Status==true),
+    require(thread,state_kept),require(thread_export,tmp_ums_thread:state(kept)),
+    writeln(thread_import_kept_state),
+    open('tmp_ums_state.pl',write,S),
+    write(S,':- module(tmp_ums_state,[state/1,version/1]).\n:- dynamic state/1.\nversion(2).\n'),close(S),
+    import_text(use_module,Path,'',tmp_ums_changed),
+    require(changed_file_state,state_kept),require(import_no_reload,tmp_ums_changed:version(1)),
+    writeln(import_ignores_file_change),
+    consult('tmp_ums_state.pl'),
+    findall(V,tmp_ums_state:version(V),Versions),require(explicit_reload,Versions==[2]),
+    writeln(explicit_consult_reloads).
+PL
+
+timeout 60 "$TPL" -q "$DRV" -g main </dev/null 2>&1
```

</details>
