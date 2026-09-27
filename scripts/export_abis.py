#!/usr/bin/env python3
"""Export or check the committed deployment ABIs using only Foundry and Python's standard library."""

import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if a committed ABI differs from the compiler output")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    subprocess.run(["forge", "build"], cwd=root, check=True)
    for contract in ("Blockcap", "BlockOutflowCapHook"):
        artifact = json.loads((root / "out" / f"{contract}.sol" / f"{contract}.json").read_text())
        expected = json.dumps(artifact["abi"], indent=2) + "\n"
        destination = root / "docs" / "abi" / f"{contract}.json"
        if args.check:
            if not destination.exists() or destination.read_text() != expected:
                raise SystemExit(f"Stale or missing ABI: {destination.relative_to(root)}")
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(expected)
        print(f"{'Checked' if args.check else 'Exported'} {destination.relative_to(root)}")


if __name__ == "__main__":
    main()
