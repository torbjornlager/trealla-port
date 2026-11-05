# Remote formatted output repair

Development qualification on 5 November 2026. No release pins, public services
or installed engines were changed.

The deployed N5 could spawn and exchange messages with N4. An actor whose
entry goal was `format/2` instead ended with
`existence_error(procedure,sandbox_format/2)`. Copied `pong/0` clauses had the
same private helper. The tutorial waits for normal `down(...,true)` messages,
so that remote exception appeared as a hang. See `public-n5-before.json`.

The source-copy decompiler now restores `format/2`. The remote spawn boundary
also restores the output bridge after validation, retaining callable metadata
in other framework terms. This works for query workers borrowing session
source and sourceless workers with only the minimal bootstrap. The receiving
node still validates and rewrites the public goal and source itself.

Formatted SWI text is decoded at the browser boundary instead of displaying its
character-list representation. The term-output channel retains list rendering.

The exact HTML tutorial source was extracted from the demonstrator, with only
the peer URI substituted for a disposable native SWI listener. It completed all
three exchanges, delivered eight acknowledged output events and returned
success. Inline remote output passed both with and without loaded session
source. The corresponding event records are checked in beside this report.

The permanent interop regression `browser_remote_format_test/3` checks the
exchange, inline `format/1-2` in both shell modes, and `write([a,b])` rendering.
Its native peer uses the fixture's explicit internal transport credential for
the return I/O route; unauthenticated transport headers grant no such access.

Engines: released Trealla v3.14.20 and `/usr/local/bin/swipl` 10.1.19.
`development-source-sha256.json` identifies the tested dirty source snapshot,
which also contains the separately developed localhost RPC repair.
The source-capture unit regression checks variable sharing and ensures export
does not instantiate partially specified module-qualified data.

Validation completed: 88 unit groups and 71 interoperability groups passed.
The final suite log is `suite.log`. The runner was a temporary copy of
`tools/test.sh` with its repository root fixed and the existing 0.2-second
fixture startup sleeps increased to one second for this macOS/Rosetta run.
The unchanged short wait had produced a connection-refused startup failure;
no engine or service configuration was changed. The export variable-sharing
regression was also run directly after its final update and passed.
