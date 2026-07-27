#!/usr/bin/env python3
"""Read-only smoke test for the Unreal HTTP-to-stdio MCP bridge."""

from __future__ import annotations

import sys
from pathlib import Path

import anyio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def verify() -> None:
    proxy = Path(__file__).with_name("unreal_mcp_stdio_proxy.py")
    params = StdioServerParameters(
        command=sys.executable,
        args=[str(proxy), "--url", "http://127.0.0.1:8000/mcp"],
    )
    async with stdio_client(params) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as session:
            initialized = await session.initialize()
            tools = await session.list_tools()
            print(f"server={initialized.serverInfo.name}")
            print("tools=" + ",".join(tool.name for tool in tools.tools))


if __name__ == "__main__":
    anyio.run(verify)
