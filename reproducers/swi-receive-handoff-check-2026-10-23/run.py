import json,subprocess,hashlib
from pathlib import Path
root=Path(__file__).resolve().parents[2];out=Path(__file__).resolve().parent
engines={'installed':'/Applications/swipl-win.app/Contents/MacOS/swipl','separate-jan-fix':'/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299/build/src/swipl'}
r={}
for label,exe in engines.items():
 for mode in ['run','control']:
  cmd=[exe,'-q','-s',str(out/'probe.pl'),'-g',f'receive_handoff_swi_gated:{mode},halt']
  p=subprocess.run(cmd,cwd=root,capture_output=True,text=True,timeout=30)
  r[label+'-'+mode]={'command':cmd,'exit_code':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'missing_count':p.stdout.count('failed(missing_unrelated,absent,absent)'),'version':subprocess.check_output([exe,'--version'],text=True).strip()}
  (out/'results.json').write_text(json.dumps(r,indent=2)+'\n')
  print(label,mode,p.returncode,r[label+'-'+mode]['missing_count'],flush=True)
