"""Task helpers for the custom intelligence evaluation dataset.

Dataset format (JSONL, one sample per line):
{
  "question": "What is 17 * 23?",
  "choices": ["351", "391", "407", "421"],
  "answer": 1,
  "category": "math"
}

The task is registered as a YAML that references these functions via
`!function llm_bench.task_helpers.doc_to_text` and `doc_to_target`.
"""

from __future__ import annotations

from typing import Any


def doc_to_text(doc: dict[str, Any]) -> str:
  lines = [doc["question"].strip(), "Choices:"]
  for i, c in enumerate(doc["choices"]):
    lines.append(f"{chr(ord('A') + i)}. {c}")
  lines.append("Answer with a single letter (A-H).")
  return "\n".join(lines)


def doc_to_target(doc: dict[str, Any]) -> str:
  ans = doc["answer"]
  if isinstance(ans, str):
    return ans.strip().upper()
  try:
    return chr(ord("A") + int(ans))
  except (ValueError, TypeError):
    return ""
