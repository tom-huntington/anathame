"""Run every case in conformance.md, including expected errors."""
from helpers import ROOT, actual, check, fixtures

def main():
    failures = 0
    for case in fixtures(ROOT / "conformance.md"):
        failures += not check(case["description"], case["input"], case["code"],
                              case["output"], actual(case["code"], case["input"]))
    raise SystemExit(bool(failures))

if __name__ == "__main__":
    main()
