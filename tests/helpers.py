"""Shared process, fixture, numeric comparison, and diagnostic helpers."""
from pathlib import Path
import math
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "zig-out" / "bin" / ("anathame.exe" if os.name == "nt" else "anathame")

def run(argv):
    result = subprocess.run([str(x) for x in argv], capture_output=True, text=True,
                            encoding="utf-8", timeout=15, cwd=ROOT)
    if result.returncode:
        return "error: " + result.stderr.strip().splitlines()[0]
    return result.stdout.strip()

def actual(code, input):
    return run([EXE, code, *[part.strip() for part in input.split(";")]])

def oracle(code, input):
    # &p prints nested bracket notation rather than terminal box drawings.
    # Negative literals in Uiua use the overbar.
    source = f"&p {code} {input.replace(";", " ")}"
    source = re.sub(r"-(?=\d)", "¯", source)
    return run(["uiua", "eval", source])

def canonical(text):
    if text.startswith("error: "):
        return text
    tokens = re.findall(r"\[|\]|[^\s\[\]]+", text.replace("¯", "-"))
    return [t if t in "[]" else float(t) for t in tokens]

def check(description, input, code, expected, output):
    print(f"\n{description}\ninput: {input}\ncode: {code}\nexpected output: {expected}\nactual output: {output}", flush=True)
    left, right = canonical(expected), canonical(output)
    passed = type(left) is type(right) and len(left) == len(right)
    if passed:
        passed = all(math.isclose(a, b, rel_tol=1e-12, abs_tol=1e-12)
                     if isinstance(a, float) and isinstance(b, float) else a == b
                     for a, b in zip(left, right))
    print("PASS" if passed else "FAIL", flush=True)
    return passed

def fixtures(path):
    case = {}
    for line in path.read_text(encoding="utf-8").splitlines() + ["---"]:
        if line.strip() == "---":
            if case:
                required = {"description", "input", "code", "output"}
                if set(case) != required:
                    raise ValueError(f"Invalid fixture fields: {case}")
                yield case
                case = {}
        elif line.startswith(("description:", "input:", "code:", "output:")):
            key, value = line.split(":", 1)
            if key in case:
                raise ValueError(f"Duplicate fixture field: {key}")
            case[key] = value.strip()
