# Agent Instructions

These instructions apply to the entire `/Users/am.will/Applications/rl-opus5` repository.

## Required stack handoff

Before changing Claude, MCP, Blender, Unreal Engine, TRELLIS, Hugging Face, or Anthropic API configuration, read:

[`docs/CLAUDE_MCP_API_HANDOFF.md`](docs/CLAUDE_MCP_API_HANDOFF.md)

Treat that file as the current machine-specific runbook. Re-verify live process and listener state before relying on any PID or connection status in it.

## Setup-only boundary

Until the user explicitly asks to build assets:

- Do not call TRELLIS `/image_to_3d` or `/extract_glb`.
- Do not execute arbitrary Blender Python.
- Do not make mutating Unreal MCP tool calls.
- Do not import, generate, rename, move, or delete game assets.
- Limit validation to service health, API schema inspection, tool listing, and read-only scene/project summaries.

## Authoritative paths and endpoints

- Repository: `/Users/am.will/Applications/rl-opus5`
- Claude Code: `/Users/am.will/.local/bin/claude`
- Blender: `/Applications/Blender.app`
- Official Blender MCP source: `/Users/am.will/Applications/blender_mcp`
- Blender add-on socket: `127.0.0.1:9876`
- Active Unreal Engine: `/Users/Shared/Epic Games/UE_5.8`
- Unreal validation project: `/Users/am.will/Applications/rl-opus5/UnrealMCPHost/UnrealMCPHost.uproject`
- Unreal MCP: `http://127.0.0.1:8000/mcp`
- TRELLIS source on `linux`: `/home/amwill/AI/TRELLIS.2`
- TRELLIS weights on `linux`: `/home/amwill/Models/TRELLIS.2-4B`
- Mac-side TRELLIS URL through SSH tunnel: `http://127.0.0.1:7860`

The Unreal copy at `/Volumes/Mac Extended/ExternalStorage/Applications/UE_5.8` is a backup. Do not launch it as the authoritative engine and do not delete the internal installation.

## MCP and configuration rules

- Claude Code running inside the Claude Desktop application is local Claude Code. It can load this project's `.mcp.json`, including Unreal's `http://127.0.0.1:8000/mcp`. Do not claim that the Desktop app itself prevents this workflow.
- Distinguish local Claude Code in Desktop from claude.ai account-level custom connectors. Only the latter originate from Anthropic's cloud and cannot reach this Mac's loopback addresses.
- Prefer project-scoped Claude Code MCP definitions in `.mcp.json`.
- Merge MCP entries; never overwrite unrelated servers or the entire Claude configuration.
- Preserve existing `controlium` and `onshape` entries unless the user separately asks to change them.
- For Claude Code stdio servers, keep all Claude flags before the server name and use `--` before the subprocess command.
- Unreal is Streamable HTTP MCP.
- Blender is stdio MCP backed by its local TCP add-on.
- TRELLIS is a Gradio API, not MCP. A future MCP bridge must be described and tested honestly before it is registered.
- Project-scoped `.mcp.json` servers require interactive approval in Claude Code.
- Require connected status plus a read-only tool call before claiming success.

## Linux and process rules

- The SSH alias is `linux`.
- Its login shell is Fish. Wrap multi-step remote commands in `bash -lc` or `bash -s`.
- Check listeners before launching another process or tunnel.
- Do not kill unknown port owners.
- Keep `OPENCV_IO_ENABLE_OPENEXR=1` when launching TRELLIS.
- Keep all three service endpoints bound to loopback.
- Never create a Gradio public share link or expose Unreal MCP to the LAN.
- Unreal MCP tool calls must be serial, not concurrent.

## Credentials

- Never print, commit, or copy Hugging Face, Anthropic, Onshape, or other tokens.
- Claude subscription login and `ANTHROPIC_API_KEY` are different authentication modes; do not silently switch between them.
- Store API credentials outside the repository and inject them at runtime.
- Never place an Anthropic key in browser-side Vite code.

## Change safety

- Preserve unrelated working-tree changes.
- Use `apply_patch` for repository file edits.
- Before later scene or asset mutation, use version control or an Unreal Sandbox and confirm the user has asked to build assets.
- Unreal MCP is experimental. Verify the open editor, active project, target asset, and tool schema before every consequential call.
- Do not claim an external write or tool action succeeded without returned evidence or a read-back.

## Minimum verification

For connection-only work, collect:

```bash
claude auth status
claude mcp list
lsof -nP -iTCP:7860 -iTCP:8000 -iTCP:9876 -sTCP:LISTEN
curl -fsS http://127.0.0.1:7860/gradio_api/info
```

Then perform one read-only Blender summary and one Unreal toolset listing from Claude. Do not generate or modify assets as a connection test.
