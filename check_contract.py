#!/usr/bin/env python3
"""Assert handler.py's inlined prompt contract, without importing it.

Importing handler.py starts llama-server, which needs the GPU and the 10 GB
weight, so the build reads the three constants out of the source instead.

    python3 check_contract.py handler.py
"""

import ast
import hashlib
import sys

EXPECTED = "cc51d66b4c593fbe"


def constants(path):
    tree = ast.parse(open(path, encoding="utf-8").read(), path)
    found = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            target = node.targets[0]
            if isinstance(target, ast.Name) and target.id in (
                "INSTR", "SEP", "EXPECTED_HASH"
            ):
                found[target.id] = ast.literal_eval(node.value)
    return found


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "handler.py"
    c = constants(path)
    missing = {"INSTR", "SEP", "EXPECTED_HASH"} - set(c)
    if missing:
        sys.exit("%s: missing top-level constants %s" % (path, sorted(missing)))
    if c["EXPECTED_HASH"] != EXPECTED:
        sys.exit("%s: EXPECTED_HASH is %s, want %s"
                 % (path, c["EXPECTED_HASH"], EXPECTED))
    got = hashlib.sha256((c["INSTR"] + "\n\n" + "X" + c["SEP"]).encode()).hexdigest()[:16]
    print("prompt_sha16 %s" % got)
    if got != EXPECTED:
        sys.exit("%s: prompt contract drift (got %s, want %s)"
                 % (path, got, EXPECTED))
    print("prompt contract OK")


if __name__ == "__main__":
    main()
