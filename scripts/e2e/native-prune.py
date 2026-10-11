#!/usr/bin/env python3
"""List retained native E2E state of dead runs; remove it only with --apply."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Sequence


# A dry run must not create bytecode caches in the checkout either.
sys.dont_write_bytecode = True
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import native_retention


_UNITS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}


def _duration(text: str) -> int:
    match = re.fullmatch(r"([0-9]+)([smhdw]?)", text)
    if match is None:
        raise argparse.ArgumentTypeError("use seconds or a number with s, m, h, d or w, e.g. 36h or 14d")
    return int(match.group(1)) * _UNITS[match.group(2)]


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="List retained native E2E resources of dead runs in this checkout; "
                    "the default is a dry run and --apply removes them by exact ID"
    )
    parser.add_argument("--run", dest="runs", action="append", default=[], metavar="ID",
                        help="select a native-suite run ID; repeat for more runs")
    parser.add_argument("--older-than", type=_duration, metavar="DURATION",
                        help="select runs whose folder changed at least this long ago, e.g. 36h or 14d")
    parser.add_argument("--keep-last", type=int, default=0, metavar="N",
                        help="never select the N most recently active runs")
    parser.add_argument("--assume-dead-after", type=int, metavar="SECONDS",
                        help="policy, not proof: treat runs without a run-owner lock or summary.json "
                             f"as dead after this idle time (at least {native_retention.MIN_ASSUMED_DEAD_SECONDS})")
    parser.add_argument("--builds", action="store_true",
                        help="also strip build intermediates of dead runs; case evidence and logs stay")
    parser.add_argument("--folders", action="store_true",
                        help="also remove whole dead run folders once nothing maps to them "
                             "(requires --run or --older-than)")
    parser.add_argument("--apply", action="store_true", help="act instead of listing")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None, *, checkout: Path = REPO_ROOT, **dependencies) -> int:
    args = parse_args(argv)
    try:
        return native_retention.prune(checkout, runs=tuple(args.runs), older_than=args.older_than,
            keep_last=args.keep_last, assume_dead_after=args.assume_dead_after, builds=args.builds,
            folders=args.folders, apply=args.apply, **dependencies)
    except (native_retention.RetentionError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
