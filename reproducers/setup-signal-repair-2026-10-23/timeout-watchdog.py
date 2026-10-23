#!/usr/bin/env python3
import sys,subprocess,os,signal
p=subprocess.Popen(sys.argv[2:],start_new_session=True)
try: rc=p.wait(timeout=float(sys.argv[1]))
except subprocess.TimeoutExpired:
 os.killpg(p.pid,signal.SIGKILL);p.wait();rc=124
sys.exit(rc if rc>=0 else 128-rc)
