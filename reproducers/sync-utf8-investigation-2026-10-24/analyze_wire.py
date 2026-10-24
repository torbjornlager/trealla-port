"""Offline WebSocket framing/UTF-8 checks on concatenated raw TCP streams."""
import hashlib,json,struct,sys
from pathlib import Path
def decode_frames(data,client=True):
 rows=[];errors=[];offset=0;fragment=None;fragment_opcode=None
 while offset<len(data):
  start=offset
  if len(data)-offset<2:return rows,errors,{'offset':start,'kind':'incomplete_header'}
  first,second=data[offset:offset+2];offset+=2;fin=bool(first&128);opcode=first&15;masked=bool(second&128);length=second&127
  if length in [126,127]:
   n=2 if length==126 else 8
   if len(data)-offset<n:return rows,errors,{'offset':start,'kind':'incomplete_length'}
   length=int.from_bytes(data[offset:offset+n],'big');offset+=n
  if length>64*1024*1024:return rows,errors,{'offset':start,'kind':'implausible_length','length':length}
  n=4 if masked else 0
  if len(data)-offset<n+length:return rows,errors,{'offset':start,'kind':'incomplete_payload','declared':length,'available':len(data)-offset-n}
  key=data[offset:offset+n];offset+=n;payload=data[offset:offset+length];offset+=length
  if masked:payload=bytes(b^key[i%4]for i,b in enumerate(payload))
  row={'offset':start,'length':length,'opcode':opcode,'fin':fin,'masked':masked,'payload_sha256':hashlib.sha256(payload).hexdigest()};rows.append(row)
  if first&112 or opcode not in [0,1,2,8,9,10] or masked!=client or (opcode>=8 and(not fin or length>125)):
   errors.append({'offset':start,'kind':'invalid_frame_header','first':first,'second':second})
  message=None
  if opcode in [1,2]:
   if fragment is not None:errors.append({'offset':start,'kind':'overlapping_fragment'})
   if fin:
    if opcode==1:message=payload
   else:fragment=bytearray(payload);fragment_opcode=opcode
  elif opcode==0:
   if fragment is None:errors.append({'offset':start,'kind':'unexpected_continuation'})
   else:
    fragment.extend(payload)
    if fin:
     if fragment_opcode==1:message=bytes(fragment)
     fragment=None;fragment_opcode=None
  elif opcode==8 and length>=2:
   try:payload[2:].decode('utf-8')
   except UnicodeDecodeError as e:errors.append({'offset':start,'kind':'invalid_close_utf8','error':str(e)})
  if message is not None:
   try:
    text=message.decode('utf-8');row['utf8']='valid'
    try:
     obj=json.loads(text);row['json']='valid'
     if isinstance(obj,dict):row['command_or_type']=obj.get('command',obj.get('type'))
    except (ValueError,TypeError):row['json']='invalid'
   except UnicodeDecodeError as e:
    row['utf8']='invalid';errors.append({'offset':start,'kind':'invalid_text_utf8','payload_index':e.start,'error':str(e),'nearby_hex':message[max(0,e.start-12):e.end+12].hex()})
 return rows,errors,({'kind':'unfinished_fragment'}if fragment is not None else None)
def analyze(path,client=True):
 data=path.read_bytes();split=data.find(b'\r\n\r\n');r={'file':path.name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
 if split<0:r['classification']='incomplete_http';return r
 headers=data[:split+4];r['first_line']=headers.split(b'\r\n')[0].decode('ascii','replace')
 if (client and b'upgrade: websocket' not in headers.lower())or(not client and not r['first_line'].startswith('HTTP/1.1 101')):
  r['classification']='http';return r
 r['classification']='websocket';r['frames'],r['errors'],r['tail']=decode_frames(data[split+4:],client);return r
if __name__=='__main__':
 directory=Path(sys.argv[1]);rows=[analyze(f,f.name.endswith('c2s.bin'))for f in sorted(directory.glob('*.bin'))];(directory/'wire-analysis.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps({'streams':len(rows),'errors':sum(len(r.get('errors',[]))for r in rows),'incomplete_tails':sum(bool(r.get('tail'))for r in rows)}))
