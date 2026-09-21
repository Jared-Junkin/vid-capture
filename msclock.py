"""Millisecond wall clock for filming.

Reads the system clock -- the same one time.is measures -- so the offset
time.is reports applies directly to whatever you record.
"""

import sys
import time

try:
    while True:
        t = time.time()
        ms = int((t % 1) * 1000)
        local = time.strftime("%H:%M:%S", time.localtime(t)) + ":%03d" % ms
        utc = time.strftime("%H:%M:%S", time.gmtime(t)) + ":%03d" % ms
        sys.stdout.write("\r  %s LOCAL    %s UTC  " % (local, utc))
        sys.stdout.flush()
        time.sleep(0.005)
except KeyboardInterrupt:
    sys.stdout.write("\n")
