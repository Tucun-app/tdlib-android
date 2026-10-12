import ctypes
import json
import sys

lib = ctypes.CDLL(sys.argv[1])
lib.td_execute.restype = ctypes.c_char_p
lib.td_execute.argtypes = [ctypes.c_char_p]
for opt in ("version", "commit_hash"):
    print(opt, lib.td_execute(json.dumps({"@type": "getOption", "name": opt}).encode()).decode())
