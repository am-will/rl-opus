#!/usr/bin/env python3
"""Bridge a local Streamable HTTP MCP server to stdio.

Claude Desktop's user-added local MCP configuration launches stdio servers.
Unreal Engine 5.8 exposes Streamable HTTP on loopback. This process connects
the two transports without exposing Unreal to the LAN or internet.
"""

from __future__ import annotations

import argparse
import sys
from typing import Any

import anyio
import mcp.types as types
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--url",
        default="http://127.0.0.1:8000/mcp",
        help="Loopback Streamable HTTP MCP endpoint.",
    )
    return parser.parse_args()


async def serve(url: str) -> None:
    if not url.startswith(("http://127.0.0.1:", "http://localhost:")):
        raise ValueError("Refusing to proxy a non-loopback MCP URL")

    async with streamable_http_client(url) as (upstream_read, upstream_write, _):
        async with ClientSession(upstream_read, upstream_write) as upstream:
            await upstream.initialize()
            call_lock = anyio.Lock()
            proxy = Server(
                "unreal-mcp-local-proxy",
                version="1.0.0",
                instructions=(
                    "Local transport bridge to Unreal Engine 5.8 MCP. "
                    "Unreal tool calls execute serially on the editor game thread."
                ),
            )

            @proxy.list_tools()
            async def list_tools() -> list[types.Tool]:
                async with call_lock:
                    result = await upstream.list_tools()
                return result.tools

            @proxy.call_tool(validate_input=True)
            async def call_tool(
                name: str,
                arguments: dict[str, Any],
            ) -> types.CallToolResult:
                async with call_lock:
                    return await upstream.call_tool(name, arguments)

            async with stdio_server() as (downstream_read, downstream_write):
                await proxy.run(
                    downstream_read,
                    downstream_write,
                    proxy.create_initialization_options(),
                )


def main() -> None:
    args = parse_args()
    try:
        anyio.run(serve, args.url)
    except KeyboardInterrupt:
        return
    except Exception as exc:
        print(f"Unreal MCP local proxy failed: {exc}", file=sys.stderr, flush=True)
        raise


if __name__ == "__main__":
    main()
