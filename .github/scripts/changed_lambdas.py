"""Compute the matrix of lambdas to validate/build and write it to GITHUB_OUTPUT.

A lambda is any lambdas/<service>/<lambda>/ directory that contains a Dockerfile.
Only lambdas with changes are included, unless something shared changed (or there is no
base to compare against), in which case all of them are included.
"""

import argparse
import json
import os
import subprocess
from pathlib import Path

LAMBDAS_DIR = Path("lambdas")
SHARED_PATHS = (
    ".github/workflows/ci.yml",
    ".github/workflows/lambda-ci.yml",
    ".github/scripts/",
    "ruff.toml",
)
NULL_SHA = "0" * 40


def discover() -> list[Path]:
    return sorted(p.parent for p in LAMBDAS_DIR.glob("*/*/Dockerfile"))


def changed_files(base: str) -> list[str] | None:
    """Files changed since base, or None if that cannot be determined."""
    if not base or base == NULL_SHA:
        return None
    result = subprocess.run(
        ["git", "diff", "--name-only", base, "HEAD"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return result.stdout.split()


def select(lambdas: list[Path], files: list[str] | None) -> list[Path]:
    if files is None or any(f.startswith(SHARED_PATHS) for f in files):
        return lambdas
    return [lam for lam in lambdas if any(f.startswith(f"{lam.as_posix()}/") for f in files)]


def to_entry(lam: Path, prefix: str) -> dict[str, str]:
    service, name = lam.parts[-2:]
    return {
        "name": f"{service}/{name}",
        "path": lam.as_posix(),
        "ecr_repository": f"{prefix}/{service}/{name}".strip("/"),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="")
    parser.add_argument("--ecr-prefix", default="")
    args = parser.parse_args()

    selected = select(discover(), changed_files(args.base))
    matrix = json.dumps([to_entry(lam, args.ecr_prefix) for lam in selected])
    print(matrix)

    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as f:
            f.write(f"matrix={matrix}\n")


if __name__ == "__main__":
    main()
