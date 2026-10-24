"""Summarize completed full-sequence runs and retain verified compressed captures."""
import json,hashlib,tarfile,shutil
from pathlib import Path
OUT=Path(__file__).resolve().parent
sha=lambda b:hashlib.sha256(b).hexdigest()
results=json.loads((OUT/'results.json').read_text());assert len(results)==2
wire=OUT/'wire'; streams=json.loads((wire/'wire-analysis.json').read_text()); connections=json.loads((wire/'connections.json').read_text())
frames=[f for s in streams for f in s.get('frames',[])]
summary={'runs':[{k:r[k] for k in ['label','exit_code','seconds']}|{'groups':len(r['groups']),'passed':sum(g['exit_code']==0 for g in r['groups']),'failed':[g for g in r['groups'] if g['exit_code']!=0],'utf8_warnings':r['utf8_warnings']} for r in results], 'wire':{'connections':len(connections),'directional_streams':len(streams),'bytes':sum(s['bytes'] for s in streams),'frames':len(frames),'text_messages':sum('utf8' in f for f in frames),'frame_or_utf8_errors':sum(len(s.get('errors',[]))for s in streams),'incomplete_websocket_tails':sum(bool(s.get('tail'))for s in streams),'invalid_json':sum(f.get('json')=='invalid'for f in frames),'empty_readiness_streams':sum(s['classification']=='incomplete_http' and s['bytes']==0 for s in streams),'forwarding_differences':sum(d['received']!=d['forwarded']for c in connections for d in c['directions'].values())}}
labels=[g['label'] for g in results[0]['groups']];assert labels==[g['label']for g in results[1]['groups']]
# Retain only the three live-node process records; discard unrelated process command lines.
process_records=[]
for name in ['before','after']:
 p=OUT/f'processes-{name}.txt'; rows=[line for line in p.read_text().splitlines()if line.split(maxsplit=1) and line.split(maxsplit=1)[0]in ['55051','42134','30612']];p.write_text('\n'.join(rows)+'\n');process_records.append(rows)
summary['live_node_process_records_unchanged']=process_records[0]==process_records[1] and len(process_records[0])==3
summary['preservation']=json.loads((OUT/'preservation.json').read_text())
(OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
# Archive all byte streams and chunk timestamps, validating every archived member before pruning duplicates.
archive=OUT/'wire.tar.gz'; members={p.name:sha(p.read_bytes())for p in wire.iterdir() if p.is_file()}
with tarfile.open(archive,'w:gz')as tar:
 for p in sorted(wire.iterdir()):tar.add(p,arcname=p.name)
with tarfile.open(archive,'r:gz')as tar:
 assert {m.name:sha(tar.extractfile(m).read())for m in tar.getmembers()if m.isfile()}==members
for name in ['wire-analysis.json','connections.json']:shutil.copy2(wire/name,OUT/name)
(OUT/'capture-archive.json').write_text(json.dumps({'archive':archive.name,'sha256':sha(archive.read_bytes()),'members':members},indent=2)+'\n')
shutil.rmtree(wire)
print(json.dumps(summary,indent=2))
