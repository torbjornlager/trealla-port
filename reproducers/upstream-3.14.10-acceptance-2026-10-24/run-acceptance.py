import os,json,time,signal,subprocess,hashlib
from pathlib import Path
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1]
ENGINE=Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine'
TPL=ENGINE/'tpl';SWIPL=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl'
NODE_BIN=Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin'
ENV=dict(os.environ,TPL=str(TPL),SWIPL=str(SWIPL),TPL_LIBRARY_PATH=str(ENGINE/'library'),SDKROOT='/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk',TEST_PORT_BASE='45760',PATH=str(OUT/'bin')+os.pathsep+str(NODE_BIN)+os.pathsep+os.environ['PATH'])
RESULTS=[]
def run(label,cwd,cmd,timeout=1800):
    print('START',label,flush=True);start=time.monotonic()
    with (OUT/(label+'.log')).open('w') as log:
        p=subprocess.Popen(cmd,cwd=cwd,env=ENV,stdout=log,stderr=log,start_new_session=True)
        try:rc=p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
    row=dict(label=label,command=list(map(str,cmd)),cwd=str(cwd),exit_code=rc,seconds=round(time.monotonic()-start,3));RESULTS.append(row)
    (OUT/'acceptance-results.json').write_text(json.dumps(RESULTS,indent=2)+'\n');print('DONE',label,rc,row['seconds'],flush=True)
    return rc
if __name__=='__main__':
    for label,script in [('engine-main','tests/run.sh'),('engine-misc','tests/run_misc.sh'),('engine-slow','tests/run_slow.sh')]:run(label,ENGINE,['sh',script])
    run('port-unit',ROOT,['sh','tools/test.sh','unit'])
    run('native-interop',ROOT,['sh','tools/test.sh','interop'])
    run('shared-conformance',ROOT.parent/'trinity-conformance',['python3',str(OUT/'run-native-checkpoint.py')])
    raise SystemExit(0 if all(r['exit_code']==0 for r in RESULTS) else 1)
