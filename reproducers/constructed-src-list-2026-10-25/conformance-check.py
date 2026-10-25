"""Run unchanged local shared packs on isolated committed-source fixtures."""
from pathlib import Path
import json,os,signal,socket,subprocess,sys,tempfile,time
HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
CONF=REPO.parent/'trinity-conformance'
sys.path.insert(0,str(CONF/'adapters'))
from local_promises import free_port,quote,sha
source=Path(json.loads((HERE/'candidate-source.json').read_text())['path'])
swi_source=REPO.parent/'swi-prolog-node'
swipl=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swi-default-startup-2026-10-24/runtime/bin/swipl')
tpl=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine/tpl')
out=HERE/'shared-local';out.mkdir(exist_ok=False)
env=dict(os.environ,TPL_LIBRARY_PATH=str(tpl.parent/'library'))
for key in ['SWI_HOME_DIR','SWIPL_HOME_DIR','WP_CONFIG_FILE','WP_ASSET_ROOT','WP_WASM_SOURCE_DIR','WP_NATIVE_STATE','WP_NATIVE_MODE']:env.pop(key,None)
processes=[];logs=[];nodes={};runs=[]
pro={'runs':runs,'nodes':nodes,'sources':{},'scope':'unchanged language/copying/creation/child-spec packs; no experimental counts in these totals','input_hashes':{}}
try:
    with tempfile.TemporaryDirectory(prefix='src-list-conformance-') as d:
        d=Path(d)
        for name,repo in [('swi',swi_source),('trealla',source)]:
            revision=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
            tar=d/(name+'.tar');dest=d/name;dest.mkdir()
            subprocess.run(['git','-C',str(repo),'archive','--format=tar','--output='+str(tar),revision],check=True)
            subprocess.run(['tar','-xf',str(tar),'-C',str(dest)],check=True)
            pro['sources'][name]={'revision':revision,'archive_sha256':sha(tar),'root':str(repo)}
            port=free_port();url=f'http://127.0.0.1:{port}'
            if name=='swi':
                goal=f"use_module(library(sgml)),use_module(library(option)),consult({quote(dest/'load.pl')}),set_setting(http:public_host,'127.0.0.1'),set_setting(http:public_port,{port}),set_setting(http:public_scheme,http),use_module(library(socket)),tcp_socket(S),tcp_bind(S,ip(127,0,0,1):{port}),tcp_listen(S,128),node:node({port},[tcp_socket(S),profile(actor),sandbox(blacklist),auth(open)]),thread_get_message(stop)"
                cmd=[str(swipl),'-f','none','-q','-g',goal]
            else:
                goal=f"use_module(web_prolog),use_module(distribution),web_prolog:web_prolog_node({port},[bind_address('127.0.0.1'),node_url({quote(url)}),profile(actor),sandbox(blacklist),auth(open)]),thread_get_message(stop)"
                cmd=[str(tpl),'-g',goal]
            log=(out/(name+'-node.log')).open('w');logs.append(log)
            p=subprocess.Popen(cmd,cwd=dest,env=env,stdout=log,stderr=log,start_new_session=True);processes.append(p)
            nodes[name]={'url':url,'pid':p.pid,'command':cmd}
            for _ in range(150):
                if p.poll() is not None:raise RuntimeError(name+' startup failed')
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.1):break
                except OSError:time.sleep(.05)
            else:raise TimeoutError(name+' startup')
        for name,node in nodes.items():
            for pack in ['language-actor-0.1','copying-isolation-0.1','creation-validation-0.1','child-specs-0.1']:
                label=name+'-'+pack;manifest=CONF/'cases'/(pack+'.json');report=out/(label+'.json')
                cmd=[sys.executable,'runner/baseline.py','--manifest',str(manifest),'--url',node['url'].replace('http:','ws:')+'/ws','--candidate',name,'--profile','actor','--timeout','8','--report',str(report)]
                with (out/(label+'.log')).open('w') as log:r=subprocess.run(cmd,cwd=CONF,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=90)
                runs.append({'label':label,'report':report.name,'command':cmd,'exit_code':r.returncode})
                pro['input_hashes'][str(manifest.relative_to(CONF))]=sha(manifest)
                print(label,r.returncode,flush=True)
finally:
    for p in reversed(processes):
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGTERM)
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
    for log in logs:log.close()
    pro['owned_nodes_stopped']=all(p.poll() is not None for p in processes)
    pro['engine_sha256']={str(p):sha(p) for p in [swipl,tpl]}
    pro['input_hashes']['runner/baseline.py']=sha(CONF/'runner/baseline.py')
    pro['input_hashes']['conformance-check.py']=sha(Path(__file__))
    (out/'provenance.json').write_text(json.dumps(pro,indent=2)+'\n')
