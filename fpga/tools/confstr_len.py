#!/usr/bin/env python3
"""Check that NDS.sv declares CONF_STR wide enough for its own literal.

hps_io indexes CONF_STR by byte, so the vector width must be exactly the
string length times 8, with `BUILD_DATE expanded to its 6 characters
(sys/build_id.tcl writes "yymmdd").

Both halves of that rule used to be wrong here: the macro was replaced in
the source text and then matched as a *quoted* string, so its 6 characters
were dropped, and a comment mentioning the macro was read as code. Counting
the macro explicitly (and stripping comments first) is what Quartus agrees
with -- see the 10230 warning it raised when this check said "fine".
Run after editing the menu: `python tools/confstr_len.py`.
"""
import os
import re
import sys

BUILD_DATE_CHARS = 6          # `BUILD_DATE is "yymmdd"

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, "..", "NDS.sv"), encoding="utf-8").read()
start = src.index("localparam [")
end = src.index("};", start)
block = src[start:end]

m = re.search(r"localparam \[(\d+):0\] CONF_STR", block)
declared = int(m.group(1)) + 1

body = block[block.index("{") + 1:]

# drop // comments, but never inside a string literal
code, in_str = [], False
i = 0
while i < len(body):
    c = body[i]
    if in_str:
        code.append(c)
        if c == '"':
            in_str = False
        i += 1
    elif c == '"':
        code.append(c)
        in_str = True
        i += 1
    elif body.startswith("//", i):
        while i < len(body) and body[i] != "\n":
            i += 1
    else:
        code.append(c)
        i += 1
code = "".join(code)

strings = re.findall(r'"([^"]*)"', code)
actual = (sum(len(s) for s in strings)
          + BUILD_DATE_CHARS * code.count("`BUILD_DATE")) * 8

print(f"declared {declared} bits ({declared // 8} bytes)")
print(f"literal  {actual} bits ({actual // 8} bytes)")

if actual > declared:
    sys.exit(f"CONF_STR overflows by {(actual - declared) // 8} bytes")
if actual < declared:
    print(f"note: {(declared - actual) // 8} bytes of slack")
