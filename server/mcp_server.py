"""
GitHub MCP Server (FastMCP edition)
------------------------------------
A small, production-shaped MCP server that wraps a few GitHub API
operations. Deployed on Kubernetes, exposed over streamable HTTP
(not stdio, since this runs as a long-lived service, not a local
subprocess).

Tools:
  - get_repo_info: basic metadata about a repo
  - list_issues:   list open/closed issues for a repo
  - create_issue_comment: post a comment on an issue

Observability:
  - Langfuse traces every tool call automatically via middleware
    (see langfuse_middleware.py) — latency, success/failure, I/O.
  - Structured JSON logging so Datadog's log pipeline (or plain
    kubectl logs) can parse fields without regex, with or without
    Langfuse configured.
"""

import logging
import os
import sys
from typing import Any

import httpx
from fastmcp import FastMCP

from langfuse_middleware import LangfuseTracingMiddleware, build_langfuse_client

# ---------------------------------------------------------------------------
# Structured logging setup
# ---------------------------------------------------------------------------
logging.basicConfig(
    stream=sys.stdout,
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}',
)
logger = logging.getLogger("github-mcp-server")

# ---------------------------------------------------------------------------
# GitHub API client
# ---------------------------------------------------------------------------
GITHUB_API = "https://api.github.com"
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")


def _gh_headers() -> dict[str, str]:
    headers = {"Accept": "application/vnd.github+json"}
    if GITHUB_TOKEN:
        headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"
    return headers


# ---------------------------------------------------------------------------
# MCP server + Langfuse tracing middleware
# ---------------------------------------------------------------------------
mcp = FastMCP(
    name="github-mcp-server",
    version="0.1.0",
    instructions="Provides read/write access to GitHub repo issues and metadata.",
)

_langfuse_client = build_langfuse_client()
mcp.add_middleware(LangfuseTracingMiddleware(_langfuse_client))


@mcp.tool()
async def get_repo_info(owner: str, repo: str) -> dict[str, Any]:
    """Get basic metadata about a GitHub repository (stars, open issues, description)."""
    async with httpx.AsyncClient() as client:
        resp = await client.get(f"{GITHUB_API}/repos/{owner}/{repo}", headers=_gh_headers())
        resp.raise_for_status()
        data = resp.json()
        return {
            "full_name": data["full_name"],
            "description": data.get("description"),
            "stars": data["stargazers_count"],
            "open_issues": data["open_issues_count"],
            "default_branch": data["default_branch"],
        }


@mcp.tool()
async def list_issues(owner: str, repo: str, state: str = "open", limit: int = 10) -> list[dict[str, Any]]:
    """List issues for a repository. state can be 'open', 'closed', or 'all'."""
    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{GITHUB_API}/repos/{owner}/{repo}/issues",
            headers=_gh_headers(),
            params={"state": state, "per_page": min(limit, 100)},
        )
        resp.raise_for_status()
        return [
            {
                "number": issue["number"],
                "title": issue["title"],
                "state": issue["state"],
                "url": issue["html_url"],
            }
            for issue in resp.json()
            if "pull_request" not in issue  # exclude PRs, which the API mixes into issues
        ]


@mcp.tool()
async def create_issue_comment(owner: str, repo: str, issue_number: int, body: str) -> dict[str, Any]:
    """Post a comment on a GitHub issue. Requires GITHUB_TOKEN with write access."""
    if not GITHUB_TOKEN:
        raise RuntimeError("GITHUB_TOKEN not configured — write operations are disabled")
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{GITHUB_API}/repos/{owner}/{repo}/issues/{issue_number}/comments",
            headers=_gh_headers(),
            json={"body": body},
        )
        resp.raise_for_status()
        data = resp.json()
        return {"comment_id": data["id"], "url": data["html_url"]}


# ---------------------------------------------------------------------------
# Health check route for K8s liveness/readiness probes
# ---------------------------------------------------------------------------
@mcp.custom_route("/healthz", methods=["GET"])
async def healthz(request):
    from starlette.responses import JSONResponse

    return JSONResponse({"status": "ok"})


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8000"))
    logger.info(f"Starting github-mcp-server on 0.0.0.0:{port}")
    mcp.run(
        transport="http",
        host="0.0.0.0",
        port=port,
        stateless_http=True,  # important for K8s: no sticky sessions needed, scales horizontally
    )
