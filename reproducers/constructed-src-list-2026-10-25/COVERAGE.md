# Constructed src_list admission coverage — 25 October 2026

Candidate runtime: committed Trealla-port `d0993e4` plus the bounded sandbox
repair; pending Boolean/URI edits excluded. Primary engine: exact unmodified
Trealla v3.14.10, matching library. SWI source: archived committed `786737f`,
separate verified SWI 10.1.18. [Repair/provenance](REPAIR.md) defines the fixture
snapshot and exclusions. Installed runtimes and n3/n5 are unchanged.

## Shared public-interface assertions

The same unchanged manifests/assertions run against both implementations.
These **50/50 passing** selections stay separate from experimental text results.

| Pack | SWI | Trealla |
|---|---|---|
| language-actor-0.1 | [7/7 pass](shared-local/swi-language-actor-0.1.json) | [7/7 pass](shared-local/trealla-language-actor-0.1.json) |
| copying-isolation-0.1 | [6/6 pass](shared-local/swi-copying-isolation-0.1.json) | [6/6 pass](shared-local/trealla-copying-isolation-0.1.json) |
| creation-validation-0.1 | [6/6 pass](shared-local/swi-creation-validation-0.1.json) | [6/6 pass](shared-local/trealla-creation-validation-0.1.json) |
| child-specs-0.1 | [6/6 pass](shared-local/swi-child-specs-0.1.json) | [6/6 pass](shared-local/trealla-child-specs-0.1.json) |

## Experimental portable-text 0.2

All 26 cases ran once per caller/peer configuration. No assertion, manifest,
reader flag or timeout was changed. These figures certify neither existing
ACTOR requirements nor full Unicode/portable-text support.

| Trealla source / engine | SWI caller → Trealla peer | Trealla caller → SWI peer | TXT-014 |
|---|---|---|---|
| Admission repair / unmodified v3.14.10 | [4 pass, 22 fail](portable-unmodified-engine/swi-portable-text.json) | [21 pass, 5 fail](portable-unmodified-engine/trealla-portable-text.json) | pass |
| Admission repair / separate JSON candidate | [4 pass, 22 fail](portable-json-candidate-engine/swi-portable-text.json) | [25 pass, 1 fail](portable-json-candidate-engine/trealla-portable-text.json) | pass |

Original TXT-014 is unchanged: runtime-constructed numeric lists, character lists,
source-variable sharing and exact child termination assertions now complete.

The four supplementary-character reader failures on the unmodified engine remain
separate (#1181); they pass with the existing JSON candidate. TXT-023's SWI-peer
source convention remains unresolved in both configurations. SWI's default
native-string convention and TXT-015 DCG sandbox block remain separate too.
Neither engine candidate is installed. Browser and GNU results are unmeasured
in this batch, and historical reports are preserved.

## Focused implementation checks

Both blacklist and whitelist regressions pass, as do existing sandbox, profile,
isolation and supervisor-admission groups. The new test fails on the original
sandbox as expected. [Unit results](repair-unit-results.json) record exact
commands and outputs. All twelve raw result reports validate their schema and
counts. [Preservation](repair-preservation.json) and the
[verification summary](repair-validation.json) record the boundaries.
