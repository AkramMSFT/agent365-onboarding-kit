---
name: add-lab-tools
description: >
  Adds local utility tools to an Agent 365 agent -- web fetch and page summarise, text
  encoders/decoders (base64, hex, url, rot13), hashing (md5/sha1/sha256/sha512), and text
  transforms (case, regex extract, counts). These are plain in-process function tools, not
  Work IQ MCP servers: no Entra consent, no tokens, no tenant setup. Use when the user says
  "add lab tools", "add a URL fetch tool", "let the agent summarise web pages", "add
  encoders", or wants utility/red-team capabilities beyond the built-in and Work IQ tools.
  Supports Python, Node.js and .NET. Kit add-on, not part of Microsoft's skills.
compatibility:
  - claude-code
  - vscode-copilot
  - github-copilot-cli
user-invocable: true
argument-hint: "Optional: which groups -- web | encoding | text | all (default all)"
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, AskUserQuestion
model: sonnet
hooks:
  preToolUse:
    - type: command
      command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/preToolUse/path-guard.js"
      timeout: 5000
  stop:
    - type: command
      command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/stop/validate-add-lab-tools.js"
      timeout: 15000
---

# Add lab tools

> **Trigger phrases:**
> - "add lab tools"
> - "add a URL fetch tool" / "let the agent summarise web pages"
> - "add encoders" / "add hashing tools"
> - "add text utility tools"

> **This is a kit add-on**, and its tools are **dual-use**. `fetch_url` in particular is
> real network-egress surface and the classic prompt-injection / data-exfil vector -- which
> is exactly why it is useful for exercising Defender and Purview detection on a tenant you
> control. Add it only to agents you operate, for testing you are authorised to run. It is
> not part of Microsoft's seven skills.

## What it adds

Plain in-process `@function_tool` (Python) / equivalent tools. **No** MCP server, Entra consent, token exchange or tenant setup -- unlike `add-workiq-tools`, these are just code the model can call.

| Group | Tools |
|---|---|
| **web** | `fetch_url`, `summarize_url_content` |
| **encoding** | `encode_text`, `decode_text` (base64, base64url, hex, url, rot13), `hash_text` (md5/sha1/sha256/sha512) |
| **text** | `transform_text`, `count_text`, `regex_extract` |

## Phase 0 -- Detect and confirm

1. **Read** `.a365-workspace-detection.local.json` for `programmingLanguage`. If absent, detect from project files (`requirements.txt`/`pyproject.toml` → Python, `package.json` → Node.js, `.csproj` → .NET).
2. Find the agent's tool list -- the file and the array passed as `tools=[...]` (Python/OpenAI Agents SDK), `tools: [...]` (Node.js), or the equivalent registration (.NET). This is usually the file the onboarding skills already edited (`src/agent.py` in the verified project).
3. **Ask which groups** (AskUserQuestion) unless the argument already says: `web`, `encoding`, `text`, or `all`. If `web` is chosen, state plainly in the same prompt: *"`fetch_url` lets the agent retrieve arbitrary http/https URLs. Add it only for an agent you operate and testing you're authorised to run."*

## Phase 1 -- Add the tools

**Read** the reference for the language and follow it exactly:

- Python: `.a365-kit/addons/add-lab-tools/references/python-lab-tools.md`
- Node.js: `.a365-kit/addons/add-lab-tools/references/nodejs-lab-tools.md`
- .NET: `.a365-kit/addons/add-lab-tools/references/dotnet-lab-tools.md`

Rules, every language:

- Put the tools in a **new module** (`src/lab_tools.py`, `src/labTools.ts`, `LabTools.cs`); do not inline them into the file the onboarding skills own.
- Import that module's tool list into the agent and **append** to the existing tools -- never replace the built-in or Work IQ tools.
- If the user chose specific groups, include only those; keep the module structured so groups can be added later.
- Add one line to the agent's **instructions** naming the new tools, or the model may not use them (the same lesson as Work IQ: a tool the prompt never mentions often goes unused).
- `fetch_url` must be capped: http/https only, a timeout, a response-size limit, bounded redirects. The reference has the exact guards. Do **not** silently add private-IP/SSRF blocking unless the user asks -- in a security lab that surface is often the point -- but say in one line that it is unguarded so the choice is explicit.

## Phase 2 -- Verify

1. Import/build check: the agent module still loads (`python -c "import src.agent"`, `npm run build`, `dotnet build`).
2. Confirm the tool count went up and the built-in/Work IQ tools are still present -- list the tool names back to the user.
3. Run the validator: `node .a365-kit/hooks/stop/validate-add-lab-tools.js`.
4. If the agent is hosted, restart it -- a running process will not pick up new tools until it does (Python does not hot-reload).

## Phase 3 -- Note the security posture

Tell the user, briefly:

- These tools run **in-process as the agent**, not through Work IQ or Entra, so Agent 365's per-tool permission model does not gate them. Governance for what they do (especially `fetch_url` egress and any content they pull in) comes from Purview DLP on the turn and from Defender -- which is a good reason to pair this with `add-purview-dlp`.
- `fetch_url` returning attacker-controlled page content into the model is a prompt-injection surface. That is intended for testing; in a real deployment, treat fetched content as untrusted.

## Summary to show the user

```
Module      <path>   groups: <web|encoding|text>
Agent       tools <before> -> <after>   (built-in + Work IQ preserved)
Instructions updated: yes
Verified    import/build OK; validator ok
Posture     in-process (not Entra-gated); pair with add-purview-dlp; fetch_url is egress surface
Next        restart the host if it is running
```
