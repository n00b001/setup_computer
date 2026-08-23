#!/usr/bin/env python3
"""llm-bench CLI: serving benchmark + intelligence evaluation."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

# Silence noisy third-party loggers BEFORE any asyncio event loop creation
# Must be done BEFORE importing asyncio
for noisy in (
    "asyncio",
    "lm_eval",
    "httpcore",
    "httpx",
    "urllib3",
    "requests",
    "openai",
):
    logging.getLogger(noisy).setLevel(logging.WARNING)


from rich.console import Console
from rich.logging import RichHandler

from . import serving
from .config import Config, resolve
from .report import print_serving, write_json


def setup_logging() -> logging.Logger:
    """Configure rich logging to console and file (ISO date filename in ./logs)."""
    log_dir = Path("logs")
    log_dir.mkdir(exist_ok=True)
    log_file = (
        log_dir
        / f"{datetime.now().isoformat(timespec='seconds').replace(':', '-')}.log"
    )

    console_handler = RichHandler(
        rich_tracebacks=True,
        markup=True,
        console=Console(stderr=True),
        level=logging.INFO,  # Console: INFO and above only
    )
    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setLevel(logging.DEBUG)  # File: DEBUG and above

    logging.basicConfig(
        level=logging.DEBUG,  # Root logger at DEBUG, handlers filter
        format="%(message)s",
        datefmt="[%X]",
        handlers=[console_handler, file_handler],
    )
    log = logging.getLogger("llm_bench")
    log.setLevel(logging.DEBUG)
    return log


log = setup_logging()


class HelpWithConfigParser(argparse.ArgumentParser):
    """ArgumentParser that prints resolved config after --help."""

    def __init__(self, *args, **kwargs):
        # Disable automatic --help so we can handle it ourselves
        kwargs["add_help"] = False
        super().__init__(*args, **kwargs)

    def print_help(self, file=None):  # type: ignore[override]
        # Manually parse sys.argv for CLI overrides (bypass argparse --help exit)
        cli_dict = {}
        import sys

        argv = sys.argv[1:]
        i = 0
        while i < len(argv):
            arg = argv[i]
            if arg.startswith("--"):
                key = arg[2:].replace("-", "_")
                if i + 1 < len(argv) and not argv[i + 1].startswith("-"):
                    cli_dict[key] = argv[i + 1]
                    i += 2
                else:
                    # flag without value (bool)
                    cli_dict[key] = True
                    i += 1
            elif arg.startswith("-") and len(arg) == 2:
                # short options not used currently, skip
                i += 1
            else:
                # positional arg (command)
                cli_dict["command"] = arg
                i += 1

        super().print_help(file)
        try:
            cfg, sources = resolve(cli_dict, env=os.environ, cwd=Path.cwd())
            print(
                "\nCurrent configuration (defaults < config file < env < CLI):",
                file=file,
            )
            for f in Config.__dataclass_fields__.values():  # type: ignore[attr-defined]
                src = sources.get(f.name, "?")
                val = mask(f.name, getattr(cfg, f.name))
                print(f"  {f.name} = {val}  [{src}]", file=file)
        except Exception as e:
            print(f"(could not show config: {e})", file=file)


def mask(key: str, value: Any) -> str:
    if "key" in key.lower() and value:
        return "***"
    return str(value)


def build_parser() -> HelpWithConfigParser:
    p = HelpWithConfigParser(
        prog="llm-bench",
        description="Automated LLM benchmark: throughput (single/multi user), TTFT, and intelligence",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  llm-bench --base-url http://localhost:8000/v1 --model my-model serve
  LLM_BENCH_BASE_URL=http://localhost:8000/v1 LLM_BENCH_MODEL=my-model llm-bench serve
  llm-bench --config llm-bench.toml all
  llm-bench --base-url http://localhost:8000/v1 --model my-model generate-dataset --num-questions 20 --output tasks/my_dataset.jsonl
        """,
    )
    # global
    p.add_argument(
        "--config", dest="config_file", default=None, help="Path to TOML config file"
    )
    p.add_argument(
        "--base-url",
        dest="base_url",
        default=None,
        help="OpenAI-compatible API base URL",
    )
    p.add_argument("--model", default=None, help="Model name")
    p.add_argument("--api-key", dest="api_key", default=None, help="API key (or EMPTY)")
    # serve
    p.add_argument(
        "--users", type=int, default=None, help="Max concurrency (sweep 1..users)"
    )
    p.add_argument(
        "--requests",
        type=int,
        default=None,
        help="Requests per concurrency level (default: 5)",
    )
    p.add_argument("--prompt", default=None, help="Prompt text")
    p.add_argument(
        "--max-tokens",
        dest="max_tokens",
        type=int,
        default=None,
        help="Max completion tokens",
    )
    p.add_argument(
        "--temperature",
        type=float,
        default=None,
        help="Sampling temperature (forced to 0.0 for benchmarks)",
    )
    p.add_argument("--warmup", type=int, default=None, help="Warmup requests per level")
    p.add_argument("--output", default=None, help="Output JSON file (default: auto)")
    p.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed for reproducibility (default: 42)",
    )
    p.add_argument(
        "--concurrency-levels",
        dest="concurrency_levels",
        default=None,
        help="Comma-separated list of concurrency levels to test (e.g., '1,2,4,8'). Overrides --users.",
    )
    p.add_argument(
        "--request-timeout",
        dest="request_timeout",
        type=int,
        default=None,
        help="Request timeout in seconds (default: 600)",
    )
    # eval
    p.add_argument(
        "--eval-model-type",
        dest="eval_model_type",
        default=None,
        help="lm-eval model type",
    )
    p.add_argument("--dataset", default=None, help="Dataset JSONL path")
    p.add_argument("--task", default=None, help="Task name (default: custom_intel)")
    p.add_argument("--limit", type=int, default=None, help="Limit samples (0 = all)")
    p.add_argument(
        "--num-fewshot",
        dest="num_fewshot",
        type=int,
        default=None,
        help="Few-shot examples",
    )
    p.add_argument(
        "--dataset-type",
        dest="dataset_type",
        default=None,
        help="Dataset type: multiple_choice or true_false (default: multiple_choice)",
    )
    # dataset generation
    p.add_argument(
        "--num-questions",
        dest="num_questions",
        type=int,
        default=None,
        help="Number of questions to generate (for generate-dataset command)",
    )
    p.add_argument(
        "--categories",
        dest="categories",
        default=None,
        help="Comma-separated categories for dataset generation (e.g., 'math,science,logic')",
    )
    p.add_argument(
        "--interactive",
        dest="interactive",
        action="store_true",
        default=None,
        help="Interactive mode for dataset generation (human review loop)",
    )
    # meta
    p.add_argument(
        "command",
        nargs="?",
        choices=["serve", "eval", "all", "generate-dataset"],
        default="all",
        help="Subcommand",
    )
    return p


def build_cli_dict(args: argparse.Namespace) -> dict[str, Any]:
    # only include non-None values; argparse default=None for all
    d = {k: v for k, v in vars(args).items() if v is not None}
    # Parse concurrency_levels if provided as string
    if "concurrency_levels" in d and isinstance(d["concurrency_levels"], str):
        try:
            d["concurrency_levels"] = [
                int(x.strip()) for x in d["concurrency_levels"].split(",") if x.strip()
            ]
        except (ValueError, TypeError):
            pass  # Let config.resolve handle the error
    return d


async def run_serve(cfg: Config) -> dict[str, Any]:
    api_url = cfg.base_url.rstrip("/") + "/chat/completions"
    prompt_len = len(
        cfg.prompt
    )  # rough proxy; server usage.prompt_tokens used for metrics

    levels = cfg.concurrency_levels
    results = {
        "config": {
            "base_url": cfg.base_url,
            "model": cfg.model,
            "prompt_len": prompt_len,
            "max_tokens": cfg.max_tokens,
            "temperature": cfg.temperature,
            "warmup": cfg.warmup,
            "seed": cfg.seed,
            "request_timeout": cfg.request_timeout,
            "requests_per_level": cfg.requests,
        },
        "levels": [],
    }
    for level in levels:
        log.info(
            f"[bold cyan]--- Concurrency {level} ({levels.index(level) + 1}/{len(levels)}) ---[/]"
        )
        outputs, dur = await serving.benchmark(
            api_url=api_url,
            model=cfg.model,
            prompt=cfg.prompt,
            prompt_len=prompt_len,
            output_len=cfg.max_tokens,
            num_requests=cfg.requests,
            max_concurrency=level,
            api_key=cfg.api_key,
            extra_request_body={"temperature": cfg.temperature}
            if cfg.temperature
            else None,
            warmup_requests=cfg.warmup,
            disable_tqdm=True,  # rich progress handles it
            seed=cfg.seed,
            request_timeout=cfg.request_timeout,
        )
        metrics = serving.calculate_metrics(outputs, dur)
        results["levels"].append({"concurrency": level, "metrics": metrics})

        # Log detailed per-request metrics at DEBUG level
        for i, o in enumerate(outputs):
            if o.success:
                log.debug(
                    "  Request %d/%d: ttft=%.2fms, itl_count=%d, latency=%.2fms, tokens=%d",
                    i + 1,
                    cfg.requests,
                    o.ttft * 1000,
                    len(o.itl),
                    o.latency * 1000,
                    o.output_len,
                )

        # Log summary at INFO level
        m = metrics
        log.info(
            "  Completed: %d/%d | TTFT: %.1f/%.1f/%.1fms (mean/med/p99) | "
            "E2E: %.2f/%.2fs (mean/p99) | Throughput: %.2f req/s, %.1f out tok/s",
            m["completed"],
            cfg.requests,
            m["mean_ttft_ms"],
            m["median_ttft_ms"],
            m["p99_ttft_ms"],
            m["mean_e2e_ms"] / 1000,
            m["p99_e2e_ms"] / 1000,
            m["request_throughput"],
            m["output_throughput"],
        )
    return results


def run_eval(cfg: Config) -> dict[str, Any]:
    # Deferred import so `uv run llm-bench serve` doesn't load lm_eval
    from lm_eval import simple_evaluate

    os.environ["OPENAI_API_KEY"] = cfg.api_key or "EMPTY"
    base = cfg.base_url.rstrip("/")
    if not base.endswith("/chat/completions"):
        base += "/chat/completions"

    task_path = Path(cfg.dataset).with_suffix(".yaml")
    if not task_path.exists():
        task_path = Path("tasks") / (cfg.task + ".yaml")

    model_args = f'model={cfg.model},base_url={base},apply_chat_template=True,eos_string="\\n\\n"'
    log.info(f"[bold cyan]--- Intelligence evaluation: {cfg.task} ---[/]")
    log.info(f"  model={cfg.model}, base_url={base}, dataset={cfg.dataset}")
    log.info(
        f"  dataset_type={cfg.dataset_type}, limit={cfg.limit}, fewshot={cfg.num_fewshot}"
    )

    eval_results = simple_evaluate(
        model=cfg.eval_model_type,
        model_args=model_args,
        tasks=[str(task_path)],
        limit=cfg.limit if cfg.limit > 0 else None,
        num_fewshot=cfg.num_fewshot,
        log_samples=False,
        apply_chat_template=True,
    )
    return {"task": cfg.task, "results": eval_results.get("results", {})}


async def generate_dataset(cfg: Config) -> int:
    """Generate a new dataset using the LLM."""
    from .dataset_gen import generate_dataset as gen_dataset
    from .dataset_gen import generate_dataset_interactive

    output_path = cfg.output or f"tasks/generated_{datetime.now():%Y%m%d-%H%M%S}.jsonl"

    if cfg.interactive:
        # Interactive mode - human-in-the-loop review
        await generate_dataset_interactive(
            base_url=cfg.base_url,
            model=cfg.model,
            api_key=cfg.api_key,
            output_path=output_path,
            seed=cfg.seed,
        )
    else:
        # Non-interactive mode (backward compatible)
        categories = (
            cfg.categories.split(",")
            if cfg.categories
            else ["math", "science", "logic", "geography", "literature"]
        )

        log.info(
            f"[bold cyan]--- Dataset generation: {cfg.num_questions} questions ---[/]"
        )
        log.info(f"  model={cfg.model}, base_url={cfg.base_url}")
        log.info(
            f"  categories={categories}, type={cfg.dataset_type}, output={output_path}"
        )

        await gen_dataset(
            base_url=cfg.base_url,
            model=cfg.model,
            api_key=cfg.api_key,
            num_questions=cfg.num_questions,
            categories=categories,
            dataset_type=cfg.dataset_type,
            output_path=output_path,
            seed=cfg.seed,
        )

        log.info(f"[green]Dataset generated at {output_path}[/]")
        log.info(
            "[yellow]Don't forget to create a YAML task file referencing this dataset![/]"
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    # Handle --help/-h before parsing so we can show config with CLI overrides
    if argv is None:
        import sys

        argv = sys.argv[1:]
    if "--help" in argv or "-h" in argv:
        parser = build_parser()
        parser.print_help()
        return 0

    parser = build_parser()
    args = parser.parse_args(argv)
    cli = build_cli_dict(args)

    try:
        cfg, sources = resolve(cli, env=os.environ, cwd=Path.cwd())
    except Exception as e:
        log.error(f"Config error: {e}")
        return 1

    if not cfg.model:
        log.error("Error: --model is required (or set LLM_BENCH_MODEL / config file)")
        return 1

    if args.command == "generate-dataset":
        if not cfg.num_questions and not cfg.interactive:
            log.error(
                "Error: --num-questions is required for generate-dataset (unless --interactive)"
            )
            return 1
        return asyncio.run(generate_dataset(cfg))

    if args.command in ("serve", "all"):
        results = asyncio.run(run_serve(cfg))
        print_serving(results)
        write_json(results, cfg.output)
        log.info(f"Results written to [bold green]{cfg.output}[/]")

        # Print detailed summary
        log.info("[bold cyan]=== Detailed Serving Summary ===[/]")
        for lvl in results["levels"]:
            c = lvl["concurrency"]
            m = lvl["metrics"]
            log.info(
                "  Concurrency %d: %d/%d ok | TTFT ms: %.1f/%.1f/%.1f (mean/med/p99) | "
                "ITL ms: %s | TPOT ms: %s | E2E s: %.2f/%.2f | "
                "Throughput: %.2f req/s, %.1f out tok/s",
                c,
                m["completed"],
                cfg.requests,
                m["mean_ttft_ms"],
                m["median_ttft_ms"],
                m["p99_ttft_ms"],
                f"{m['mean_itl_ms']:.1f}/{m['p99_itl_ms']:.1f}"
                if m["itl_available"]
                else "N/A",
                f"{m['mean_tpot_ms']:.1f}/{m['p99_tpot_ms']:.1f}"
                if m["tpot_available"]
                else "N/A",
                m["mean_e2e_ms"] / 1000,
                m["p99_e2e_ms"] / 1000,
                m["request_throughput"],
                m["output_throughput"],
            )

    if args.command in ("eval", "all"):
        try:
            eval_res = run_eval(cfg)
            log.info("[bold cyan]=== Intelligence results ===[/]")
            log.info(json.dumps(eval_res, indent=2))
        except Exception as e:
            log.error(f"Eval failed: {e}")
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
