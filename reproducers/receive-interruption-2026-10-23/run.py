import subprocess,os,json,time,signal,hashlib
from pathlib import Path
root=Path(__file__).resolve().parents[2]; out=Path(__file__).resolve().parent
engines={'pinned':root/'.build/trealla-v3.13.10/tpl','upstream':Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-http-timeout/upstream-1178-42ebc21-2026-10-23/tpl')}
rows={}
for mode in ['adapter','native']:
 for label,exe in engines.items():
  for trial in range(1,6):
   key=f'{mode}-{label}-{trial}'
   env=dict(os.environ,TPL_LIBRARY_PATH=str(exe.parent/'library'))
   goal='run' if mode=='adapter' else 'run_native'
   cmd=[str(exe),'-g',f"consult('reproducers/receive-interruption-2026-10-23/probe.pl'),receive_interruption_probe:{goal},halt"]
   p=subprocess.Popen(cmd,cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True);start=time.monotonic()
   try:stdout,stderr=p.communicate(timeout=30);timed=False
   except subprocess.TimeoutExpired:
    os.killpg(p.pid,signal.SIGKILL);stdout,stderr=p.communicate();timed=True
   (out/f'{key}.stdout').write_text(stdout)
   rows[key]=dict(exit=p.returncode,timeout=timed,seconds=time.monotonic()-start,stderr=stderr,findings=stdout.count('finding('),complete='probe_complete' in stdout,engine=str(exe),engine_sha256=hashlib.sha256(exe.read_bytes()).hexdigest())
   (out/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print(key,rows[key]['findings'],rows[key]['complete'],flush=True)
