# Claude 3D Stack MCP and API Handoff

Last verified: 2026-07-25 on this Mac and the SSH host named `linux`.

## Mission

Connect Claude to the already-installed Blender, Unreal Engine, and TRELLIS.2 stack, then prove the connections with read-only checks.

## Important Claude Desktop distinction

The Claude Desktop application contains more than one execution mode:

- **Claude Code inside Claude Desktop:** This is a local Claude Code session presented in the Desktop UI. It supports the project's `.mcp.json`, including Unreal's local Streamable HTTP endpoint at `http://127.0.0.1:8000/mcp`. This is the recommended way to operate the complete stack from Claude Desktop.
- **Regular Claude chat with account-level custom connectors:** These connectors are reached from Anthropic's cloud. A connector configured there cannot reach this Mac's `127.0.0.1`.
- **Legacy/local Desktop MCP configuration:** `claude_desktop_config.json` can launch local stdio integrations such as Blender for regular Desktop chat.

Do not conflate the Desktop application with account-level remote connectors. The user can run the full workflow in Claude Desktop by using its Claude Code mode and the project `.mcp.json`. A full app restart is not a fundamental limitation; at most, a new/reloaded Code session may be needed after changing MCP configuration.

This is a setup-only pass:

- Do not generate a TRELLIS asset.
- Do not create, import, modify, or delete Blender or Unreal assets.
- Do not expose any localhost port to the LAN or internet.
- Do not copy API tokens into this repository, `.mcp.json`, command history, or chat.

## Definition of done

The setup is complete when all of the following are true:

1. `claude auth status` reports `"loggedIn": true`.
2. Claude Code shows both `blender-lab` and `unreal-mcp` as connected.
3. A read-only Blender summary tool succeeds.
4. Unreal's MCP endpoint is listening and Claude can list its MCP tools or toolsets.
5. TRELLIS's live Gradio schema is reachable through the Mac's SSH tunnel.
6. No asset-generation or scene-mutation call has been made.

## Current verified state

| Component | Current state | Authoritative location |
| --- | --- | --- |
| Claude Code | Installed, version `2.1.212`; currently signed out | `/Users/am.will/.local/bin/claude` |
| Claude Desktop MCP config | Present but has no configured MCP servers | `/Users/am.will/Library/Application Support/Claude/claude_desktop_config.json` |
| Blender | Blender 5.2 LTS running; add-on listening on `127.0.0.1:9876` | `/Applications/Blender.app` |
| Blender MCP source | Official Blender Lab server | `/Users/am.will/Applications/blender_mcp` |
| Unreal Engine | UE 5.8 running; official MCP listening on `127.0.0.1:8000/mcp` | `/Users/Shared/Epic Games/UE_5.8` |
| Unreal MCP host project | Empty validation project with `ModelContextProtocol` and `AllToolsets` enabled | `/Users/am.will/Applications/rl-opus5/UnrealMCPHost/UnrealMCPHost.uproject` |
| TRELLIS.2 | Gradio process running on Linux `127.0.0.1:7860`; Mac SSH tunnel on local port `7860` | `/home/amwill/AI/TRELLIS.2` on `linux` |
| TRELLIS weights | Present | `/home/amwill/Models/TRELLIS.2-4B` on `linux` |
| Hugging Face | CLI authenticated as `amwillryan` on `linux` | Stored by the Linux HF CLI; do not copy its token |

Existing unrelated Claude Code MCP entries must be preserved:

- `controlium` was connected at verification time.
- `onshape` existed but failed its health check.

Do not remove, rename, repair, or overwrite either one as part of this task.

## Connection topology

```text
Claude Code
  ├─ MCP/stdio → blender-lab → TCP 127.0.0.1:9876 → Blender add-on
  ├─ MCP/HTTP  → http://127.0.0.1:8000/mcp       → Unreal Editor 5.8
  └─ shell or future stdio MCP bridge
                  → http://127.0.0.1:7860         → SSH tunnel
                                                      → TRELLIS.2 on linux
```

TRELLIS's endpoint is a Gradio API. It is not an MCP server. Do not register `http://127.0.0.1:7860` with `claude mcp add`.

## 1. Authenticate Claude Code

Run from the project root:

```bash
cd /Users/am.will/Applications/rl-opus5
claude auth status
```

For the user's Claude subscription:

```bash
claude auth login --claudeai
```

For Anthropic Console/API-usage billing instead:

```bash
claude auth login --console
```

Choose one authentication path deliberately. An `ANTHROPIC_API_KEY` in the environment makes Claude Code use API credentials instead of the Claude subscription and can change which claude.ai connectors are loaded.

Verify:

```bash
claude auth status
```

Do not continue until it reports `"loggedIn": true`.

Official reference: [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp).

## 2. Confirm the three services before registering them

### Blender

Check the listener:

```bash
lsof -nP -iTCP:9876 -sTCP:LISTEN
```

If it is absent, start Blender:

```bash
open -a /Applications/Blender.app
```

In Blender, confirm the official MCP extension is enabled and its preferences are:

- Host: `127.0.0.1`
- Port: `9876`
- Auto-start: enabled

The installed extension directory is:

```text
/Users/am.will/Library/Application Support/Blender/5.2/extensions/user_default/mcp
```

The server command Claude will launch is:

```bash
/opt/homebrew/bin/uv --directory /Users/am.will/Applications/blender_mcp/mcp run blender-mcp
```

Official reference: [Blender Lab MCP server](https://www.blender.org/lab/mcp-server/).

### Unreal Engine

Check the listener:

```bash
lsof -nP -iTCP:8000 -sTCP:LISTEN
```

Only if it is absent, launch the validation project:

```bash
open -n -a '/Users/Shared/Epic Games/UE_5.8/Engine/Binaries/Mac/UnrealEditor.app' \
  --args '/Users/am.will/Applications/rl-opus5/UnrealMCPHost/UnrealMCPHost.uproject' \
  -ModelContextProtocolStartServer \
  -ModelContextProtocolPort=8000 \
  -log
```

The project already enables:

- `ModelContextProtocol`
- `AllToolsets`
- Auto-start
- Tool search
- Port `8000`
- URL path `/mcp`

A normal browser-style `GET` to `/mcp` returns HTTP `405`. That is expected because the MCP endpoint expects protocol requests such as `POST`; use the listener check and an MCP client for validation.

If needed, the Unreal console commands are:

```text
ModelContextProtocol.StartServer 8000
ModelContextProtocol.StopServer
ModelContextProtocol.RefreshTools
ModelContextProtocol.GenerateClientConfig ClaudeCode
```

Unreal executes MCP tool invocations serially on the game thread. Do not issue overlapping calls.

Official references:

- [Unreal MCP in Unreal Editor](https://dev.epicgames.com/documentation/unreal-engine/unreal-mcp-in-unreal-editor)
- [Unreal Engine 5.8 announcement](https://www.unrealengine.com/news/unreal-engine-5-8-is-now-available)

### TRELLIS.2

Check the Mac-side tunnel:

```bash
lsof -nP -iTCP:7860 -sTCP:LISTEN
```

Check the remote process and weights:

```bash
ssh linux 'bash -lc '\''ss -ltnp | grep 7860 || true; pgrep -af ".venv/bin/python app.py" || true; test -d /home/amwill/Models/TRELLIS.2-4B && echo weights=present || echo weights=missing'\'''
```

The login shell on `linux` is Fish. Wrap multi-step commands in Bash as shown; do not assume Bash syntax is accepted by the remote login shell.

If the remote Gradio process is absent, start it:

```bash
ssh linux 'bash -lc '\''cd /home/amwill/AI/TRELLIS.2; : > trellis-gradio.log; nohup env OPENCV_IO_ENABLE_OPENEXR=1 GRADIO_SERVER_NAME=127.0.0.1 GRADIO_SERVER_PORT=7860 CUDA_HOME=/opt/cuda PATH=/opt/cuda/bin:$PATH .venv/bin/python app.py > trellis-gradio.log 2>&1 < /dev/null & printf "%s\n" $!'\'''
```

If the Mac listener is absent, start the tunnel:

```bash
ssh -f -N -o ExitOnForwardFailure=yes -L 7860:127.0.0.1:7860 linux
```

Do not start a second tunnel if port `7860` is already listening.

Verify the UI and API metadata without generating anything:

```bash
curl -fsS http://127.0.0.1:7860/ >/dev/null

curl -fsS http://127.0.0.1:7860/gradio_api/info \
  | jq '{named_endpoints:(.named_endpoints | keys)}'
```

The live API exposed these named endpoints at verification time:

```text
/start_session
/image_to_3d
/extract_glb
/get_seed
/preprocess_image_1
/lambda
/lambda_1
```

The two important generation contracts were:

- `/image_to_3d`: image, seed, resolution, and sampling/guidance parameters.
- `/extract_glb`: decimation target and texture size; returns the preview and downloadable GLB.

Use one `gradio_client.Client` instance for a complete job because the app carries session state between `/start_session`, `/image_to_3d`, and `/extract_glb`.

Official references:

- [TRELLIS.2 repository](https://github.com/microsoft/TRELLIS.2)
- [Gradio Python client](https://gradio.app/guides/getting-started-with-the-python-client)

## 3. Register Blender and Unreal with Claude Code

Project scope is recommended because it creates a reviewable `.mcp.json` in this repository and keeps the 3D tools tied to this project.

Run exactly:

```bash
cd /Users/am.will/Applications/rl-opus5

claude mcp add \
  --transport stdio \
  --scope project \
  blender-lab \
  -- /opt/homebrew/bin/uv \
  --directory /Users/am.will/Applications/blender_mcp/mcp \
  run blender-mcp

claude mcp add \
  --transport http \
  --scope project \
  unreal-mcp \
  http://127.0.0.1:8000/mcp
```

All Claude options must appear before the server name. For a stdio server, the `--` separator must appear between the MCP registration and the subprocess command.

The resulting `.mcp.json` should be equivalent to:

```json
{
  "mcpServers": {
    "blender-lab": {
      "type": "stdio",
      "command": "/opt/homebrew/bin/uv",
      "args": [
        "--directory",
        "/Users/am.will/Applications/blender_mcp/mcp",
        "run",
        "blender-mcp"
      ]
    },
    "unreal-mcp": {
      "type": "http",
      "url": "http://127.0.0.1:8000/mcp"
    }
  }
}
```

If `.mcp.json` already exists, merge these entries. Never replace unrelated entries.

Claude Code requires one-time approval for project-scoped MCP servers. Start an interactive session from the project root:

```bash
cd /Users/am.will/Applications/rl-opus5
claude
```

Approve the two reviewed project servers, then run:

```text
/mcp
```

Outside the interactive session, inspect them with:

```bash
claude mcp list
claude mcp get blender-lab
claude mcp get unreal-mcp
```

Do not report success merely because registration commands exited cleanly. Require connected status and a read-only tool call.

## 4. Read-only acceptance tests in Claude Code

Ask Claude to perform only these checks:

1. Use `blender-lab` to return the current blend-file path/status or datablock summary.
2. Use `unreal-mcp` to list toolsets.
3. Describe one Unreal toolset without calling a mutating tool.
4. Use Bash to fetch only the keys under TRELLIS's `/gradio_api/info`.

Expected Unreal MCP top-level tools when tool search is enabled:

```text
list_toolsets
describe_toolset
call_tool
```

Stop if the model attempts to:

- Execute arbitrary Blender Python.
- Call Unreal's `call_tool` on a mutating operation.
- Call TRELLIS `/image_to_3d`.
- Import a GLB.

Those are later production actions, not connection tests.

## 5. Give Claude access to TRELLIS

### Claude Code

Claude Code can already reach the Gradio API through Bash or a local Python helper, subject to normal tool approval. No MCP wrapper is required for schema inspection or a deliberately authorized one-off call.

API inspection example:

```bash
python3 -m venv /private/tmp/trellis-client-venv
/private/tmp/trellis-client-venv/bin/pip install gradio_client
/private/tmp/trellis-client-venv/bin/python -c 'from gradio_client import Client; Client("http://127.0.0.1:7860").view_api()'
```

The following is an eventual generation flow, not a setup test. Keep it as reference and do not run it until the user explicitly asks to build an asset:

```python
from gradio_client import Client, handle_file

client = Client("http://127.0.0.1:7860")
client.predict(api_name="/start_session")
client.predict(
    image=handle_file("/absolute/path/to/reference.png"),
    seed=0,
    resolution="1024",
    api_name="/image_to_3d",
)
result = client.predict(
    decimation_target=500000,
    texture_size=2048,
    api_name="/extract_glb",
)
print(result)
```

### Plain Claude Desktop chat

Do not add `http://127.0.0.1:7860` as a connector. It is not MCP.

If plain Claude Desktop chat—not Claude Code opened through the Desktop app—must operate TRELLIS, build or package a local stdio MCP bridge. The bridge should:

- Keep a Gradio client session alive for the duration of one job.
- Expose read-only `trellis_status` and `trellis_schema` tools.
- Expose a generation tool only after the user explicitly authorizes asset generation.
- Validate input image paths and write outputs only under an approved workspace directory.
- Bind or connect only through `127.0.0.1`.
- Never accept or log a Hugging Face token; the Linux service already has the weights.
- Return actionable errors when the SSH tunnel or remote process is down.

Register that future bridge as a local stdio MCP server. Do not pretend that bridge exists before it has been implemented and tested.

## 6. Claude Desktop options

### Recommended: Claude Code inside Claude Desktop

Run the project as a Claude Code task inside the Claude Desktop application. This is still running the workflow in Desktop. Its project `.mcp.json` supports Blender stdio and Unreal Streamable HTTP directly:

```json
{
  "mcpServers": {
    "blender-lab": {
      "type": "stdio",
      "command": "/opt/homebrew/bin/uv",
      "args": [
        "--directory",
        "/Users/am.will/Applications/blender_mcp/mcp",
        "run",
        "blender-mcp"
      ]
    },
    "unreal-mcp": {
      "type": "http",
      "url": "http://127.0.0.1:8000/mcp"
    }
  }
}
```

Put that `.mcp.json` in `/Users/am.will/Applications/rl-opus5`, open or reload a Claude Code task for that folder in Desktop, approve the project MCP servers, and inspect `/mcp`. It does not require a proxy for Unreal because Claude Code is running locally on the Mac.

### Regular Claude chat

The following applies only if the user specifically wants the ordinary chat surface, rather than Claude Code inside Desktop, to own the tools.

For plain Claude Desktop chat, the Blender stdio server can be merged into:

```text
/Users/am.will/Library/Application Support/Claude/claude_desktop_config.json
```

Use:

```json
{
  "mcpServers": {
    "blender-lab": {
      "type": "stdio",
      "command": "/opt/homebrew/bin/uv",
      "args": [
        "--directory",
        "/Users/am.will/Applications/blender_mcp/mcp",
        "run",
        "blender-mcp"
      ],
      "env": {}
    }
  }
}
```

Merge this object; never overwrite the entire file. Fully quit and reopen Claude Desktop, then inspect the connector/tool status.

Do not put Unreal's localhost URL into a **claude.ai account-level custom connector**: those remote connectors originate from Anthropic's cloud and cannot reach this Mac's `127.0.0.1`. That restriction does not apply to Claude Code running locally inside the Desktop app. If the user insists on the ordinary chat surface owning Unreal directly, use a reviewed local Desktop extension or stdio proxy.

Official references:

- [Local MCP servers in Claude Desktop](https://modelcontextprotocol.io/docs/develop/connect-local-servers)
- [Claude remote connector network requirements](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp)

## 7. Anthropic API setup for application code

Claude Code subscription authentication and the Anthropic API are separate concerns. An API key is needed only if this repository or another program will call the Claude Messages API directly.

Create the key in the Anthropic Console. Do not paste it into this document or any tracked file.

For an interactive shell:

```bash
export ANTHROPIC_API_KEY='set-this-outside-the-repository'
```

For the current TypeScript project, the official SDK would be:

```bash
npm install @anthropic-ai/sdk
```

Minimal server-side example:

```ts
import Anthropic from "@anthropic-ai/sdk";

const client = new Anthropic({
  apiKey: process.env.ANTHROPIC_API_KEY,
});
```

Never expose this key in browser-side Vite code. Keep Claude API calls on a server or trusted local process. Store long-lived secrets in macOS Keychain, 1Password, or another secret manager; use environment injection at runtime.

Official references:

- [Claude API authentication](https://platform.claude.com/docs/en/manage-claude/authentication)
- [Anthropic TypeScript SDK](https://platform.claude.com/docs/en/cli-sdks-libraries/sdks/typescript)

## 8. Security and operational rules

- Keep Unreal, Blender, and TRELLIS bound to loopback only.
- Never use Gradio `share=True` for this stack.
- Never change the Unreal MCP host to `0.0.0.0`; it has no authentication layer and Epic documents it as local-only.
- Treat Blender `execute_blender_code` as arbitrary code execution inside the user's Blender process.
- Treat Unreal `call_tool` as potentially mutating the open project.
- Use version control or Unreal Sandboxes before any later mutation pass.
- The Unreal MCP feature is experimental; APIs and data formats may change.
- During setup, Unreal displayed an EULA/data-use warning for content sent to a connected LLM. Before sending proprietary project data, confirm the user's Anthropic organization data controls and the applicable Unreal Engine license terms.
- Preserve `/Users/Shared/Epic Games/UE_5.8` as the active engine. The external copy at `/Volumes/Mac Extended/ExternalStorage/Applications/UE_5.8` is a backup, not the launch target.
- Do not delete the internal UE installation after a successful endpoint check.
- Do not print or move Hugging Face, Anthropic, Onshape, or other existing credentials.

## 9. Troubleshooting

### Claude Code is signed out

```bash
claude auth login --claudeai
claude auth status
```

### Project MCP is pending approval

Run `claude` from the project root, approve the reviewed `.mcp.json`, and use `/mcp`. To revisit prior choices:

```bash
claude mcp reset-project-choices
```

### Blender MCP fails

1. Confirm Blender is running.
2. Confirm `127.0.0.1:9876` is listening.
3. Confirm the official extension is enabled and auto-started.
4. Run the server command manually and inspect stderr.
5. Run `claude --debug mcp` if Claude still reports a connection failure.

### Unreal MCP fails

1. Confirm the editor is running from `/Users/Shared/Epic Games/UE_5.8`.
2. Confirm port `8000` is listening.
3. Check Unreal Output Log for `LogModelContextProtocol`.
4. Run `ModelContextProtocol.StartServer 8000`.
5. Run `ModelContextProtocol.RefreshTools`.
6. Reconnect Claude.

### TRELLIS UI is unreachable

1. Confirm the remote process is listening on Linux port `7860`.
2. Inspect `/home/amwill/AI/TRELLIS.2/trellis-gradio.log`.
3. Confirm the Mac SSH tunnel is listening locally.
4. Recreate only the missing process or tunnel.
5. Keep `OPENCV_IO_ENABLE_OPENEXR=1` in the remote launch environment.

### Port collision

Do not kill an unknown process. Resolve the listener first:

```bash
lsof -nP -iTCP:7860 -iTCP:8000 -iTCP:9876 -sTCP:LISTEN
```

Then decide whether it is the expected service.

## 10. Final report format for the next agent

Report each component separately:

```text
Claude auth: connected/not connected; method
Blender MCP: connected/not connected; read-only tool used
Unreal MCP: connected/not connected; toolsets visible
TRELLIS API: reachable/not reachable; schema-only check used
Claude Desktop: unchanged/configured; exact mode
Secrets written to repo: no
Assets generated or modified: no
Remaining blocker: none or exact evidence
```

Do not use “everything works” unless every acceptance item has direct evidence.
