"""Dataset generation utility - creates evaluation datasets from an LLM with human-in-the-loop review.

Uses OpenAI function calling (tools) for structured output - the single happy path
that works with the local inference server.
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from typing import Any

import aiohttp
from pydantic import BaseModel, Field, field_validator

log = logging.getLogger("llm_bench.dataset_gen")


class Question(BaseModel):
    """A single benchmark question."""

    question: str = Field(..., description="The question text")
    choices: list[str] = Field(..., description="Answer choices")
    answer: int = Field(..., description="Index of correct answer")
    category: str = Field(..., description="Category name")
    explanation: str = Field(..., description="Brief explanation")

    @field_validator("choices")
    @classmethod
    def validate_choices(cls, v: list[str]) -> list[str]:
        if len(v) not in (2, 4):
            raise ValueError(
                "Choices must have 2 (true/false) or 4 (multiple choice) items"
            )
        return v

    @field_validator("answer")
    @classmethod
    def validate_answer(cls, v: int, info: Any) -> int:
        if "choices" in info.data:
            max_idx = len(info.data["choices"]) - 1
            if v < 0 or v > max_idx:
                raise ValueError(f"Answer index must be 0-{max_idx}")
        return v


class GenerationConfig(BaseModel):
    """Configuration for dataset generation."""

    dataset_type: str = Field(
        default="multiple_choice", description="multiple_choice or true_false"
    )
    num_questions: int = Field(
        default=10, ge=1, le=100, description="Number of questions to generate"
    )
    categories: list[str] = Field(
        default_factory=lambda: ["math", "science", "logic", "geography", "literature"]
    )
    themes: list[str] = Field(
        default_factory=list, description="Optional theme descriptions"
    )
    difficulty_mix: str = Field(
        default="balanced", description="easy, medium, hard, or balanced"
    )


def _build_tool_schema(config: GenerationConfig) -> dict[str, Any]:
    """Build the function calling schema from Pydantic models."""
    # Use Question model schema for the array items
    question_schema = Question.model_json_schema()
    question_schema["additionalProperties"] = False

    return {
        "type": "function",
        "function": {
            "name": "generate_questions",
            "description": f"Generate {config.num_questions} benchmark questions",
            "parameters": {
                "type": "object",
                "properties": {
                    "questions": {
                        "type": "array",
                        "items": question_schema,
                        "minItems": config.num_questions,
                        "maxItems": config.num_questions,
                    }
                },
                "required": ["questions"],
                "additionalProperties": False,
            },
        },
    }


def _build_generation_prompt(
    config: GenerationConfig, approved_examples: list[Question] | None = None
) -> str:
    """Build the prompt for generating questions."""

    cat_str = ", ".join(config.categories)
    themes_str = ", ".join(config.themes) if config.themes else "general knowledge"

    if config.dataset_type == "true_false":
        format_desc = "TRUE/FALSE questions with exactly 2 choices: ['True', 'False']"
        answer_desc = "0 for True, 1 for False"
    else:
        format_desc = "MULTIPLE CHOICE questions with exactly 4 options"
        answer_desc = "0, 1, 2, or 3 (index of correct answer)"

    # Add few-shot examples from approved questions
    examples_section = ""
    if approved_examples:
        examples_section = (
            "\n\nHere are approved examples to match the style and difficulty:\n"
        )
        for i, ex in enumerate(approved_examples[:5], 1):
            examples_section += f"\nExample {i}:\n{ex.model_dump_json()}\n"

    prompt = f"""You are creating a benchmark dataset for evaluating LLM intelligence.
Generate exactly {config.num_questions} {format_desc}.

Configuration:
- Categories: {cat_str}
- Themes: {themes_str}
- Difficulty: {config.difficulty_mix}
- Answer format: {answer_desc}
{examples_section}

Requirements:
- Distribute questions evenly across categories
- Vary difficulty levels
- Make questions unambiguous and verifiable without an LLM
- For true/false: statements must be clearly true or false
- For multiple choice: exactly 4 options, only one correct
- Each question must have a brief explanation

Call the generate_questions function with the questions array."""

    return prompt


async def _chat_request_with_tools(
    api_url: str,
    model: str,
    prompt: str,
    tools: list[dict[str, Any]],
    api_key: str = "",
    seed: int | None = None,
    timeout: int = 600,
) -> dict[str, Any]:
    """Non-streaming OpenAI Chat Completions request with function calling."""
    assert api_url.endswith("/chat/completions"), api_url

    timeout_obj = aiohttp.ClientTimeout(total=timeout)
    async with aiohttp.ClientSession(timeout=timeout_obj) as session:
        # Add system prompt to ensure tool usage
        messages = [
            {"role": "system", "content": "You are a benchmark question generator. You MUST call the generate_questions function with the requested questions. Do not output questions directly."},
            {"role": "user", "content": prompt},
        ]
        payload: dict[str, Any] = {
            "model": model,
            "messages": messages,
            "max_completion_tokens": 4096,
            "temperature": 0.3,
            "stream": False,
            "tools": tools,
            "tool_choice": {
                "type": "function",
                "function": {"name": "generate_questions"},
            },
        }
        if seed is not None:
            payload["seed"] = seed

        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}

        async with session.post(api_url, json=payload, headers=headers) as response:
            if response.status == 200:
                data = await response.json()
                choices = data.get("choices") or []
                if choices:
                    msg = choices[0].get("message", {})
                    tool_calls = msg.get("tool_calls") or []
                    if tool_calls:
                        # Parse function arguments
                        for tc in tool_calls:
                            if (
                                tc.get("function", {}).get("name")
                                == "generate_questions"
                            ):
                                try:
                                    args = json.loads(tc["function"]["arguments"])
                                    return {"success": True, "data": args}
                                except Exception as e:
                                    return {
                                        "success": False,
                                        "error": f"Failed to parse function args: {e}",
                                    }
                        return {
                            "success": False,
                            "error": "No generate_questions tool call found",
                        }
                    # Fallback: try to parse content as JSON if no tool calls
                    content = msg.get("content", "")
                    if content and content.strip().startswith("{"):
                        try:
                            args = json.loads(content)
                            if "questions" in args:
                                return {"success": True, "data": args}
                        except Exception:
                            pass
                    return {"success": False, "error": "No tool calls in response"}
                return {"success": False, "error": "No choices in response"}
            else:
                return {
                    "success": False,
                    "error": f"HTTP {response.status}: {await response.text()}",
                }


async def generate_batch(
    base_url: str,
    model: str,
    api_key: str,
    config: GenerationConfig,
    seed: int,
    approved_examples: list[Question] | None = None,
) -> list[Question]:
    """Generate a batch of questions using function calling for structured output."""
    api_url = base_url.rstrip("/") + "/chat/completions"
    prompt = _build_generation_prompt(config, approved_examples)
    tools = [_build_tool_schema(config)]

    log.debug("Sending dataset generation request to %s", api_url)
    start = time.perf_counter()

    result = await _chat_request_with_tools(
        api_url, model, prompt, tools, api_key, seed, timeout=600
    )
    dur = time.perf_counter() - start

    if not result["success"]:
        log.error("Generation failed: %s", result["error"])
        raise RuntimeError(f"Dataset generation failed: {result['error']}")

    log.debug("Received response in %.2fs", dur)

    # Parse and validate with Pydantic
    questions_data = result["data"].get("questions", [])
    questions = []
    for item in questions_data:
        try:
            questions.append(Question(**item))
        except Exception as e:
            log.warning("Skipping invalid question: %s", e)

    if not questions:
        raise RuntimeError("No valid questions generated")

    return questions


def interactive_config() -> GenerationConfig:
    """Interactively ask user for dataset generation configuration."""
    print("\n" + "=" * 60)
    print("Dataset Generation Configuration")
    print("=" * 60)

    # Dataset type
    while True:
        dt = (
            input(
                "\nDataset type [multiple_choice/true_false] (default: multiple_choice): "
            )
            .strip()
            .lower()
        )
        if dt in ("", "multiple_choice", "mc", "m"):
            dataset_type = "multiple_choice"
            break
        elif dt in ("true_false", "tf", "t"):
            dataset_type = "true_false"
            break
        print("Please enter 'multiple_choice' or 'true_false'")

    # Number of questions
    while True:
        nq = input("Number of questions (1-100, default: 10): ").strip()
        if nq == "":
            num_questions = 10
            break
        try:
            num_questions = int(nq)
            if 1 <= num_questions <= 100:
                break
            print("Please enter a number between 1 and 100")
        except ValueError:
            print("Please enter a valid number")

    # Categories
    print(
        "\nAvailable categories: math, science, logic, geography, literature, history, programming, general"
    )
    cats = input(
        "Categories (comma-separated, default: math,science,logic,geography,literature): "
    ).strip()
    if cats == "":
        categories = ["math", "science", "logic", "geography", "literature"]
    else:
        categories = [c.strip() for c in cats.split(",") if c.strip()]

    # Themes
    themes = input(
        "Optional themes/descriptions (comma-separated, e.g., 'algebra, world capitals, logic puzzles'): "
    ).strip()
    themes_list = [t.strip() for t in themes.split(",") if t.strip()] if themes else []

    # Difficulty
    while True:
        diff = (
            input("Difficulty mix [easy/medium/hard/balanced] (default: balanced): ")
            .strip()
            .lower()
        )
        if diff in ("", "balanced"):
            difficulty_mix = "balanced"
            break
        elif diff in ("easy", "medium", "hard"):
            difficulty_mix = diff
            break
        print("Please enter 'easy', 'medium', 'hard', or 'balanced'")

    return GenerationConfig(
        dataset_type=dataset_type,
        num_questions=num_questions,
        categories=categories,
        themes=themes_list,
        difficulty_mix=difficulty_mix,
    )


def display_questions(questions: list[Question], start_idx: int = 0) -> None:
    """Display questions in a readable format."""
    print("\n" + "-" * 60)
    for i, q in enumerate(questions, start=start_idx + 1):
        print(f"\n  [{i}] {q.question}")
        for j, choice in enumerate(q.choices):
            marker = " →" if j == q.answer else ""
            print(f"      {chr(65 + j)}. {choice}{marker}")
        print(f"      Category: {q.category} | Explanation: {q.explanation}")


def review_questions(
    questions: list[Question],
) -> tuple[list[Question], list[Question]]:
    """Let user review and accept/reject questions."""
    print("\n" + "=" * 60)
    print("Review Generated Questions")
    print("=" * 60)

    accepted = []
    rejected = []

    for i, q in enumerate(questions):
        print(f"\n--- Question {i + 1}/{len(questions)} ---")
        print(f"  {q.question}")
        for j, choice in enumerate(q.choices):
            marker = " ✓" if j == q.answer else ""
            print(f"      {chr(65 + j)}. {choice}{marker}")
        print(f"      Category: {q.category} | Explanation: {q.explanation}")

        while True:
            action = input("  [a]ccept / [r]eject / [e]dit / [q]uit: ").strip().lower()
            if action in ("a", "accept"):
                accepted.append(q)
                break
            elif action in ("r", "reject"):
                rejected.append(q)
                break
            elif action in ("e", "edit"):
                edited = edit_question(q)
                accepted.append(edited)
                break
            elif action in ("q", "quit"):
                return accepted, rejected + questions[i:]
            else:
                print("  Please enter a, r, e, or q")

    return accepted, rejected


def edit_question(q: Question) -> Question:
    """Interactively edit a question."""
    print("  Editing question (press Enter to keep current value):")

    new_q = input(f"  Question [{q.question}]: ").strip()
    if new_q:
        q.question = new_q

    print(f"  Choices (current: {', '.join(q.choices)}):")
    new_choices = []
    for j, choice in enumerate(q.choices):
        new_c = input(f"    {chr(65 + j)}. [{choice}]: ").strip()
        new_choices.append(new_c if new_c else choice)
    q.choices = new_choices

    while True:
        new_a = input(f"  Answer index 0-{len(q.choices) - 1} [{q.answer}]: ").strip()
        if new_a == "":
            break
        try:
            ai = int(new_a)
            if 0 <= ai < len(q.choices):
                q.answer = ai
                break
            print(f"  Must be 0-{len(q.choices) - 1}")
        except ValueError:
            print("  Enter a number")

    new_cat = input(f"  Category [{q.category}]: ").strip()
    if new_cat:
        q.category = new_cat

    new_exp = input(f"  Explanation [{q.explanation}]: ").strip()
    if new_exp:
        q.explanation = new_exp

    return q


async def generate_dataset_interactive(
    base_url: str,
    model: str,
    api_key: str,
    output_path: str,
    seed: int = 42,
) -> None:
    """Interactive dataset generation with human review loop."""
    config = interactive_config()

    all_accepted: list[Question] = []
    remaining = config.num_questions

    print(f"\n{'=' * 60}")
    print(f"Generating {config.num_questions} {config.dataset_type} questions...")
    print(f"{'=' * 60}")

    while remaining > 0:
        batch_size = min(remaining, 10)
        batch_config = config.model_copy(update={"num_questions": batch_size})

        print(f"\n--- Generating batch of {batch_size} questions ---")
        try:
            generated = await generate_batch(
                base_url, model, api_key, batch_config, seed, all_accepted
            )
        except Exception as e:
            log.error("Generation error: %s", e)
            if not all_accepted:
                raise
            print(
                f"Error generating batch. Continuing with {len(all_accepted)} accepted questions..."
            )
            break

        new_accepted, rejected = review_questions(generated)
        all_accepted.extend(new_accepted)
        remaining -= batch_size

        print(f"\nAccepted: {len(new_accepted)}, Rejected: {len(rejected)}")
        print(f"Total accepted so far: {len(all_accepted)}")

        if remaining > 0:
            more = input("\nGenerate more questions? [Y/n]: ").strip().lower()
            if more in ("n", "no"):
                break
            while True:
                more_n = input(
                    f"How many more? (1-{remaining}, default: {remaining}): "
                ).strip()
                if more_n == "":
                    break
                try:
                    mn = int(more_n)
                    if 1 <= mn <= remaining:
                        remaining = mn
                        break
                    print(f"Please enter 1-{remaining}")
                except ValueError:
                    print("Enter a number")

    if not all_accepted:
        print("No questions accepted. Aborting.")
        return

    print(f"\n{'=' * 60}")
    print(f"FINAL REVIEW: {len(all_accepted)} accepted questions")
    print(f"{'=' * 60}")
    display_questions(all_accepted)

    final_confirm = input("\nSave dataset? [Y/n]: ").strip().lower()
    if final_confirm in ("n", "no"):
        print("Aborted.")
        return

    output_file = Path(output_path)
    output_file.parent.mkdir(parents=True, exist_ok=True)

    with output_file.open("w") as f:
        for q in all_accepted:
            eval_q = {
                "question": q.question,
                "choices": q.choices,
                "answer": q.answer,
                "category": q.category,
            }
            f.write(json.dumps(eval_q) + "\n")

    print(f"\n✓ Dataset written to {output_path} ({len(all_accepted)} questions)")

    yaml_path = output_file.with_suffix(".yaml")
    yaml_content = f"""task: {output_file.stem}
dataset_path: json
dataset_name: null
dataset_kwargs:
  data_files:
    train: {output_file.name}
test_split: train
output_type: generate_until
doc_to_text: !function llm_bench.task_helpers.doc_to_text
doc_to_target: !function llm_bench.task_helpers.doc_to_target
generation_kwargs:
  max_tokens: 64
  temperature: 0.0
  stop: ["\\n\\n"]
  until: ["\\n\\n"]
metric_list:
  - metric: exact_match
    aggregation: mean
    higher_is_better: true
    ignore_case: true
    ignore_punctuation: false
    regexes_to_ignore: []
filter_list:
  - name: letter
    filter:
      - function: "regex"
        regex_pattern: "([A-H])"
      - function: "take_first"
"""
    yaml_path.write_text(yaml_content)
    print(f"✓ YAML task template written to {yaml_path}")


# Backward compatibility
async def generate_dataset(
    base_url: str,
    model: str,
    api_key: str,
    num_questions: int,
    categories: list[str],
    dataset_type: str,
    output_path: str,
    seed: int = 42,
) -> None:
    """Non-interactive generation for backward compatibility."""
    config = GenerationConfig(
        dataset_type=dataset_type,
        num_questions=num_questions,
        categories=categories,
    )
    questions = await generate_batch(base_url, model, api_key, config, seed)

    valid_questions = []
    for q in questions:
        if len(q.choices) == (2 if dataset_type == "true_false" else 4):
            valid_questions.append(q)

    output_file = Path(output_path)
    output_file.parent.mkdir(parents=True, exist_ok=True)

    with output_file.open("w") as f:
        for q in valid_questions:
            eval_q = {
                "question": q.question,
                "choices": q.choices,
                "answer": q.answer,
                "category": q.category,
            }
            f.write(json.dumps(eval_q) + "\n")

    log.info("Dataset written to %s (%d questions)", output_path, len(valid_questions))

    yaml_path = output_file.with_suffix(".yaml")
    yaml_content = f"""task: {output_file.stem}
dataset_path: json
dataset_name: null
dataset_kwargs:
  data_files:
    train: {output_file.name}
test_split: train
output_type: generate_until
doc_to_text: !function llm_bench.task_helpers.doc_to_text
doc_to_target: !function llm_bench.task_helpers.doc_to_target
generation_kwargs:
  max_tokens: 64
  temperature: 0.0
  stop: ["\\n\\n"]
  until: ["\\n\\n"]
metric_list:
  - metric: exact_match
    aggregation: mean
    higher_is_better: true
    ignore_case: true
    ignore_punctuation: false
    regexes_to_ignore: []
filter_list:
  - name: letter
    filter:
      - function: "regex"
        regex_pattern: "([A-H])"
      - function: "take_first"
"""
    yaml_path.write_text(yaml_content)
    log.info("YAML task template written to %s", yaml_path)
