"""Shared model constants for Agent SDK integration."""

MODEL_MAP = {
    "opus": "claude-opus-4-6",
    "sonnet": "claude-sonnet-4-5",
    "haiku": "claude-haiku-4-5",
}


def resolve_model(short: str) -> str:
    """Resolve a short model name to a full model ID. Passes through unknown names."""
    return MODEL_MAP.get(short, short)
