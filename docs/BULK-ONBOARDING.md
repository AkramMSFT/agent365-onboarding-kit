# Onboarding several agents at once

The kit onboards one agent per CLI session. When you have several agents to onboard, you can run one session per agent side by side in [herdr](https://herdr.dev), an open-source terminal multiplexer built for coding agents. herdr shows which sessions are working, which are waiting for you, and which are done, so you can move to whichever one needs an answer.

This step is optional. Nothing else in the kit depends on it. The idea came from Gerard Salvador López.

## What stays the same

Running sessions in parallel saves waiting time, not decisions. Each onboarding still:

- asks you which capabilities to set up and how the agent authenticates
- asks before it runs anything that changes your tenant
- hands `a365 setup all` to you to run and sign in, as in the single-agent flow
- needs an administrator for consent and permission grants

herdr marks a session **blocked** when its CLI is showing a question or an approval, which is where your attention goes.

## Before you start

- The kit's usual prerequisites from the [README](../README.md#prerequisites).
- GitHub Copilot CLI or Claude Code, installed and signed in.
- herdr 0.9 or later. It runs natively on Windows, macOS and Linux:

  ```powershell
  powershell -ExecutionPolicy Bypass -c "irm https://herdr.dev/install.ps1 | iex"
  ```

  ```bash
  curl -fsSL https://herdr.dev/install.sh | sh
  ```

  herdr is a third-party tool under the Apache 2.0 licence. Check your organisation's policy before installing it on a managed machine.

  On a managed Windows PC the installer can fail with *Program 'herdr.exe' failed to run: Access is denied*. Microsoft Defender's attack surface reduction rule *Use advanced protection against ransomware* (`c1db55ab-c21a-4637-bb3f-a12568109d35`) blocks the new, unsigned executable, and Defender's operational log records it as event 1121. Ask your IT administrator for a per-rule exclusion for `%USERPROFILE%\.herdr\` and `%LOCALAPPDATA%\Programs\Herdr\` (see [Configure ASR rules and exclusions](https://learn.microsoft.com/en-us/defender-endpoint/attack-surface-reduction-rules-configure)), then run the installer again from a normal, non-administrator PowerShell window.
- A clone of this repository or the bundle zip, because the tool lives in `tools/`.
- The agent projects. Each needs the kit in its root, or the tool can copy it in with `--install-kit`.

## Steps

1. **Start herdr** in its own terminal and leave it open:

   ```bash
   herdr
   ```

   `herdr server` starts it without the interface instead. Attach later with `herdr`.

2. **List the agents** in a text file, one project folder per line. A short name can follow a comma; otherwise the folder name is used. Relative paths are relative to the file.

   ```text
   # agents.txt
   C:\src\hr-agent
   C:\src\expenses-agent, expenses
   ..\java-agent
   ```

3. **Check the plan** from the repository root. Nothing starts in a dry run.

   ```bash
   node tools/bulk-onboard.mjs agents.txt --dry-run
   ```

4. **Start the onboarding.** Each agent gets its own herdr workspace, a CLI session in its folder, and the request *Onboard this agent to Agent 365.*

   ```bash
   node tools/bulk-onboard.mjs agents.txt
   ```

   | Option | Effect |
   |---|---|
   | `--cli claude` | Start Claude Code instead of GitHub Copilot CLI |
   | `--install-kit` | Copy the kit into folders that do not have it yet. Existing files are never overwritten. |
   | `--prompt "…"` | Ask for something else, such as *Add observability to this agent.* |

5. **Work through the sessions** in herdr. Pick the blocked ones first and answer them. When a session reaches `a365 setup all`, the CLI asks you to run the command yourself. Split a pane in that agent's workspace, run it there and complete the sign-in, then tell the CLI it finished. If sign-in windows for several agents appear at once, run those setups one at a time.

6. **Check progress** whenever you like:

   ```bash
   node tools/bulk-onboard.mjs agents.txt --status
   ```

   GitHub Copilot CLI asks whether to trust each folder the first time it starts there, so expect every session to stop at that question once. Choose *Yes, and remember this folder* to skip it next time. After answering, send the request:

   ```bash
   node tools/bulk-onboard.mjs agents.txt --send-prompt
   ```

   The tool counts a request as sent only when herdr sees the CLI react to it within a few seconds. That matters when a CLI updates itself on first start: text typed during the update is lost, so the tool leaves the request unsent and `--send-prompt` delivers it later. A request is never sent twice to the same agent.

7. **Continue per agent.** Later steps work the same way as for a single agent. Type the next phrase in that agent's session, or send it from any terminal:

   ```bash
   herdr agent prompt hr-agent "Grant observability access to this agent."
   ```

## Good practice

- Start with two or three agents until the flow is familiar.
- Every session uses your CLI's model quota.
- Keep each agent's name and folder distinct. Each onboarding creates its own blueprint and identity.
- Keep secrets out of the agents file. It only holds folder paths and names.
- Progress is recorded in `.a365-bulk-onboard.json` next to the agents file. To start an agent over, close its workspace in herdr and remove its entry from that file.

## Verification

The tool has offline tests (`build/test-bulk-onboard.mjs`) against a stand-in for the herdr command line, built from the commands and API schema documented for herdr 0.9.1, and CI runs them on every push.

It has also run on Windows 11 with herdr 0.9.1 and GitHub Copilot CLI 1.0.89. Two agents started in parallel, each stopped at Copilot's folder trust question, and after that was answered each received its request and listed the kit's fifteen skills. A full onboarding through the tool, which is interactive and creates objects in a tenant, has not been run yet.
