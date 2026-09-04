---
name: a365-kit
description: >
  Maintains the Agent 365 Onboarding Kit itself from inside your coding CLI: check
  prerequisites, report the installed kit and upstream versions, update the kit in place
  (only the kit's own files are replaced), and set where updates come from -- the public
  release or your organisation's own mirror. Use when the user says "update the Agent 365
  kit", "check kit prerequisites", "which kit version is this", "set the kit update source",
  or when the session-start notice says a newer version is available. Kit add-on.
compatibility:
  - claude-code
  - vscode-copilot
  - github-copilot-cli
user-invocable: true
argument-hint: "Optional: update | doctor | version | source <url-or-path>"
allowed-tools: Read, Bash, AskUserQuestion
model: sonnet
hooks:
  preToolUse:
    - type: command
      command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/preToolUse/path-guard.js"
      timeout: 5000
---

# Maintain the Agent 365 Onboarding Kit

> **Trigger phrases:**
> - "update the Agent 365 kit"
> - "check the kit prerequisites"
> - "which kit version is installed"
> - "set the kit update source to <url or path>"
> - "use our internal mirror for kit updates"

The kit ships two equivalent launchers at the project root: `agent365-kit.ps1` (Windows) and `agent365-kit.sh` (macOS / Linux). Everything below is a call to one of them. Pick by platform; on Windows prefer PowerShell even from a bash-flavoured CLI shell (`pwsh -File .\agent365-kit.ps1 ...`).

None of these steps needs the Windows broker or a separate terminal -- run them directly.

## Which operation?

If the user's request is unambiguous, do it. Otherwise ask once:

> What would you like to do with the kit?
> 1. **Update** to the latest release (kit files only; your agent is untouched)
> 2. **Check prerequisites** (doctor)
> 3. **Show versions** (installed kit, bundled upstream, latest upstream)
> 4. **Set the update source** (public release, or your own mirror / file share)

## 1. Update

```bash
# Windows                          # macOS / Linux
.\agent365-kit.ps1 -Update         ./agent365-kit.sh --update
```

The launcher prints the source it resolved and where that came from (`-UpdateFrom` > `A365_KIT_UPDATE_SOURCE` > `a365-kit.config.json` > build default > public release). It replaces **only** `.a365-kit/`, the kit's own skill folders in `.claude/skills/` and `.agents/skills/`, the launchers and `AGENT365-KIT-README.md`. The user's agent, `.env`, `a365.*.json`, `.claude/settings.json` and any skill they added themselves are never touched.

Afterwards:

1. **Read** `.a365-kit/KIT-VERSION.json` and report `kitVersion`, `upstreamVersion`, `upstreamCommit`, and whether the `addons` list changed.
2. Tell the user their CLI may need a restart or a reload to pick up changed skills.
3. If `git status` shows the kit paths as modified in a repository, suggest committing them so teammates get the same kit.

To update from a specific file or URL just once (a build you are testing, or a download you already have):

```bash
.\agent365-kit.ps1 -Update -UpdateFrom <zip-or-url>      ./agent365-kit.sh --update --update-from <zip-or-url>
```

## 2. Check prerequisites

```bash
.\agent365-kit.ps1 -DoctorOnly                           ./agent365-kit.sh --doctor-only
```

Relay the table. For anything marked `MISS`, offer to run the install command it printed, then remind the user to open a new terminal before re-checking -- PATH changes do not reach an existing shell.

## 3. Show versions

**Read** `.a365-kit/KIT-VERSION.json`. Then, if `gh` is available:

```bash
gh release view --repo microsoft/agent365-skills --json tagName -q .tagName
```

Report installed kit version, bundled upstream version and commit, latest upstream release, and the resolved update source (run the update step's resolution by calling the launcher with `-Update -UpdateFrom` **not** set and reading only its first "Source" line -- or simply state the resolution order and the config-file value if present).

## 4. Set the update source

For organisations that host the kit themselves (internal GitHub, artifact server, file share). Accept an HTTPS URL to a zip, or a filesystem path to a zip:

```bash
.\agent365-kit.ps1 -SetUpdateSource "https://git.corp.example/tools/agent365-kit/releases/latest/download/agent365-onboarding-kit-latest.zip"
./agent365-kit.sh --set-update-source "/mnt/tools/agent365-kit/agent365-onboarding-kit-latest.zip"
```

This writes `a365-kit.config.json` at the project root -- deliberately outside the paths an update replaces, so the setting survives updates. Tell the user to **commit that file** so the whole team updates from the same place. An empty string clears it and falls back to the build default.

Two other levels exist and you should mention them when relevant:

- `A365_KIT_UPDATE_SOURCE` environment variable -- per shell or CI job; overrides the config file.
- A default baked in at build time (`updateSource` in `KIT-VERSION.json`) -- for organisations that rebuild the kit for their mirror with `Build-Kit.ps1 -UpdateSource ...`.

## Summary to show the user

```
Kit          v<kitVersion>   upstream v<upstreamVersion> (<commit>)   add-ons: <list>
Source       <resolved source>   [<origin>]
Action       <what was done>
Next         <restart CLI to reload skills | commit kit paths | nothing>
```
