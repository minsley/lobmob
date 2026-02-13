"""Structured JSON logging and cost tracking for agent operations."""

import json
import logging
import sys
import time
from typing import Any

# Cost per million tokens (input/output) as of Feb 2026
MODEL_PRICING = {
    "claude-opus-4-6": {"input": 5.00, "output": 25.00},
    "claude-sonnet-4-5": {"input": 3.00, "output": 15.00},
    "claude-haiku-4-5": {"input": 0.80, "output": 4.00},
}


class JSONFormatter(logging.Formatter):
    """Format log records as single-line JSON."""

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "ts": self.formatTime(record),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        # Merge extra structured data if present
        if hasattr(record, "data"):
            entry["data"] = record.data
        if record.exc_info and record.exc_info[0]:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


def setup_logging(json_output: bool = True, level: int = logging.INFO) -> None:
    """Configure root logger for structured JSON output.

    Args:
        json_output: If True, use JSON formatter. If False, use human-readable format.
        level: Logging level.
    """
    handler = logging.StreamHandler(sys.stdout)
    if json_output:
        handler.setFormatter(JSONFormatter())
    else:
        handler.setFormatter(logging.Formatter(
            "%(asctime)s %(levelname)s %(name)s: %(message)s"
        ))

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(level)


def log_structured(logger: logging.Logger, msg: str, **data: Any) -> None:
    """Log a message with structured data attached."""
    record = logger.makeRecord(
        logger.name, logging.INFO, "(structured)", 0, msg, (), None
    )
    record.data = data
    logger.handle(record)


def estimate_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    """Estimate cost in USD for a given model and token counts."""
    pricing = MODEL_PRICING.get(model, MODEL_PRICING["claude-sonnet-4-5"])
    return (input_tokens * pricing["input"] + output_tokens * pricing["output"]) / 1_000_000


class CostTracker:
    """Accumulates token usage and cost across multiple LLM calls."""

    def __init__(self, budget_tokens: int = 0) -> None:
        self.total_input_tokens = 0
        self.total_output_tokens = 0
        self.total_cost_usd = 0.0
        self.call_count = 0
        self.budget_tokens = budget_tokens  # 0 = no budget
        self._logger = logging.getLogger("lobboss.cost")

    def record(self, model: str, input_tokens: int, output_tokens: int) -> None:
        self.total_input_tokens += input_tokens
        self.total_output_tokens += output_tokens
        cost = estimate_cost(model, input_tokens, output_tokens)
        self.total_cost_usd += cost
        self.call_count += 1

        total_tokens = self.total_input_tokens + self.total_output_tokens

        if self.budget_tokens:
            pct = total_tokens / self.budget_tokens
            if pct >= 0.95:
                self._logger.error(
                    "Token budget 95%% used: %d/%d tokens ($%.4f)",
                    total_tokens, self.budget_tokens, self.total_cost_usd,
                )
            elif pct >= 0.80:
                self._logger.warning(
                    "Token budget 80%% used: %d/%d tokens ($%.4f)",
                    total_tokens, self.budget_tokens, self.total_cost_usd,
                )

    def summary(self) -> dict[str, Any]:
        return {
            "calls": self.call_count,
            "input_tokens": self.total_input_tokens,
            "output_tokens": self.total_output_tokens,
            "total_tokens": self.total_input_tokens + self.total_output_tokens,
            "cost_usd": round(self.total_cost_usd, 4),
        }
