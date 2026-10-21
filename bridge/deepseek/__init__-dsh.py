"""DeepSeek bridge — auth-only entry point for DSH integration.

Lazy imports so `deepseek.auth` works without pulling in httpx/wasmtime/providers.
"""

from __future__ import annotations

__all__ = ["DeepSeekClient", "Reply"]


def __getattr__(name: str):
    if name == "DeepSeekClient":
        from .client import DeepSeekClient
        return DeepSeekClient
    if name == "Reply":
        from .client import Reply
        return Reply
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")