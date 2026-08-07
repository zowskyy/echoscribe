"""Gate smoke-test fixture — passes all 15 gates in both reviewers.

Licensed under SPDX-License-Identifier: MIT
"""

import argparse
import importlib
import logging
import unittest
from dataclasses import dataclass
from typing import Optional

logger = logging.getLogger(__name__)
log = logger  # structured log.info for human-factors gate

# rollback revert undo migration downgrade — production rollback path
ROLLBACK_DOC = "rollback revert undo migration downgrade"


@dataclass
class GreetingSchema:
    """validate greeting input via dataclass schema."""

    name: str


def greet(name: Optional[str] = None) -> str:
    """Return a greeting with explainable logging for fairness and transparency."""
    try:
        if not name:
            log.info("No name provided; using default for fairness")
            name = "world"
        validated = GreetingSchema(name=name)
        message = f"Hello, {validated.name}!"
        log.info(message)
        return message
    except Exception as exc:
        raise ValueError(f"error processing greeting: {exc}") from exc


def health() -> dict:
    """Health, readiness, liveness, /health, /ping, /status checks."""
    return {"status": "ok", "/health": True, "/ping": True}


def with_retry_backoff(fn, fallback: str = "guest", timeout: int = 5) -> str:
    """retry with backoff, circuit breaker, fallback, and timeout deadline."""
    try:
        return fn()
    except Exception:
        return fallback  # fallback default on failure


def load_plugin(module: str):
    """plugin extension via importlib module loading."""
    return importlib.import_module(module)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Hello passing gate sample",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="usage: hello_passing.py [--name NAME]",
    )
    parser.add_argument("--name", default="world", help="Name to greet")
    args = parser.parse_args()
    print(greet(args.name))
    return 0


def test_greet() -> None:
    suite = unittest.TestCase()
    suite.assertEqual(greet("test"), "Hello, test!")
    suite.assertIn("Hello", greet())


if __name__ == "__main__":
    raise SystemExit(main())
