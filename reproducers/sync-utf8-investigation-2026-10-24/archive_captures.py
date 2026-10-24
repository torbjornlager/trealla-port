"""Losslessly package completed captures, verifying every archived byte first."""
from pathlib import Path
import tarfile,json,hashlib,shutil
OUT=Path(__file__).resolve().parent;rows=json.loads((OUT/'results.json').read_text());assert len(rows)==80
manifest=[]
for row in rows:
 folder=OUT/row['label'];wire=folder/'wire';archive=folder/'wire.tar.gz';files=[p for p in wire.rglob('*')if p.is_file()]
 expected={str(p.relative_to(folder)):hashlib.sha256(p.read_bytes()).hexdigest()for p in files}
 with tarfile.open(archive,'w:gz')as tar:
  for p in sorted(files):tar.add(p,arcname=str(p.relative_to(folder)),recursive=False)
 with tarfile.open(archive,'r:gz')as tar:
  actual={m.name:hashlib.sha256(tar.extractfile(m).read()).hexdigest()for m in tar.getmembers()if m.isfile()}
 assert actual==expected,row['label']
 manifest.append({'trial':row['label'],'archive':str(archive.relative_to(OUT)),'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'member_sha256':actual})
 shutil.rmtree(wire)
(OUT/'capture-archives.json').write_text(json.dumps(manifest,indent=2)+'\n');print('Verified archives',len(manifest))
