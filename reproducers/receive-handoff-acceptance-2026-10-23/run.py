import os,sys,json,time,signal,subprocess,hashlib
from pathlib import Path
OUT=Path(__file__).resolve().parent
ROOT=OUT.parents[1]; SWI=ROOT.parent/'trinity-demonstrator'
SWIPL='/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299/build/src/swipl'
ENGINE=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests/receive-handoff-2026-10-23/upstream');TPL=str(ENGINE/'tpl')
ENV=dict(os.environ,SWIPL=SWIPL,TPL=TPL,TPL_LIBRARY_PATH=str(ENGINE/'library'),SDKROOT='/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk',TEST_PORT_BASE='44760',PATH='/tmp/trinity-acceptance-bin:'+os.environ['PATH'])
def run(label,cwd,cmd,timeout=1800):
 start=time.time();print('START',label,flush=True)
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen(cmd,cwd=cwd,env=ENV,stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
 r=dict(label=label,command=cmd,cwd=str(cwd),exit_code=rc,seconds=round(time.time()-start,3))
 (OUT/(label+'.json')).write_text(json.dumps(r,indent=2)+'\n');print('END',label,rc,r['seconds'],flush=True)
 return rc
if sys.argv[1]=='swi':
 run('swi-all',SWI,['bash','tools/test.sh'])
elif sys.argv[1]=='trealla':
 for label,cmd in [('engine-main',['sh','tests/run.sh']),('engine-misc',['sh','tests/run_misc.sh']),('engine-slow',['sh','tests/run_slow.sh'])]:run(label,ENGINE,cmd)
 run('trealla-unit',ROOT,['sh','tools/test.sh','unit'])
 run('native-interop',ROOT,['sh','tools/test.sh','interop'])
