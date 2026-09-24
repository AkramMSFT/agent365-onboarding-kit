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
- A clone of this repository or the bundle zip, because the tool lives in `tools/`.
- The agent projects. Each needs the kit in its root, or the tool can copy it in with `--install-kit`.

## Steps

1. **Start herdr** in its own terminal and leave it open:

   ```bash
   herdr
   ```

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

   If a CLI stopped at a question before it received the request, such as a prompt to trust the folder, answer it in herdr and then send the request:

   ```bash
   node tools/bulk-onboard.mjs agents.txt --send-prompt
   ```

   The request is never sent twice to the same agent.

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

The tool has offline tests (`build/test-bulk-onboard.mjs`) that run against a stand-in for the herdr command line, built from the commands and API schema documented for herdr 0.9.1. It has not yet been run end to end against a live herdr session and tenant.
