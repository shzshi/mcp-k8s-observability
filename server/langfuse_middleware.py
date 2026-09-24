"""
Langfuse tracing middleware for FastMCP.

Rather than decorating every tool individually, this hooks into FastMCP's
middleware pipeline once and traces every tool call automatically —
latency, success/failure, and input/output — using the official Langfuse
Python SDK directly (not a third-party glue package, since those are thin
and not worth the dependency risk for a production-shaped project).

If Langfuse isn't configured (no env vars set), this middleware becomes a
no-op passthrough so the server still boots and works locally without it.
"""

import logging
import os
import time

from fastmcp.server.middleware import CallNext, Middleware, MiddlewareContext
from mcp.types import CallToolRequestParams

logger = logging.getLogger("github-mcp-server")


def build_langfuse_client():
    """Create a Langfuse client from env vars, or return None if unset."""
    if not (os.environ.get("LANGFUSE_PUBLIC_KEY") and os.environ.get("LANGFUSE_SECRET_KEY")):
        logger.warning("Langfuse env vars not set — tracing disabled, tools still work")
        return None
    try:
        from langfuse import Langfuse

        client = Langfuse(
            public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
            secret_key=os.environ["LANGFUSE_SECRET_KEY"],
            host=os.environ.get("LANGFUSE_HOST", "https://cloud.langfuse.com"),
        )
        logger.info("Langfuse tracing enabled")
        return client
    except ImportError:
        logger.warning("langfuse package not installed — tracing disabled")
        return None


class LangfuseTracingMiddleware(Middleware):
    """Traces every MCP tool call as a Langfuse span, plus structured
    JSON logging so the same events are visible via kubectl logs / Datadog
    even without Langfuse configured."""

    def __init__(self, langfuse_client=None):
        self.langfuse = langfuse_client

    async def on_call_tool(
        self,
        context: MiddlewareContext[CallToolRequestParams],
        call_next: CallNext,
    ):
        tool_name = context.message.name
        arguments = context.message.arguments or {}
        start = time.perf_counter()

        span = None
        if self.langfuse:
            span = self.langfuse.start_span(
                name=f"tool:{tool_name}",
                input=arguments,
                metadata={"transport": "streamable_http"},
            )

        try:
            result = await call_next(context)
            elapsed_ms = round((time.perf_counter() - start) * 1000, 2)
            logger.info(
                f'{{"event":"tool_call","tool":"{tool_name}","status":"success","duration_ms":{elapsed_ms}}}'
            )
            if span:
                # result is a ToolResult; keep the trace payload small and serialisable
                output_preview = str(getattr(result, "content", result))[:2000]
                span.update(output=output_preview, level="DEFAULT")
                span.end()
            return result

        except Exception as exc:
            elapsed_ms = round((time.perf_counter() - start) * 1000, 2)
            logger.error(
                f'{{"event":"tool_call","tool":"{tool_name}","status":"error",'
                f'"duration_ms":{elapsed_ms},"error":"{str(exc)}"}}'
            )
            if span:
                span.update(output={"error": str(exc)}, level="ERROR")
                span.end()
            raise
