from pathlib import Path
import os,subprocess,json,signal,time
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1]
ENGINE=Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine';TPL=ENGINE/'tpl'
ENV=dict(os.environ,TPL_LIBRARY_PATH=str(ENGINE/'library'));ROWS=[]
def run(label,file,goal,timeout=30,exe=TPL):
    env=dict(ENV,TPL_LIBRARY_PATH=str(exe.parent/'library'))
    cmd=[str(exe),'-g',f"(catch((consult('{file}'),{goal}),E,(writeq(E),nl,fail))->halt;halt(1))"]
    start=time.monotonic()
    with (OUT/(label+'.log')).open('w') as log:
        p=subprocess.Popen(cmd,cwd=ROOT,env=env,stdout=log,stderr=log,start_new_session=True)
        try:rc=p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
    ROWS.append(dict(label=label,command=cmd,exit_code=rc,seconds=round(time.monotonic()-start,3)))
    (OUT/'atomic-repeat-results.json').write_text(json.dumps(ROWS,indent=2)+'\n')
    if rc!=0 or not label[-3:].isdigit() or int(label[-3:])%20==0:print(label,rc,flush=True)

for i in range(1,11):
    run(f"atomic-final-{i:03}",ROOT/"receive_atomic_tests.pl","receive_atomic_tests:run")
