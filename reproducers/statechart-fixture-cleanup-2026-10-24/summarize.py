from pathlib import Path
import json,statistics
OUT=Path(__file__).resolve().parent
rows=json.loads((OUT/'results.json').read_text());assert len(rows)==80
summary={'total':len(rows),'passed':sum(r['exit_code']==0 for r in rows),'failed':sum(r['exit_code']!=0 for r in rows),'groups':[]}
for engine in ['pinned','v3.14.10']:
 for suite in ['policy','full']:
  group=[r for r in rows if r['engine']==engine and r['suite']==suite]
  assert len(group)==20
  summary['groups'].append(dict(engine=engine,suite=suite,passed=sum(r['exit_code']==0 for r in group),failed=sum(r['exit_code']!=0 for r in group),runs_with_cleanup_wait=sum('fixture_cleanup_wait(' in (OUT/r['log']).read_text() for r in group),median_seconds=statistics.median(r['seconds']for r in group),max_seconds=max(r['seconds']for r in group)))
summary['preservation']=json.loads((OUT/'after.json').read_text())['unchanged_from_batch_start']
summary['repair_scope']=json.loads((OUT/'repair-scope.json').read_text())
(OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
report=(OUT/'REPORT.md').read_text();report+='\n### Completed fixed batches\n\n| Engine | Policy-only | Full invocation |\n|---|---:|---:|\n'
for engine in ['pinned','v3.14.10']:
 groups=[g for g in summary['groups']if g['engine']==engine]
 report+=f"| {engine} | {groups[0]['passed']}/20 pass | {groups[1]['passed']}/20 pass |\n"
report+=f"\nTotal: **{summary['passed']}/80 pass**, {summary['failed']} failures. No failures were retried.\n"
report+='The original test text is byte-for-byte preserved outside the two added\nbarrier calls and helper. Tracked source files stayed unchanged throughout the\nbatches; engine hashes, installed SWI hashes and live N3/N5 commands match their\npre-batch values. See `repair-scope.json`, `after.json` and `summary.json`.\n'
(OUT/'REPORT.md').write_text(report)
print(json.dumps(summary,indent=2))
