#!/usr/bin/env python3
import subprocess,sys,os,signal
seconds=float(sys.argv[1]);p=subprocess.Popen(sys.argv[2:],start_new_session=True)
try:r=p.wait(timeout=seconds)
except subprocess.TimeoutExpired:
 os.killpg(p.pid,signal.SIGKILL);p.wait();sys.exit(124)
sys.exit(r if r>=0 else 128-r)
