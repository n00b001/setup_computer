"""Tests for config resolution layering."""

from __future__ import annotations

import tempfile
from pathlib import Path

from llm_bench.config import resolve


def test_defaults():
    with tempfile.TemporaryDirectory() as tmp:
        cfg, src = resolve({}, cwd=Path(tmp))
        assert cfg.base_url == "http://localhost:8000/v1"
        assert cfg.users == 5
        assert cfg.requests == 5
        assert all(s == "default" for s in src.values())


def test_env_overrides_defaults():
    with tempfile.TemporaryDirectory() as tmp:
        env = {"LLM_BENCH_BASE_URL": "http://env:8000/v1", "LLM_BENCH_USERS": "3"}
        cfg, src = resolve({}, env=env, cwd=Path(tmp))
        assert cfg.base_url == "http://env:8000/v1"
        assert cfg.users == 3
        assert src["base_url"].startswith("env")
        assert src["users"].startswith("env")
        assert src["model"] == "default"


def test_cli_overrides_env():
    with tempfile.TemporaryDirectory() as tmp:
        cli = {"base_url": "http://cli:8000/v1", "users": 7}
        env = {"LLM_BENCH_BASE_URL": "http://env:8000/v1", "LLM_BENCH_USERS": "3"}
        cfg, src = resolve(cli, env=env, cwd=Path(tmp))
        assert cfg.base_url == "http://cli:8000/v1"
        assert cfg.users == 7
        assert src["base_url"] == "cli"
        assert src["users"] == "cli"


def test_file_overrides_defaults(tmp_path: Path):
    toml = tmp_path / "llm-bench.toml"
    toml.write_text("""
[endpoint]
base_url = "http://file:8000/v1"
model = "file-model"

[serve]
users = 2
""")
    cfg, src = resolve({}, cwd=tmp_path)
    assert cfg.base_url == "http://file:8000/v1"
    assert cfg.model == "file-model"
    assert cfg.users == 2
    assert src["base_url"].startswith("file")
    assert src["model"].startswith("file")
    assert src["users"].startswith("file")


def test_full_precedence(tmp_path: Path):
    toml = tmp_path / "llm-bench.toml"
    toml.write_text("""
[endpoint]
base_url = "http://file:8000/v1"
model = "file-model"

[serve]
users = 2
""")
    env = {
        "LLM_BENCH_BASE_URL": "http://env:8000/v1",
        "LLM_BENCH_MODEL": "env-model",
        "LLM_BENCH_USERS": "3",
    }
    cli = {"base_url": "http://cli:8000/v1", "users": 7}
    cfg, src = resolve(cli, env=env, cwd=tmp_path)
    assert cfg.base_url == "http://cli:8000/v1"
    assert cfg.model == "env-model"
    assert cfg.users == 7
    assert src["base_url"] == "cli"
    assert src["model"].startswith("env")
    assert src["users"] == "cli"


def test_casting():
    with tempfile.TemporaryDirectory() as tmp:
        env = {
            "LLM_BENCH_USERS": "10",
            "LLM_BENCH_TEMPERATURE": "0.7",
            "LLM_BENCH_WARMUP": "3",
        }
        cfg, src = resolve({}, env=env, cwd=Path(tmp))
        assert cfg.users == 10
        assert cfg.temperature == 0.7
        assert cfg.warmup == 3
        assert isinstance(cfg.users, int)
        assert isinstance(cfg.temperature, float)


def test_bool_casting():
    from llm_bench.config import _TYPE_MAP, _cast

    # _cast returns int for warmup field (its type is int)
    # Testing the bool branch directly via a bool field
    _TYPE_MAP["_bool_test"] = bool
    try:
        assert _cast("_bool_test", "true") is True
        assert _cast("_bool_test", "false") is False
        assert _cast("_bool_test", "1") is True
        assert _cast("_bool_test", "0") is False
        assert _cast("_bool_test", "yes") is True
        assert _cast("_bool_test", "no") is False
    finally:
        _TYPE_MAP.pop("_bool_test", None)


def test_invalid_cast_fallback():
    from llm_bench.config import _cast

    assert _cast("users", "not-an-int") == 0
    assert _cast("temperature", "not-a-float") == 0.0
