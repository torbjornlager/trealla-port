import json,os,time,subprocess,signal
from pathlib import Path
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1];meta=json.loads((OUT/'before.json').read_text());results=[]
for i in range(1,31):
 for name in ['candidate','unmodified']:
  engine=Path(meta['binaries'][name]['path']);label=f'owner-{name}-{i:03}'
  goal="consult('"+str(OUT/'owner-tests.pl')+"'),(catch(http_paging_cleanup_tests:interruption(lookahead),E,(writeq(E),nl,fail))->halt;halt(1))"
  cmd=[str(engine),'-g',goal];start=time.time();sample=None
  with (OUT/(label+'.log')).open('w') as log:
   p=subprocess.Popen(cmd,cwd=ROOT,env=dict(os.environ,TPL_LIBRARY_PATH=str(engine.parent/'library')),stdout=log,stderr=log,start_new_session=True)
   try:rc=p.wait(timeout=4)
   except subprocess.TimeoutExpired:
    sample_cmd=['/usr/bin/sample',str(p.pid),'1','-file',str(OUT/(label+'.sample.txt'))]
    try:
     sr=subprocess.run(sample_cmd,capture_output=True,text=True,timeout=4);sample=dict(command=sample_cmd,exit_code=sr.returncode,stdout=sr.stdout,stderr=sr.stderr)
    except subprocess.TimeoutExpired:sample=dict(command=sample_cmd,exit_code='sampler_timeout')
    remaining=max(.1,10-(time.time()-start))
    try:rc=p.wait(timeout=remaining)
    except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
  row=dict(engine=name,trial=i,exit_code=rc,seconds=round(time.time()-start,3),log=label+'.log',command=cmd,sample=sample);results.append(row)
  (OUT/'owner-results.json').write_text(json.dumps(results,indent=2)+'\n')
  if rc!=0 or i%10==0:print(label,rc,flush=True)
print('OWNER CHECK FINISHED',len(results),'runs;',sum(r['exit_code']!=0 for r in results),'nonzero',flush=True)
