"""Sample module for gate testing."""

import logging
from typing import Optional

logger = logging.getLogger(__name__)


def greet(name: Optional[str] = None) -> str:
    """Return a greeting with explainable decision logging."""
    if not name:
        logger.info("No name provided; using default for fairness")
        name = "world"
    return f"Hello, {name}!"
