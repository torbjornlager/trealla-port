"""One complete unit checkpoint; preserve commands and watchdogs, collect all groups."""
from pathlib import Path
import os,subprocess,json,hashlib,time,signal,socket,re,difflib
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[1]
ENGINE=Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine'
TPL=ENGINE/'tpl';SWIPL=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl';NODE_BIN=Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def snapshot():
 files=[p for p in ROOT.rglob('*.pl')if '.build'not in p.parts and '.git'not in p.parts]+[ROOT/'tools/test.sh']
 installed=[ROOT/'.build/trealla-v3.13.10/tpl',Path('/Applications/swipl-win.app/Contents/MacOS/swipl'),Path('/Library/Frameworks/swipl.framework/Versions/A/swipl')]
 return {'source_sha256':{str(p.relative_to(ROOT)):sha(p)for p in files},'engine_sha256':{str(p):sha(p)for p in [TPL,SWIPL]},'installed_sha256':{str(p):sha(p)for p in installed},'live_processes':subprocess.check_output(['ps','-p','55051,42134,30612','-o','pid=,command='],text=True),'upstream_head':subprocess.check_output(['git','-C',str(ENGINE),'rev-parse','HEAD'],text=True).strip(),'upstream_tracked_status':subprocess.check_output(['git','-C',str(ENGINE),'status','--short','--untracked-files=no'],text=True)}
original=(ROOT/'tools/test.sh').read_text();s=original.replace('ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)',f'ROOT={ROOT}\nSUITE_FAILURE=0')
s=s.replace('fail "$test_label timed out after ${TEST_TIMEOUT}s"',"printf 'FINAL_TIMEOUT|%s|%s\\n' \"$test_label\" \"$command_exit\"; SUITE_FAILURE=1")
s=s.replace('fail "$test_label failed with exit status $command_exit"',"printf 'FINAL_FAILURE|%s|%s\\n' \"$test_label\" \"$command_exit\"; SUITE_FAILURE=1")
s=s.replace('\n}\n\nrun_tpl_goal()', '\n    printf \'FINAL_RESULT|%s|%s\\n\' "$test_label" "$command_exit"\n}\n\nrun_tpl_goal()',1)
s=s.replace("printf '\\nALL %s TESTS PASSED\\n' \"$MODE\"", "printf '\\nCOMPLETE %s TESTS; suite failure status %s\\n' \"$MODE\" \"$SUITE_FAILURE\"\nexit \"$SUITE_FAILURE\"")
assert s!=original and 'exit "$SUITE_FAILURE"'in s
runner=OUT/'test-unit-final.sh';runner.write_text(s)
(OUT/'unit-final-runner.diff').write_text(''.join(difflib.unified_diff(original.splitlines(True),s.splitlines(True),fromfile='tools/test.sh',tofile=runner.name)))
# Everything between run_tpl_goal and the final reporting line is byte-identical.
start=original.index('run_tpl_goal()');end=original.index("printf '\\nALL %s TESTS PASSED")
assert original[start:end]in s
(OUT/'unit-final-scope.json').write_text(json.dumps({'original_runner_sha256':sha(ROOT/'tools/test.sh'),'test_commands_and_suite_body_byte_identical':True,'test_timeout_seconds':30,'watchdog_term_then_kill_delay_seconds':2},indent=2)+'\n')
BEFORE=snapshot();(OUT/'unit-final-before.json').write_text(json.dumps(BEFORE,indent=2)+'\n')
for port in range(50761,50861):
 with socket.socket()as sock:sock.bind(('127.0.0.1',port))
env=dict(os.environ,TPL=str(TPL),SWIPL=str(SWIPL),TPL_LIBRARY_PATH=str(ENGINE/'library'),SDKROOT='/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk',TEST_PORT_BASE='50760',TEST_TIMEOUT='30',PATH=str(OUT/'bin')+os.pathsep+str(NODE_BIN)+os.pathsep+os.environ['PATH'])
command=['sh',str(runner),'unit'];start=time.monotonic();print('START final complete unit suite',flush=True)
with (OUT/'port-unit-final.log').open('w')as log:
 p=subprocess.Popen(command,cwd=ROOT,env=env,stdout=log,stderr=log,start_new_session=True)
 try:rc=p.wait(timeout=1800)
 except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='outer_watchdog_timeout'
text=(OUT/'port-unit-final.log').read_text(errors='replace');groups=[{'label':m[0],'exit_code':int(m[1])}for m in re.findall(r'^FINAL_RESULT\|(.+)\|(\d+)$',text,re.M)]
result={'command':command,'cwd':str(ROOT),'exit_code':rc,'seconds':round(time.monotonic()-start,3),'groups':groups,'total':len(groups),'passed':sum(g['exit_code']==0 for g in groups),'failed':[g for g in groups if g['exit_code']!=0],'timeouts':re.findall(r'^FINAL_TIMEOUT\|(.+)$',text,re.M),'skips':[x for x in text.splitlines()if 'SKIP:'in x]}
(OUT/'unit-final-results.json').write_text(json.dumps(result,indent=2)+'\n');AFTER=snapshot();AFTER['unchanged_from_batch_start']={k:AFTER[k]==BEFORE[k]for k in BEFORE};(OUT/'unit-final-after.json').write_text(json.dumps(AFTER,indent=2)+'\n')
print('COMPLETE',json.dumps({k:result[k]for k in ['exit_code','seconds','total','passed','failed','timeouts','skips']}),flush=True)
raise SystemExit(0 if rc==0 and len(groups)==75 and not result['failed']else 1)
