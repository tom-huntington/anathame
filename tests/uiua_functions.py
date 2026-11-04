"""Deterministic generated differential tests against the installed Uiua CLI."""
import argparse
import random
from helpers import actual, check, oracle

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=1729)
    parser.add_argument("--cases", type=int, default=30)
    args = parser.parse_args()
    if args.cases < 1:
        parser.error("--cases must be positive")
    rng = random.Random(args.seed)
    failures = 0
    for i in range(args.cases):
        for name in ("mul", "couple"):
            input = f"{rng.randint(-48, 48) / 4}; {rng.randint(-48, 48) / 4}"
            expected = oracle(name, input)
            if expected.startswith("error:"):
                raise RuntimeError(f"Uiua oracle failed: {expected}")
            failures += not check(f"Uiua {name}, seed={args.seed}, case={i}",
                                  input, name, expected, actual(name, input))
    raise SystemExit(bool(failures))

if __name__ == "__main__":
    main()
