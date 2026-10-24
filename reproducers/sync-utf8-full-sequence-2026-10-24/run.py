import os,sys,json,time,signal,subprocess,hashlib,socket,re,difflib
from pathlib import Path
OUT=Path(__file__).resolve().parent; ROOT=OUT.parents[1]
PRIOR=ROOT/'reproducers/sync-utf8-investigation-2026-10-24'
ENGINE=Path.home()/'.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine'
TPL=ENGINE/'tpl'; SWIPL=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl'
NODEBIN=Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def snapshot():
 files=[p for p in ROOT.rglob('*.pl') if '.build' not in p.parts and '.git' not in p.parts]+[ROOT/'tools/test.sh',TPL,SWIPL,ROOT/'.build/trealla-v3.13.10/tpl',Path('/Applications/swipl-win.app/Contents/MacOS/swipl'),Path('/Library/Frameworks/swipl.framework/Versions/A/swipl')]
 return {str(p):sha(p) for p in files if p.is_file()}
def snapshot_processes(label):
 text=subprocess.check_output(['ps','-axo','pid=,command='],text=True)
 rows=[line for line in text.splitlines() if line.split(maxsplit=1) and line.split(maxsplit=1)[0] in ['55051','42134','30612']]
 (OUT/f'processes-{label}.txt').write_text('\n'.join(rows)+'\n')
original=(ROOT/'tools/test.sh').read_text()
common=original.replace('ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)',f'ROOT={ROOT}\nSUITE_FAILURE=0')
common=common.replace('fail "$test_label timed out after ${TEST_TIMEOUT}s"',"printf 'ACCEPTANCE_TIMEOUT|%s|%s\\n' \"$test_label\" \"$command_exit\"; SUITE_FAILURE=1")
common=common.replace('fail "$test_label failed with exit status $command_exit"',"printf 'ACCEPTANCE_FAILURE|%s|%s\\n' \"$test_label\" \"$command_exit\"; SUITE_FAILURE=1")
common=common.replace('\n}\n\nrun_tpl_goal()', '\n    printf \'ACCEPTANCE_RESULT|%s|%s\\n\' "$test_label" "$command_exit"\n}\n\nrun_tpl_goal()',1)
common+='\nexit "$SUITE_FAILURE"\n'
old='''        start_background "$SWIPL" -q \\
            -g "use_module('$TRINITY_NODE_FILE'),node:node($swi_actor_port,[profile(actor),auth(open)]),thread_get_message(stop)"
        swi_actor_pid=$STARTED_PID'''
new='''        capture_backend_port=$((TEST_PORT_BASE + 50))
        start_background "$SWIPL" -q \\
            -g "use_module('$TRINITY_NODE_FILE'),set_setting(http:public_host,localhost),set_setting(http:public_port,$swi_actor_port),set_setting(http:public_scheme,http),use_module(library(socket)),tcp_socket(Socket),tcp_bind(Socket,ip(127,0,0,1):$capture_backend_port),tcp_listen(Socket,128),node:node($capture_backend_port,[tcp_socket(Socket),profile(actor),auth(open)]),thread_get_message(stop)"
        swi_actor_pid=$STARTED_PID
        wait_for_port "$capture_backend_port" || fail "SWI capture backend did not start"
        start_background python3 "$CAPTURE_PROXY" "$CAPTURE_DIR" "$capture_backend_port" "$swi_actor_port"
        capture_proxy_pid=$STARTED_PID'''
assert common.count(old)==1
capture=common.replace(old,new).replace('        stop_background "$swi_actor_pid"','        stop_background "$capture_proxy_pid"\n        stop_background "$swi_actor_pid"')
for name,content in [('direct',common),('captured',capture)]:
 (OUT/(name+'.sh')).write_text(content)
 (OUT/(name+'.diff')).write_text(''.join(difflib.unified_diff(original.splitlines(True),content.splitlines(True),fromfile='tools/test.sh',tofile=name+'.sh')))
# Validate that both runners retain the complete identical test body except fixture plumbing.
assert common.replace(old,new).replace('        stop_background "$swi_actor_pid"','        stop_background "$capture_proxy_pid"\n        stop_background "$swi_actor_pid"')==capture
before=snapshot();(OUT/'before.json').write_text(json.dumps(before,indent=2)+'\n')
snapshot_processes('before')
for base in [48760,49760]:
 for offset in range(1,51):
  with socket.socket() as s:s.bind(('127.0.0.1',base+offset))
results=[]
for label,base in [('captured',48760),('direct',49760)]:
 env=dict(os.environ,TPL=str(TPL),SWIPL=str(SWIPL),TPL_LIBRARY_PATH=str(ENGINE/'library'),SDKROOT='/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk',TEST_PORT_BASE=str(base),TEST_TIMEOUT='30',PATH=str(NODEBIN)+os.pathsep+os.environ['PATH'],CAPTURE_PROXY=str(PRIOR/'capture_proxy.py'),CAPTURE_DIR=str(OUT/'wire'))
 command=['sh',str(OUT/(label+'.sh')),'interop'];start=time.monotonic();print('START',label,flush=True)
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen(command,cwd=ROOT,env=env,stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=1800)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='outer_watchdog'
 logtext=(OUT/(label+'.log')).read_text(errors='replace');groups=[{'label':m[0],'exit_code':int(m[1])} for m in re.findall(r'^ACCEPTANCE_RESULT\|(.+)\|(\d+)$',logtext,re.M)]
 row=dict(label=label,command=command,port_base=base,exit_code=rc,seconds=round(time.monotonic()-start,3),groups=groups,utf8_warnings=[x for x in logtext.splitlines() if 'Illegal UTF-8' in x]);results.append(row)
 (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('DONE',label,rc,len(groups),row['seconds'],flush=True)
after=snapshot();(OUT/'after.json').write_text(json.dumps(after,indent=2)+'\n');(OUT/'preservation.json').write_text(json.dumps({'changed_files':[p for p in before if after.get(p)!=before[p]],'original_runner_sha256':sha(ROOT/'tools/test.sh')},indent=2)+'\n')
snapshot_processes('after')
subprocess.run([sys.executable,str(PRIOR/'analyze_wire.py'),str(OUT/'wire')],check=True)
