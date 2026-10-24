# Controlled local Trealla v3.14.10 update — 24 October 2026

## Outcome

The local n5 endpoint at **http://localhost:3060** now serves the verified,
unmodified Trealla **v3.14.10** build. `/version` reports `3.14.10`; `/readyz`
reports ready. Public HTTP and WebSocket smoke checks pass.

The old v3.13.10 runtime and its complete adjacent library directory remain
unchanged for rollback. SWI executables and the existing n3 process remain
unchanged. The n5 frontend process also remains unchanged.

## Installation and runtime selection

Source revision: `4ef56e3bbbcc6ca44085a4aa5eae0e6848c70294`.
Application revision at installation: `99bb5fb3d0bfc62d5c3febc4668ef940ea2a49fd`.
The exact executable and library tree from the accepted separate build were
copied without rebuilding or patching:

- Verified source build:
  `~/.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine`
- Installed local runtime: `trealla-port/.build/trealla-v3.14.10`
- Active local pointer: `trealla-port/.build/trealla-current`
- Retained rollback runtime: `trealla-port/.build/trealla-v3.13.10`

`installation.json` records the executable hash and every library-file hash.
The new executable SHA-256 is
`71f5ab7df3bde1a0a73cffccb2a762815895f6d2c2ef3f63ee52ef10baaeba1c`.
Binary and library hashes match the accepted build. The build remains
`NOSSL=1 NOFFI=1`; this update does not add TLS or FFI support. No global PATH
or system-wide Trealla installation was introduced.

The persistent public-node launcher is:

`~/.local/share/trinity-local-nodes/n5/start.sh`

It selects `.build/trealla-current/tpl` and explicitly exports the matching
`TPL_LIBRARY_PATH`. A copy is saved here as `start-n5.sh`. The live public backend
PID is recorded in `~/.local/share/trinity-local-nodes/n5/n5.pid`, and its log is
`~/.local/share/trinity-local-nodes/n5/n5.log`.

## Backend discovery and preserved configuration

There were two old Trealla processes. The previously recorded auxiliary node on
3061 was updated first. Checking the public endpoint then revealed that the
unchanged frontend on 3060 actually forwards to another old backend on **3062**,
started by a now-missing temporary launcher. That public backend was subsequently
updated too. The stale public version response disappeared when the actual
backend was updated; no frontend modification was necessary.

Both 3061 and 3062 now run v3.14.10 with matching libraries. The public launcher
and PID file refer to **3062**, not the auxiliary node. The auxiliary launch
command is retained as `start-auxiliary-3061.sh` in the same persistent state
folder; its PID is recorded in `auxiliary-3061.pid`.

The public backend retains:

- loopback bind on port 3062 and advertised URL `http://localhost:3060`;
- ACTOR profile, blacklist sandbox and open authentication;
- the original four localhost/127.0.0.1 browser origins;
- all tutorial sections and the common family/actor tutorial database.

The public `/node_info` response is identical before and after the update.
The replacement launcher imports actor APIs and operators before consulting
`Deployment/shared_db_common.pl` and `Deployment/shared_db_actor_common.pl`.
It also supplies both files through `load_shared_db_file/1`, so new private actor
namespaces receive the same tutorial definitions. An initial launcher parsed the
actor file before importing `!`, producing a syntax diagnostic; correcting the
startup import order removed that diagnostic. No runtime Prolog code was edited.

The old temporary startup files no longer exist, so the persistent launcher was
reconstructed from the live process, public node metadata and repository tutorial
sources. Logs and metadata retain the discovery and corrected startup stages.

## Smoke checks

Passed against the installed copy before switching the old node:

- signal-atomic receive deadlines, returning handlers and interruption regression.

Passed through the public frontend at `http://localhost:3060`:

- HTTP ordinary paging, first-slice `once`, variable sharing, failure/error answers;
- promise forwarding, full slices, offset and sharing, including an explicit timeout callback
  followed by successful retry;
- shared family data (`father_child(tom,sally)`);
- synchronous remote toplevel call and next: `[a,b]` then `[c]`;
- remote timed receive callback returning `waiting`;
- `first_solution` and exact before/after actor-list cleanup comparison;
- supervisor creation, count and halt with Trealla's existing list reply format;
- shared actor data routing Alice to `printer2`;
- ordinary query exception answer;
- toplevel halt, spawn-time termination notification and connection cleanup.

Initial combined smoke attempts returned nonzero because the new harness expected
SWI's `counts(0,0)` instead of Trealla's documented list of counts, and then passed
a URL to `remote_node_close/1`, which requires a connection handle. Stage output
identified both mistakes. The final harness uses Trealla's existing reply format
and the URL-based `remote_drop_connection/1`; it passes. These are harness
corrections, not runtime repairs. Initial failed logs are retained rather than
presented as successful runs. Canonical absolute imports are used in the final
harness; no claim is made that changing those imports repaired a runtime issue.

`public-n5-smoke.log` and `smoke-results.json` contain the successful final run.
`live-versions.json` confirms 3.14.10 at frontend 3060 and backends 3061/3062.
This batch used public HTTP/WebSocket interfaces, not browser terminal automation.
The earlier acceptance UI results remain separate evidence.

## Rollback

Keep both version directories intact. To roll the public backend back, stop the
PID recorded in the persistent `n5.pid` file, verify its port is released, then
start the same launcher with:

```sh
TRINITY_TREALLA_RUNTIME=/Users/torbjorn.lager/Documents/GitHub/trealla-port/.build/trealla-v3.13.10 \
  /Users/torbjorn.lager/.local/share/trinity-local-nodes/n5/start.sh
```

The launcher pairs the selected executable with that version's library directory.
It preserves the current public-node configuration. For a background restart,
redirect output to the persistent log and record the replacement PID. Rollback
has not been executed: the old binary and library hashes were verified unchanged,
and the old compatibility receive path has preceding regression coverage.

The active-pointer symlink can separately be returned to `trealla-v3.13.10` for
future launches. Changing the pointer alone does not restart existing processes.
The auxiliary 3061 process has its own PID/launcher and must be stopped and
relaunched separately if it too needs rollback. No rollback step involves n3.

## Preservation and evidence

`before.json`, `after.json`, `public-n5-before.json`, `public-n5-startup.json` and
`final-public-n5-pid.json` record discovery, configuration and process changes.
All final preservation checks pass: old executable/libraries unchanged, new
executable/libraries identical to the accepted build, SWI hashes unchanged, and
n3/frontend process IDs and commands unchanged. A read-only n3 readiness check
also succeeds.

The setup scripts retain the one-off installation sequence and original process
IDs as evidence; they are not generic repeatable installers. Use the persistent
launcher for future starts. The final copied launcher and `public-n5-goal.txt`
record the corrected public startup configuration. The runtime README's tested
version was updated. No source repair, commit or push was performed in this batch.
