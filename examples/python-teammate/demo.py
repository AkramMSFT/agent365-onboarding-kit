"""Dependency-free tool demonstration; deliberately does not perform AI inference."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone


def count_words(text: str) -> int:
    return len(text.split())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("text", nargs="?", default="Hello from Agent 365")
    args = parser.parse_args()
    print(json.dumps({
        "mode": "mock",
        "aiInference": False,
        "input": args.text,
        "words": count_words(args.text),
        "utc": datetime.now(timezone.utc).isoformat(),
        "note": "Not an AI response or an Agent 365 integration test. See README.md for the authenticated host.",
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
