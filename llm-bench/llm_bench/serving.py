# SPDX-License-Identifier: Apache-2.0
# Vendored and trimmed from SGLang's `sglang/benchmark/serving.py`
# (https://github.com/sgl-project/sglang), which is itself adapted from
# vLLM's `benchmarks/benchmark_serving.py`
# (https://github.com/vllm-project/vllm).
#
# Kept: OpenAI Chat Completions streaming client, semaphore-based concurrency,
# warmup, and standard metric definitions (TTFT / ITL / TPOT / E2E /
# throughput), so results are directly comparable to vLLM/SGLang benchmarks.
#
# Dropped: all non-OpenAI backends, tokenizer re-tokenization, LoRA,
# multi-turn, profiling, cache flush, image/reasoning model special-casing.
#
# One deliberate deviation from upstream: SSE lines are buffered per-line
# before json.loads (the upstream code assumes one SSE event per TCP chunk,
# which breaks if a server coalesces events).
"""Serving benchmark client targeting the OpenAI Chat Completions API."""

from __future__ import annotations

import asyncio
import json
import logging
import sys
import time
import traceback
from dataclasses import dataclass, field
from typing import Any

import aiohttp
import numpy as np
from rich.progress import (
    BarColumn,
    MofNCompleteColumn,
    Progress,
    SpinnerColumn,
    TaskProgressColumn,
    TextColumn,
    TimeElapsedColumn,
    TimeRemainingColumn,
)

AIOHTTP_TIMEOUT_S = 6 * 60 * 60
AIOHTTP_READ_BUFSIZE = 10 * 1024**2  # 10 MB
_STREAM_PREFIX = "data: "

log = logging.getLogger("llm_bench.serving")


def remove_prefix(text: str, prefix: str) -> str:
    return text[len(prefix) :] if text.startswith(prefix) else text


@dataclass
class RequestFuncInput:
    prompt: str
    api_url: str
    prompt_len: int
    output_len: int
    model: str
    extra_request_body: dict[str, Any] = field(default_factory=dict)
    seed: int | None = None


@dataclass
class RequestFuncOutput:
    generated_text: str = ""
    success: bool = False
    latency: float = 0.0  # E2E
    ttft: float = 0.0
    itl: list[float] = field(default_factory=list)
    prompt_len: int = 0
    output_len: int = 0
    prompt_tokens: int = 0
    start_time: float = 0.0
    error: str = ""
    # Per-request detailed timing
    ttft_ts: float = 0.0
    first_token_ts: float = 0.0
    last_token_ts: float = 0.0


def _auth_headers(api_key: str) -> dict[str, str]:
    if api_key:
        return {"Authorization": f"Bearer {api_key}"}
    return {}


async def _chat_request(
    inp: RequestFuncInput,
    api_key: str = "",
    request_timeout: int = 600,
) -> RequestFuncOutput:
    """OpenAI Chat Completions streaming request (standard SSE)."""
    assert inp.api_url.endswith("/chat/completions"), inp.api_url

    timeout = aiohttp.ClientTimeout(total=request_timeout)
    async with aiohttp.ClientSession(
        timeout=timeout, read_bufsize=AIOHTTP_READ_BUFSIZE
    ) as session:
        payload: dict[str, Any] = {
            "model": inp.model,
            "messages": [{"role": "user", "content": inp.prompt}],
            "max_completion_tokens": inp.output_len,
            "stream": True,
            "temperature": 0.0,  # Always use temperature=0 for deterministic results
        }
        if inp.seed is not None:
            payload["seed"] = inp.seed
        payload.update(inp.extra_request_body)
        # Force temperature=0 and seed regardless of extra_request_body
        payload["temperature"] = 0.0
        if inp.seed is not None:
            payload["seed"] = inp.seed

        out = RequestFuncOutput(prompt_len=inp.prompt_len)
        st = time.perf_counter()
        out.start_time = st
        ttft = 0.0
        most_recent = st
        generated: list[str] = []
        output_len = inp.output_len
        buf = ""
        try:
            async with session.post(
                inp.api_url, json=payload, headers=_auth_headers(api_key)
            ) as response:
                if response.status == 200:
                    async for chunk in response.content:
                        buf += chunk.decode("utf-8", errors="replace")
                        while "\n" in buf:
                            line, buf = buf.split("\n", 1)
                            line = line.strip()
                            if not line:
                                continue
                            if not line.startswith(_STREAM_PREFIX.rstrip()):
                                continue
                            line = remove_prefix(line, _STREAM_PREFIX)
                            if line == "[DONE]":
                                continue
                            data = json.loads(line)
                            usage = data.get("usage") or {}
                            output_len = usage.get("completion_tokens", output_len)
                            out.prompt_tokens = usage.get(
                                "prompt_tokens", out.prompt_tokens
                            )
                            choices = data.get("choices") or []
                            if not choices:
                                continue
                            delta = choices[0].get("delta") or {}
                            content = delta.get("content") or ""
                            now = time.perf_counter()
                            if ttft == 0.0:
                                # First chunk with any delta (role or content) = TTFT
                                ttft = now - st
                                out.ttft = ttft
                                out.ttft_ts = now
                                most_recent = now
                            elif content:
                                # Subsequent content chunks = ITL
                                itl_val = now - most_recent
                                out.itl.append(itl_val)
                                most_recent = now
                            if content:
                                if not out.first_token_ts:
                                    out.first_token_ts = now
                                generated.append(content)
                    out.last_token_ts = most_recent
                    out.generated_text = "".join(generated)
                    out.success = True
                    out.latency = time.perf_counter() - st
                    out.output_len = output_len
                    log.debug(
                        "Request completed: ttft=%.2fms, itl_count=%d, latency=%.2fms, tokens=%d",
                        out.ttft * 1000,
                        len(out.itl),
                        out.latency * 1000,
                        output_len,
                    )
                else:
                    out.error = (response.reason or "") + ": " + (await response.text())
                    out.success = False
                    log.debug("Request failed: %s", out.error)
        except Exception:
            out.success = False
            exc = sys.exc_info()
            out.error = "".join(traceback.format_exception(*exc))
            log.debug("Request exception: %s", out.error)

    return out


async def benchmark(
    api_url: str,
    model: str,
    prompt: str,
    prompt_len: int,
    output_len: int,
    num_requests: int,
    max_concurrency: int | None,
    *,
    api_key: str = "",
    extra_request_body: dict[str, Any] | None = None,
    warmup_requests: int = 1,
    disable_tqdm: bool = False,
    seed: int | None = None,
    request_timeout: int = 600,
) -> tuple[list[RequestFuncOutput], float]:
    """Run `num_requests` OpenAI chat-completions requests.

    Returns (outputs, wall_clock_seconds).
    """
    extra = extra_request_body or {}

    def _inp() -> RequestFuncInput:
        return RequestFuncInput(
            prompt=prompt,
            api_url=api_url,
            prompt_len=prompt_len,
            output_len=output_len,
            model=model,
            extra_request_body=extra,
            seed=seed,
        )

    # Warmup (following vLLM/SGLang practice)
    if warmup_requests > 0:
        warm_tasks = [
            asyncio.create_task(
                _chat_request(_inp(), api_key=api_key, request_timeout=request_timeout)
            )
            for _ in range(warmup_requests)
        ]
        warm_out = await asyncio.gather(*warm_tasks)
        if not any(o.success for o in warm_out):
            raise RuntimeError(
                "Warmup failed – check --base-url / --model / --api-key. "
                f"Error: {warm_out[0].error}"
            )

    sem = asyncio.Semaphore(max_concurrency) if max_concurrency else None

    async def _limited(inp: RequestFuncInput):
        if sem is None:
            return await _chat_request(
                inp, api_key=api_key, request_timeout=request_timeout
            )
        async with sem:
            return await _chat_request(
                inp, api_key=api_key, request_timeout=request_timeout
            )

    tasks = [asyncio.create_task(_limited(_inp())) for _ in range(num_requests)]
    start = time.perf_counter()

    if disable_tqdm:
        outputs = await asyncio.gather(*tasks)
    else:
        # Rich progress bar with iterations/sec and ETA
        with Progress(
            SpinnerColumn(),
            TextColumn("[bold cyan]{task.description}"),
            BarColumn(),
            TaskProgressColumn(),
            MofNCompleteColumn(),
            TextColumn("•"),
            TimeElapsedColumn(),
            TextColumn("•"),
            TimeRemainingColumn(),
            TextColumn("•"),
            TextColumn("[green]{task.fields[rate]:.2f} it/s[/]"),
        ) as progress:
            task = progress.add_task(
                f"conc={max_concurrency or 'inf'}", total=num_requests, rate=0.0
            )
            done = 0
            for coro in asyncio.as_completed(tasks):
                await coro
                done += 1
                elapsed = time.perf_counter() - start
                rate = done / elapsed if elapsed > 0 else 0.0
                progress.update(task, advance=1, rate=rate)
            outputs = [t.result() for t in tasks]

    dur = time.perf_counter() - start
    return list(outputs), dur


def calculate_metrics(
    outputs: list[RequestFuncOutput],
    dur_s: float,
) -> dict[str, Any]:
    """Standard serving metrics (same definitions as vLLM/SGLang)."""
    ttfts: list[float] = []
    itls: list[float] = []
    tpots: list[float] = []
    e2e: list[float] = []
    completed = 0
    total_input = 0
    total_output = 0

    for o in outputs:
        if not o.success:
            continue
        completed += 1
        total_input += o.prompt_tokens
        total_output += o.output_len
        ttfts.append(o.ttft)
        itls.extend(o.itl)
        e2e.append(o.latency)
        if o.output_len > 1:
            tpots.append((o.latency - o.ttft) / (o.output_len - 1))

    # ITL is only meaningful when server streams token-by-token
    itl_available = len(itls) > 0
    tpot_available = len(tpots) > 0

    def p(xs, p):
        return float(np.percentile(xs, p)) if xs else 0.0

    return {
        "completed": completed,
        "failed": len(outputs) - completed,
        "total_input_tokens": total_input,
        "total_output_tokens": total_output,
        "request_throughput": completed / dur_s if dur_s else 0.0,
        "input_throughput": total_input / dur_s if dur_s else 0.0,
        "output_throughput": total_output / dur_s if dur_s else 0.0,
        "total_throughput": (total_input + total_output) / dur_s if dur_s else 0.0,
        "mean_ttft_ms": float(np.mean(ttfts or [0])) * 1000,
        "median_ttft_ms": float(np.median(ttfts or [0])) * 1000,
        "std_ttft_ms": float(np.std(ttfts or [0])) * 1000,
        "p90_ttft_ms": p(ttfts, 90),
        "p95_ttft_ms": p(ttfts, 95),
        "p99_ttft_ms": p(ttfts, 99),
        "mean_itl_ms": float(np.mean(itls or [0])) * 1000 if itl_available else 0.0,
        "median_itl_ms": float(np.median(itls or [0])) * 1000 if itl_available else 0.0,
        "p99_itl_ms": p(itls, 99) if itl_available else 0.0,
        "mean_tpot_ms": float(np.mean(tpots or [0])) * 1000 if tpot_available else 0.0,
        "median_tpot_ms": float(np.median(tpots or [0])) * 1000
        if tpot_available
        else 0.0,
        "p99_tpot_ms": p(tpots, 99) if tpot_available else 0.0,
        "mean_e2e_ms": float(np.mean(e2e or [0])) * 1000,
        "median_e2e_ms": float(np.median(e2e or [0])) * 1000,
        "p99_e2e_ms": p(e2e, 99),
        "concurrency_index": float(np.sum(e2e) / dur_s) if dur_s else 0.0,
        "itl_available": itl_available,
        "tpot_available": tpot_available,
    }
