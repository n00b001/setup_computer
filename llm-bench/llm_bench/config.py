"""Configuration: CLI args > env vars > TOML file > defaults."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass, fields
from pathlib import Path
from typing import Any

import tomllib

DEFAULT_PROMPT = (
    "Write a 200-word essay about the history of the internet. "
    "Cover ARPANET, TCP/IP, and the World Wide Web."
)


ENV_PREFIX = "LLM_BENCH_"

# Type map for _cast (from __future__.annotations makes annotations strings)
_TYPE_MAP = {
    "base_url": str,
    "model": str,
    "api_key": str,
    "users": int,
    "requests": int,
    "prompt": str,
    "max_tokens": int,
    "temperature": float,
    "warmup": int,
    "output": str,
    "eval_model_type": str,
    "dataset": str,
    "task": str,
    "limit": int,
    "num_fewshot": int,
    "config_file": str,
    "seed": int,
    "concurrency_levels": str,  # comma-separated list, parsed specially
    "request_timeout": int,
    "dataset_type": str,
    "num_questions": int,
    "categories": str,
    "interactive": bool,
}


@dataclass
class Config:
    # endpoint
    base_url: str = "http://localhost:8000/v1"
    model: str = ""
    api_key: str = ""
    # serve
    users: int = 5
    requests: int = 5  # Changed from 10 to 5
    prompt: str = DEFAULT_PROMPT
    max_tokens: int = 256
    temperature: float = 0.0
    warmup: int = 1
    output: str = ""
    seed: int = 42
    concurrency_levels: list[int] | str = ""  # comma-separated, e.g. "1,2,4,8"
    request_timeout: int = 600
    # eval (the benchmark uses the standard OpenAI Chat Completions API;
    # non-conforming APIs are out of scope)
    eval_model_type: str = "openai-chat-completions"
    dataset: str = "tasks/custom_intel.jsonl"
    task: str = "custom_intel"
    limit: int = 0
    num_fewshot: int = 0
    dataset_type: str = "multiple_choice"  # multiple_choice, true_false
    # dataset generation
    num_questions: int = 0
    categories: str = ""
    interactive: bool = False
    # meta
    config_file: str = ""


def _cast(field_name: str, value: str) -> Any:
    target_type = _TYPE_MAP.get(field_name, str)
    if target_type is int:
        try:
            return int(value)
        except (ValueError, TypeError):
            return 0
    if target_type is float:
        try:
            return float(value)
        except (ValueError, TypeError):
            return 0.0
    if target_type is bool:
        return value.lower() in ("1", "true", "yes", "on")
    if field_name == "concurrency_levels":
        # Parse comma-separated list of ints
        try:
            return [int(x.strip()) for x in value.split(",") if x.strip()]
        except (ValueError, TypeError):
            return []
    return value


def _load_file(path: str) -> dict:
    raw = Path(path).read_bytes()
    data = tomllib.loads(raw.decode())
    out: dict[str, Any] = {}
    for section in ("endpoint", "serve", "eval"):
        out.update(data.get(section, {}))
    return out


def resolve(
    cli: dict[str, Any] | None = None,
    env: Mapping[str, str] | None = None,
    cwd: Path | None = None,
) -> tuple[Config, dict[str, str]]:
    """Resolve final config and return (config, sources_map)."""
    cli = cli or {}
    env = env if env is not None else os.environ
    cwd = cwd or Path.cwd()

    defaults = {f.name: f.default for f in fields(Config)}
    file_vals: dict[str, Any] = {}
    env_vals: dict[str, Any] = {}
    sources: dict[str, str] = {}

    # 1) config file
    config_path: str | None = cli.get("config_file") or env.get(f"{ENV_PREFIX}CONFIG")
    if not config_path:
        candidate = cwd / "llm-bench.toml"
        if candidate.exists():
            config_path = str(candidate)
    if config_path and Path(config_path).exists():
        try:
            file_vals = _load_file(config_path)
            sources["config_file"] = config_path
        except Exception as exc:
            raise RuntimeError(f"Failed to read config {config_path}: {exc}") from exc

    # 2) env vars
    for f in fields(Config):
        env_key = f"{ENV_PREFIX}{f.name.upper()}"
        val = env.get(env_key)
        if val is not None:
            env_vals[f.name] = _cast(f.name, val)

    # 3) assemble (defaults < file < env < cli)
    cfg = Config()
    for f in fields(Config):
        val: Any = defaults[f.name]
        src = "default"
        if f.name in file_vals:
            val = file_vals[f.name]
            src = f"file ({sources.get('config_file', '?')})"
        if f.name in env_vals:
            val = env_vals[f.name]
            src = f"env ({ENV_PREFIX}{f.name.upper()})"
        if f.name in cli and cli[f.name] is not None:
            val = cli[f.name]
            src = "cli"
        setattr(cfg, f.name, val)
        sources[f.name] = src

    # output defaults to timestamped file when not explicitly set anywhere
    if cfg.output == "" and "output" not in cli and f"{ENV_PREFIX}OUTPUT" not in env:
        from datetime import datetime

        cfg.output = f"results-{datetime.now():%Y%m%d-%H%M%S}.json"

    # If concurrency_levels not set, use 1..users
    if not cfg.concurrency_levels:
        cfg.concurrency_levels = list(range(1, cfg.users + 1))

    return cfg, sources


def mask(key: str, value: Any) -> str:
    if "key" in key.lower() and value:
        return "***"
    return str(value)
