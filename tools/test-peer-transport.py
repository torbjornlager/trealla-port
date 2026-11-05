#!/usr/bin/env python3
"""Check deployed Trealla peer-file loading, propagation, validation and redaction."""
import argparse,os,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--tpl',required=True);a=p.parse_args()
with tempfile.TemporaryDirectory(prefix='trealla-peer-options-') as tmp:
    file=Path(tmp)/'peers.pl'
    valid="['https://peer.example'-fixture_secret]."
    cases=[('valid',valid,True),('empty','[].',True),('shape','[fixture_secret].',False),('extra',valid+' unexpected.',False),('term',"['https://peer.example'-secret(leak)].",False),('scheme',"['file:///tmp'-fixture_secret].",False),('newline',"['https://peer.example'-'fixture_secret\\nheader'].",False),('missing',None,False)]
    for name,text,good in cases:
        if text is None:file.unlink(missing_ok=True)
        else:file.write_text(text)
        env=dict(os.environ,WP_AUTH='private',WP_ADMIN_TOKEN='fixture_admin_secret_123456789',WP_PEER_TRANSPORT_TOKENS_FILE=str(file),TPL_LIBRARY_PATH=str(Path(a.tpl).parent/'library'))
        goal="consult('Deployment/start_node.pl'),(catch((deployment_start:check_config,"
        if name=='valid':goal+="deployment_start:deployment_options(_,O),memberchk(peer_transport_tokens(['https://peer.example'-fixture_secret]),O),receiver_lineage:transport_options('https://peer.example',[header('Authorization','Bearer fixture_secret')]),"
        goal+="writeln(peer_configuration_passed)),E,(writeq(E),nl,fail))->halt;halt(1))"
        r=subprocess.run([a.tpl,'-g',goal],cwd=ROOT,env=env,capture_output=True,text=True,timeout=15)
        output=r.stdout+r.stderr
        assert (r.returncode==0)==good,(name,output)
        assert not any(secret in output for secret in ['fixture_secret','fixture_admin_secret','secret(leak)']),(name,'credential leak')
        if not good:assert 'invalid_peer_transport_tokens_file' in output,(name,output)
        print(name,'passed')
