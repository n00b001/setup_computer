"""Entry point for `python -m llm_bench`."""

from __future__ import annotations

from .cli import main

if __name__ == "__main__":
    import sys

    sys.exit(main())
