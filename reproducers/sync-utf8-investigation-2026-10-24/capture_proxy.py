"""Loopback TCP forwarder: record raw streams, forward the original bytes."""
import asyncio,json,time,signal,sys
from pathlib import Path
OUT=Path(sys.argv[1]);BACK=int(sys.argv[2]);FRONT=int(sys.argv[3]);OUT.mkdir(exist_ok=True,parents=True)
connections=[];tasks=set();writers=set()
async def accept(reader,writer):
 task=asyncio.current_task();tasks.add(task);writers.add(writer)
 number=len(connections)+1;row={'id':number,'started_at':time.time(),'peer':writer.get_extra_info('peername'),'directions':{}};connections.append(row)
 index=(OUT/f'{number:03}-chunks.jsonl').open('w');peer_writer=None
 try:
  peer_reader,peer_writer=await asyncio.open_connection('127.0.0.1',BACK);writers.add(peer_writer)
  async def pipe(src,dst,direction):
   received=forwarded=0
   with (OUT/f'{number:03}-{direction}.bin').open('wb') as capture:
    try:
     while True:
      data=await src.read(65536)
      if not data:
       try:dst.write_eof();await dst.drain()
       except (OSError,RuntimeError):pass
       break
      capture.write(data);capture.flush();index.write(json.dumps({'time_ns':time.time_ns(),'direction':direction,'offset':received,'size':len(data)})+'\n');index.flush();received+=len(data)
      dst.write(data);await dst.drain();forwarded+=len(data)
    except (OSError,RuntimeError) as e:row.setdefault('io_errors',[]).append({'direction':direction,'error':repr(e)})
    finally:row['directions'][direction]={'received':received,'forwarded':forwarded}
  await asyncio.gather(pipe(reader,peer_writer,'c2s'),pipe(peer_reader,writer,'s2c'))
 except Exception as e:row['error']=repr(e)
 finally:
  for w in [writer,peer_writer]:
   if w is not None:w.close();writers.discard(w)
  index.close();row['ended_at']=time.time();tasks.discard(task)
async def main():
 stop=asyncio.Event();loop=asyncio.get_running_loop()
 for sig in [signal.SIGTERM,signal.SIGINT]:loop.add_signal_handler(sig,stop.set)
 server=await asyncio.start_server(accept,'127.0.0.1',FRONT);print(json.dumps({'ready':True,'port':FRONT}),flush=True)
 await stop.wait();server.close();await server.wait_closed()
 for w in list(writers):w.close()
 if tasks:
  done,pending=await asyncio.wait(list(tasks),timeout=2)
  for task in pending:task.cancel()
  if pending:await asyncio.gather(*pending,return_exceptions=True)
 (OUT/'connections.json').write_text(json.dumps(connections,indent=2)+'\n')
asyncio.run(main())
