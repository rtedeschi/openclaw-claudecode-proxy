# Architecture

## Purpose

This project bridges OpenClaw to Claude Code CLI through a local Anthropic Messages-compatible proxy, so OpenClaw traffic uses the operator's Claude Code subscription instead of direct API billing.

The proxy is small on purpose. Its entire job is to take an OpenClaw request, translate it into something the Claude CLI can execute, and translate the response back.

## Design goals

1. OpenClaw remains authoritative for conversation history, memory conventions, persona, tool policy, and provider selection.
2. Claude Code CLI remains the execution runtime that actually talks to Anthropic and runs tools.
3. The proxy is a thin but stateful compatibility layer. It composes each request deterministically from OpenClaw-owned state.
4. Requests handed to Claude Code should look like things a real operator would type, not like pipeline-generated scaffolding.

## Components

### OpenClaw

Conversation owner. Responsible for:
- user/channel interaction
- agent orchestration
- memory file conventions (`MEMORY.md`, `memory/YYYY-MM-DD.md`)
- session transcript persistence (`~/.openclaw/agents/<agent>/sessions/<uuid>.jsonl`)
- persona/SOUL configuration
- provider routing

### Proxy

Compatibility + context-composition boundary. Responsible for:
- accepting `POST /v1/messages` from OpenClaw
- composing a per-turn prompt package from OpenClaw-owned sources
- spawning the `claude` CLI child process
- translating its streaming output back to Anthropic Messages SSE / JSON
- applying human-pacing jitter so request cadence isn't metronomic
- mapping model IDs (stripping provider prefixes, preserving concrete versions)

### Claude Code CLI

Execution runtime. Responsible for:
- upstream Anthropic request execution
- running tools within its full default surface (Read, Edit, Write, Bash, Grep, Glob, WebFetch, WebSearch, Task, TodoWrite, NotebookEdit, etc.)
- any incidental prompt-caching the vendor applies

The proxy does not restrict CC's tool surface beyond disabling Gmail/Calendar OAuth flows that are not wired up through this bridge.

## Request composition

Each request is assembled from:

1. OpenClaw's system prompt (passed through verbatim; not labelled).
2. A short bridge notice mentioning the Gmail/Calendar exclusion.
3. A one-sentence memory-answering nudge (use memory as background, answer what was asked).
4. A prose orientation paragraph: where the workspace is, where MEMORY.md lives, how many daily notes exist, which recent ones exist.
5. A memory digest: excerpts from `MEMORY.md` and today's daily note, with a short list of other recent daily-note filenames (reachable via the `Read` tool on demand).
6. Optional startup turn note when OpenClaw flags a `/new` or `/reset` turn.
7. Recent conversation tail: prefer the on-disk OpenClaw session transcript (`sessions/*.jsonl`); fall back to the in-request `messages` array when no transcript is available.
8. The current user message, trailing, without a banner label.

All labels and ceremony that used to look machine-generated ("System instructions:", "Required startup memory loading:", "Memory digest inventory:", "ALL-CAPS role prefixes") have been removed or rewritten as prose.

## Continuity model

The proxy does not rely on Claude `session_id` resume for ordinary continuation. Two reasons:

1. Resume proved fragile across OpenClaw's own startup/reset boundaries.
2. The on-disk OpenClaw transcript (`sessions/<uuid>.jsonl`) is a better source of truth anyway; it includes every turn and tool call, not just what CC happened to cache.

So instead the proxy reads the most recently modified transcript file under `~/.openclaw/agents/<agent>/sessions/` and uses its tail (bounded by `MAX_CONTEXT_MESSAGES`) as the conversation-context block for this turn. OpenClaw serializes requests per session, so "most recently modified" reliably picks the right file in practice.

When no transcript is available (proxy used by a non-OpenClaw Anthropic client), the in-request `messages` array is used as the fallback.

## Tunable bounds

All context bounds are env-overridable so operators can adjust without a redeploy:

| Env var | Default | Meaning |
|---------|---------|---------|
| `OC_PROXY_MAX_CONTEXT_MESSAGES` | 30 | Size of the conversation-tail window |
| `OC_PROXY_MAX_CONTEXT_CHARS_PER_MESSAGE` | 6000 | Per-message truncation |
| `OC_PROXY_MAX_MEMORY_EXCERPT_CHARS` | 20000 | `MEMORY.md` excerpt size |
| `OC_PROXY_MAX_DAILY_EXCERPT_CHARS` | 8000 | Today's daily-note excerpt size |
| `OC_PROXY_MAX_RECENT_MEMORY_FILES` | 5 | How many recent daily-note basenames to mention |
| `OC_PROXY_JITTER_MIN_MS` | 200 | Min pacing delay per request |
| `OC_PROXY_JITTER_MAX_MS` | 1200 | Max pacing delay per request |
| `OC_PROXY_MIN_SPACING_MS` | 800 | Minimum spacing between consecutive spawns |

Set jitter/spacing to 0 to disable the human-pacing behavior when strict throughput matters.

## Model handling

The proxy maps whatever OpenClaw asks for to the concrete model id that Claude Code expects:

- Strip any provider prefix (`claude-code-proxy/`, `anthropic/`, etc.) before handing to CC.
- Pass through `opus`/`sonnet`/`haiku` aliases verbatim (CC resolves them to latest).
- Pass through concrete versions unchanged (`claude-opus-4-5`, `claude-opus-4-6`, `claude-opus-4-7`, `claude-sonnet-4-5`, `claude-sonnet-4-6`). No silent rewrites.
- Default when nothing is specified: `claude-opus-4-7`.

Registered models (written to `agents.defaults.models` on install):

- `claude-code-proxy/claude-opus-4-7` (alias `popus`)
- `claude-code-proxy/claude-opus-4-6`
- `claude-code-proxy/claude-opus-4-5`
- `claude-code-proxy/claude-sonnet-4-6` (alias `psonnet`)
- `claude-code-proxy/claude-sonnet-4-5`

The `p*` aliases exist because OpenClaw itself ships an `opus` alias pointing at the direct-API `anthropic/claude-opus-4-7`; a proxy alias of the same name would collide silently.

## Tool surface

The child `claude` process is spawned with `--dangerously-skip-permissions` and no `--tools` restriction. That means:

- Full default CC tool set is available: Read, Edit, Write, Bash, Grep, Glob, WebFetch, WebSearch, Task, TodoWrite, NotebookEdit, etc.
- `Bash` is live: operators can sshpass into other hosts, run docker/rsync/git, inspect the system, etc.
- Only Gmail and Google Calendar OAuth tools are explicitly disallowed because their auth flows don't survive the proxy bridge.

The proxy does not expose OpenClaw-native tools (cron, canvas, nodes, browser, etc.) into the CC session. Those remain OpenClaw-owned; CC is the execution runtime, not a full OpenClaw replacement.

## What the proxy is not

- It is not a transparent pass-through. It rewrites the outer prompt shape.
- It is not trying to minimize tokens at all costs. Deterministic continuity matters more.
- It is not using Claude session resume as the primary continuity mechanism.
- It is not attempting to hide that it's a proxy; it just stops announcing itself in every request body.

## Failure modes to watch

1. Transcript selection picking the wrong session file when multiple agents are active. (Current mitigation: latest-mtime under the default agent. Better fix: have OpenClaw send an explicit session UUID header.)
2. Memory digest drifting too large if `MAX_MEMORY_EXCERPT_CHARS` grows unbounded.
3. `Bash` misuse because the proxy doesn't gate it; operators should trust the source of their own OpenClaw sessions.
4. Pacing jitter aggregating into visible latency under high request volume; disable by setting `OC_PROXY_MIN_SPACING_MS=0` if needed.

## Summary

- OpenClaw owns context policy and history.
- The proxy assembles a deterministic, human-shaped request package each turn.
- Claude Code executes that package with its full default tool surface.
- Continuity comes from reading OpenClaw's on-disk transcripts, not from hoping CC retained session state.
