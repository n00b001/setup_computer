"""Tests for the serving benchmark against a mock OpenAI-compatible server."""

from __future__ import annotations

import asyncio
import json
import sys
import threading

import pytest
from aiohttp import web

sys.path.insert(0, str(__import__("pathlib").Path(__file__).parent.parent))

from llm_bench import serving


def start_mock_server(
    ttft_delay: float = 0.05, itl_delay: float = 0.01, n_tokens: int = 20
):
    """Start a mock OpenAI chat-completions server on a random port.
    Returns (base_url, thread, loop, runner, stop_event).
    """
    app = web.Application()

    async def mock_chat(request):
        body = await request.json()
        resp = web.StreamResponse(
            status=200,
            headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"},
        )
        await resp.prepare(request)

        await asyncio.sleep(ttft_delay)
        for i in range(n_tokens):
            chunk = {"choices": [{"delta": {"content": f"tok{i} "}}]}
            if i == 0:
                chunk["choices"][0]["delta"] = {"role": "assistant", "content": "tok0 "}
            await resp.write(f"data: {json.dumps(chunk)}\n\n".encode())
            await asyncio.sleep(itl_delay)

        usage = {
            "prompt_tokens": 10,
            "completion_tokens": n_tokens,
            "total_tokens": n_tokens + 10,
        }
        await resp.write(
            f"data: {json.dumps({'choices': [], 'usage': usage})}\n\n".encode()
        )
        await resp.write(b"data: [DONE]\n\n")
        await resp.write_eof()
        return resp

    app.router.add_post("/v1/chat/completions", mock_chat)

    loop = asyncio.new_event_loop()
    runner = web.AppRunner(app, access_log=None)
    ready = threading.Event()
    port_box: dict[str, int] = {}

    def run_loop():
        asyncio.set_event_loop(loop)
        loop.run_until_complete(runner.setup())
        site = web.TCPSite(runner, "127.0.0.1", 0)
        loop.run_until_complete(site.start())
        port_box["port"] = runner.addresses[0][1]
        ready.set()
        loop.run_forever()

    t = threading.Thread(target=run_loop, daemon=True)
    t.start()
    if not ready.wait(timeout=10):
        raise RuntimeError("Server failed to start")

    base_url = f"http://127.0.0.1:{port_box['port']}/v1"
    return base_url, t, loop, runner


@pytest.mark.asyncio
async def test_benchmark_metrics():
    base_url, thread, loop, runner = start_mock_server(
        ttft_delay=0.05, itl_delay=0.01, n_tokens=20
    )
    api_url = base_url + "/chat/completions"

    try:
        outputs, dur = await serving.benchmark(
            api_url=api_url,
            model="mock",
            prompt="hello",
            prompt_len=5,
            output_len=20,
            num_requests=4,
            max_concurrency=2,
            warmup_requests=1,
            disable_tqdm=True,
        )

        assert len(outputs) == 4
        assert all(o.success for o in outputs)

        m = serving.calculate_metrics(outputs, dur)
        assert m["completed"] == 4
        assert m["failed"] == 0
        assert m["total_output_tokens"] == 4 * 20
        assert m["output_throughput"] > 0
        # TTFT ~50ms (allow slack)
        assert 0.03 < m["mean_ttft_ms"] / 1000 < 1.0
        # ITL ~10ms
        assert 0.005 < m["mean_itl_ms"] / 1000 < 0.1
    finally:
        await runner.cleanup()
        loop.call_soon_threadsafe(loop.stop)


@pytest.mark.asyncio
async def test_single_user_throughput():
    """Single user (concurrency=1) should show baseline throughput."""
    base_url, thread, loop, runner = start_mock_server(
        ttft_delay=0.02, itl_delay=0.005, n_tokens=50
    )
    api_url = base_url + "/chat/completions"

    try:
        outputs, dur = await serving.benchmark(
            api_url=api_url,
            model="mock",
            prompt="hello",
            prompt_len=5,
            output_len=50,
            num_requests=5,
            max_concurrency=1,
            warmup_requests=1,
            disable_tqdm=True,
        )
        m = serving.calculate_metrics(outputs, dur)
        assert m["completed"] == 5
        # With 50 tokens per request * 5 requests = 250 tokens
        # Should complete in ~0.5s (10ms TTFT + 50*5ms = 260ms per request * 5 = 1.3s wall)
        assert m["output_throughput"] > 100  # tokens/s
    finally:
        await runner.cleanup()
        loop.call_soon_threadsafe(loop.stop)
