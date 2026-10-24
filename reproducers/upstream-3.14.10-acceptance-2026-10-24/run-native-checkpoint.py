import subprocess,os,json,socket,time,hashlib,sys
from pathlib import Path
ROOT=Path.cwd();OUT=ROOT/'reports/2026-10-24-trealla-v3.14.10-acceptance';OUT.mkdir(exist_ok=True)
SWI=ROOT.parent/'trinity-demonstrator';TREALLA=ROOT.parent/'trealla-port'
SWIPL='/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl';TPL=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests/trealla-v3.14.10-acceptance-2026-10-24/engine/tpl')
ENV=dict(os.environ,TPL_LIBRARY_PATH=str(TPL.parent/'library'))
procs=[];logs=[]
PEER_PORT=None
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def quote(s):return "'"+str(s).replace("'","''")+"'"
def version(cmd):return subprocess.check_output(cmd,env=ENV,text=True).strip()
def source(p):return {'revision':version(['git','-C',str(p),'rev-parse','HEAD']),'dirty':version(['git','-C',str(p),'status','--short']).splitlines()}
def tracked_hash(p):
 files=subprocess.check_output(['git','ls-files','-z'],cwd=p).decode().split('\0')
 return hashlib.sha256('\n'.join(f+':'+sha(p/f) for f in files if f and (p/f).is_file()).encode()).hexdigest()
meta={'started_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'scope':'Native SWI/Trealla checkpoint; GNU and browser engines not rerun','sources':{k:source(p) for k,p in [('conformance',ROOT),('swi',SWI),('trealla',TREALLA)]},'versions':{'swi':version([SWIPL,'--version']),'trealla':version([str(TPL),'-g','current_prolog_flag(version_data,V),writeq(V),nl,halt'])},'binaries':{k:{'path':str(p),'sha256_before':sha(p)} for k,p in [('swi',Path(SWIPL)),('trealla',TPL)]},'runtime_trees_before':{k:tracked_hash(p) for k,p in [('swi',SWI),('trealla',TREALLA)]},'inputs':{str(p.relative_to(ROOT)):sha(p) for folder in ['cases','profiles','baselines','runner'] for p in (ROOT/folder).glob('*') if p.is_file()},'nodes':{},'runs':[]}
def save():(OUT/'provenance.json').write_text(json.dumps(meta,indent=2)+'\n')
def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def launch(name,cwd,cmd,p):
 log=(OUT/(name+'-node.log')).open('w');logs.append(log);proc=subprocess.Popen(cmd,cwd=cwd,env=ENV,stdout=log,stderr=log);procs.append(proc)
 for _ in range(150):
  if proc.poll() is not None:raise RuntimeError(f'{name} exited {proc.returncode}')
  try:
   with socket.create_connection(('127.0.0.1',p),timeout=.1):return
  except OSError:time.sleep(.05)
 raise RuntimeError(name+' readiness timeout')
def run(label,command,scope):
 start=time.time()
 with (OUT/(label+'.log')).open('w') as log:
  try:r=subprocess.run(command,cwd=ROOT,env=ENV,stdout=log,stderr=log,timeout=150);code=r.returncode
  except subprocess.TimeoutExpired:code='timeout'
 result={'label':label,'scope':scope,'exit_code':code,'elapsed_seconds':round(time.time()-start,2),'report':label+'.json' if (OUT/(label+'.json')).exists() else None,'log':label+'.log','command':command}
 meta['runs'].append(result);save();print(label,code,flush=True)
def pack(name,candidate,url,peer=None):
 label=candidate+'-'+name+('-to-'+peer[0] if peer else '')
 cmd=[sys.executable,'runner/baseline.py','--manifest','cases/'+name+'-0.1.json','--url',url,'--candidate',candidate,'--profile','actor','--timeout','10','--report',str(OUT/(label+'.json'))]
 if peer:cmd+=['--peer',peer[1]]
 run(label,cmd,'diagnostic' if 'diagnostics' in name else 'required')
save()
try:
 for name,cwd in [('trealla',TREALLA),('swi',SWI)]:
  p=port();url=f'http://127.0.0.1:{p}';meta['nodes'][name]={'url':url,'profile':'actor','sandbox':'blacklist','auth':'open disposable loopback fixture','bind_address':'127.0.0.1'}
  if name=='swi':
   fixture=OUT/'peer_transport_fixture.pl'
   fixture.write_text("% Disposable loopback fixture; token is public test data, not a credential.\n:- multifile distribution:hook_transport_options/2.\ndistribution:hook_transport_options('http://127.0.0.1:"+str(PEER_PORT)+"',[request_header('Authorization'='Bearer checkpoint-fixture-peer')]).\n")
   meta['peer_authentication']={'fixture':fixture.name,'peer':'trealla','capabilities':['execute','internal_transport'],'token':'public checkpoint fixture only','negative_authority_coverage':'native-interop.log delegated-lineage checks'}
   goal=f"use_module(library(sgml)),use_module(library(option)),use_module({quote(SWI/'prolog/web_prolog/node.pl')}),consult({quote(fixture)}),set_setting(http:public_host,'127.0.0.1'),set_setting(http:public_port,{p}),set_setting(http:public_scheme,http),use_module(library(socket)),tcp_socket(Socket),tcp_bind(Socket,ip(127,0,0,1):{p}),tcp_listen(Socket,128),node:node({p},[tcp_socket(Socket),profile(actor),sandbox(blacklist),auth(open)]),thread_get_message(stop)";cmd=[SWIPL,'-f','none','-q','-g',goal]
  else:
   goal=f"consult(distribution),web_prolog:web_prolog_node({p},[bind_address('127.0.0.1'),node_url({quote(url)}),profile(actor),sandbox(blacklist),auth(open),bearer_token(checkpoint_peer,'checkpoint-fixture-peer',[execute,internal_transport])]),thread_get_message(stop)";cmd=[str(TPL),'-g',goal]
  meta['nodes'][name]['command']=cmd;launch(name,cwd,cmd,p);save()
  if name=='trealla':PEER_PORT=p
 for name,node in meta['nodes'].items():
  url=node['url'];ws=url.replace('http:','ws:')+'/ws'
  for suite in ['isobase-http','isobase-diagnostics']:pack(suite,name,url)
  for suite in ['language-actor','wire-capabilities']:pack(suite,name,ws)
  for suite in ['actor-core','actor-workers','actor-behaviours','actor-supervisors','supervisor-diagnostics','worker-diagnostics','portable-text']:
   label=name+'-'+suite;scope='diagnostic' if 'diagnostics' in suite else 'experimental' if suite=='portable-text' else 'supporting'
   run(label,[sys.executable,'runner/run.py','--manifest','cases/'+suite+'-0.1.json','--ws-url',ws,'--candidate',name,'--advertised-profile','actor','--timeout','8','--report',str(OUT/(label+'.json'))],scope)
 for name,node in meta['nodes'].items():
  for peer,target in meta['nodes'].items():
   pack('interop-http',name,node['url'],(peer,target['url']))
   pack('interop-actor',name,node['url'].replace('http:','ws:')+'/ws',(peer,target['url']))
finally:
 for p in reversed(procs):
  p.terminate()
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:p.kill();p.wait()
 for log in logs:log.close()
 meta['finished_at']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime());meta['runtime_trees_after']={k:tracked_hash(p) for k,p in [('swi',SWI),('trealla',TREALLA)]};meta['runtime_files_unchanged']=meta['runtime_trees_before']==meta['runtime_trees_after']
 for item in meta['binaries'].values():item['sha256_after']=sha(Path(item['path']))
 save()
print('FINISHED; runtime files unchanged:',meta['runtime_files_unchanged'],flush=True)
