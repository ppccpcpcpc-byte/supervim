import sys
from py.editor import run

filename = sys.argv[1] if len(sys.argv) > 1 else None
run(filename)
