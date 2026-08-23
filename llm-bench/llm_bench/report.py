"""Human-readable serving benchmark report."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from rich.console import Console
from rich.table import Table


def fmt_ms(x: float) -> str:
    return f"{x:.1f}"


def fmt_itl(x: float, available: bool) -> str:
    if not available:
        return "N/A"
    return f"{x:.1f}"

def fmt_tpot(x: float, available: bool) -> str:
    if not available:
        return "N/A"
    return f"{x:.1f}"

def fmt_itl_pair(m: dict, available: bool) -> str:
    if not available:
        return "N/A"
    return f"{fmt_ms(m['mean_itl_ms'])}/{fmt_ms(m['p99_itl_ms'])}"

def fmt_tpot_pair(m: dict, available: bool) -> str:
    if not available:
        return "N/A"
    return f"{fmt_ms(m['mean_tpot_ms'])}/{fmt_ms(m['p99_tpot_ms'])}"


def fmt_tok_s(x: float) -> str:
    if x >= 1000:
        return f"{x / 1000:.2f} K"
    return f"{x:.1f}"


def print_serving(results: dict[str, Any]) -> None:
    cfg = results.get("config", {})
    console = Console()

    console.print(
        f"\n[bold cyan]=== llm-bench serving: model={cfg.get('model', '?')} base_url={cfg.get('base_url', '?')} ==="
    )

    table = Table(show_header=True, header_style="bold", show_lines=False)
    table.add_column("Concurrency", justify="right", style="dim")
    table.add_column("OK/Fail", justify="right")
    table.add_column("TTFT ms\n(mean/med/p99)", justify="right")
    table.add_column("ITL ms\n(mean/p99)", justify="right")
    table.add_column("E2E s\n(mean/p99)", justify="right")
    table.add_column("req/s", justify="right")
    table.add_column("out tok/s", justify="right")
    table.add_column("total tok/s", justify="right")

    for lvl in results.get("levels", []):
        c = lvl["concurrency"]
        m = lvl["metrics"]
        ok = m["completed"]
        fail = m["failed"]
        itl_avail = m.get("itl_available", False)
        tpot_avail = m.get("tpot_available", False)
        ttft = f"{fmt_ms(m['mean_ttft_ms'])}/{fmt_ms(m['median_ttft_ms'])}/{fmt_ms(m['p99_ttft_ms'])}"
        itl = fmt_itl_pair(m, itl_avail)
        tpot = fmt_tpot_pair(m, tpot_avail)
        e2e = f"{m['mean_e2e_ms'] / 1000:.2f}/{m['p99_e2e_ms'] / 1000:.2f}"
        rps = f"{m['request_throughput']:.2f}"
        otps = fmt_tok_s(m["output_throughput"])
        ttps = fmt_tok_s(m["total_throughput"])
        table.add_row(
            str(c),
            f"{ok}/{fail}",
            ttft,
            itl,
            tpot,
            e2e,
            rps,
            otps,
            ttps,
        )

    console.print(table)
    console.print()


def write_json(results: dict[str, Any], path: str) -> None:
    Path(path).write_text(json.dumps(results, indent=2))
    console = Console()
    console.print(f"[green]Wrote results to {path}[/]")
