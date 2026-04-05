# Architecture

## Purpose

This project bridges OpenClaw to Claude Code CLI through a local Anthropic Messages-compatible proxy.

The goal is not just to forward requests. The goal is to preserve OpenClaw as the orchestration layer while using Claude Code CLI as the execution/runtime engine.

That means the system must satisfy both of these constraints:

1. OpenClaw must remain authoritative for startup context, memory loading, tool policy, and session semantics.
2. Claude Code CLI must remain authoritative for its internal session state, tool execution, and upstream request assembly.

The proxy exists to normalize between those two layers.

## Current Components

### OpenClaw

OpenClaw is the conversation owner.

It is responsible for:

- user/channel interaction
- agent orchestration
- memory file conventions
- startup and reset semantics
- tool availability policy
- provider selection

### Proxy

The proxy is the compatibility boundary.

It is responsible for:

- accepting Anthropic Messages-style requests from OpenClaw
- mapping OpenClaw conversation identity to Claude session identity
- normalizing messages before handing them to Claude Code CLI
- preserving token efficiency where safe
- stripping incompatible metadata when required

### Claude Code CLI

Claude Code CLI is the Claude runtime.

It is responsible for:

- executing the active Claude session
- tool invocation inside Claude Code
- upstream request construction
- Claude-side caching behavior
- Claude-side session continuity

## Core Design Principle

OpenClaw should be able to inject required context through a simple API contract.

However, Claude Code CLI is not a dumb transport. It maintains its own session model and request assembly behavior.

Therefore the proxy must follow this rule:

- OpenClaw-owned context must be preserved at startup and reset boundaries.
- Claude-owned session continuity should be used for ordinary continuation turns.

If the proxy leans too hard toward replaying everything, token cost grows.
If the proxy leans too hard toward Claude resume only, OpenClaw loses deterministic control of context.

## Current Request Modes

### Bootstrap

Bootstrap is used when no reusable Claude session is available.

Current behavior:

- the proxy synthesizes a single user message
- it includes:
  - system instructions
  - bridge/tool notice
  - prior conversation transcript
  - current user message

Advantages:

- OpenClaw context is reasserted
- robust against missing Claude session state

Disadvantages:

- expensive in tokens
- conversation replay cost grows with history length

### Resume

Resume is used when the proxy has a stored Claude session id for the conversation lookup key.

Current behavior:

- the proxy sends only the latest sanitized user turn
- the proxy passes Claude `session_id`

Advantages:

- low token cost
- efficient continued conversation

Disadvantages:

- relies on Claude-side continuity
- OpenClaw context is not automatically restated every turn
- if startup/reset semantics are not handled explicitly, context can appear to vanish

## Known Failure Modes

### 1. Foreign cache metadata crossing the boundary

OpenClaw can send structured content blocks with cache metadata.

Claude Code CLI also has its own upstream request behavior.

If the proxy forwards foreign cache metadata in resume mode, Anthropic request validation can fail.

This was the cause of the observed cache ordering error.

Required rule:

- resume mode must sanitize incoming content and strip foreign block metadata such as `cache_control`

### 2. Session continuity without startup reinjection

When resume works, only the new user turn is sent.

This is good for tokens, but it means OpenClaw does not automatically restate:

- memory loading instructions
- persona overrides
- required startup files
- active task context

If OpenClaw emits a new/reset boundary and does not explicitly reintroduce those instructions, the assistant will behave like a fresh session.

### 3. Fresh/reset turns treated like ordinary continuation

OpenClaw can semantically start a fresh session even if the proxy still has Claude session mappings.

If the boundary is not detected correctly, the system can resume a Claude session but still receive a reset-style instruction from OpenClaw.

That creates mismatch between:

- Claude session continuity
- OpenClaw conversation semantics

## Target Architecture

### Responsibility Split

#### OpenClaw owns

- startup sequence
- reset/new-session sequence
- required memory file reads
- persona and behavioral overrides
- workspace-specific context policy
- conversation identity

#### Proxy owns

- session lookup and mapping
- message normalization
- resume vs bootstrap choice
- safe transport into Claude Code CLI
- stripping incompatible metadata

#### Claude Code CLI owns

- actual Claude session execution
- Claude tool usage
- Claude-side internal state
- upstream request generation

## Required Behavioral Rules

### Rule 1: Ordinary continuation should resume

For ordinary continuation turns:

- use Claude `session_id`
- send only the new sanitized user turn
- do not replay full conversation history

### Rule 2: Startup and reset should bootstrap intentionally

For startup/reset/new-session turns:

- do not rely on plain resume alone
- explicitly inject OpenClaw-owned startup context
- explicitly instruct the agent to read required memory files
- rebuild a bootstrap-style request when needed

### Rule 3: Memory files should be loaded by instruction, not pasted every turn

Persistent memory should not be inlined into every request.

Instead:

- OpenClaw should instruct the agent to read required files at startup/reset
- the agent should read those files through tools
- resumed turns should remain lean

This preserves both:

- low token burn
- deterministic context recovery

### Rule 4: Resume sanitization is mandatory

Resume mode should preserve only what Claude Code CLI safely accepts.

Allowed:

- plain text content

Disallowed across the boundary unless proven safe:

- OpenClaw cache metadata
- upstream-specific block annotations
- foreign tool metadata
- any structure that Claude Code CLI does not explicitly require for resumed user turns

## Required OpenClaw Behavior

For this integration to work correctly, OpenClaw must distinguish between two classes of turns.

### Continuation turn

Characteristics:

- same conversation
- no reset/new semantics
- no need to reload baseline context

Desired proxy behavior:

- resume

### Startup/reset turn

Characteristics:

- `/new`
- `/reset`
- channel startup
- agent restart where baseline context must be restored

Desired proxy behavior:

- bootstrap with explicit OpenClaw-authored startup context

## Memory Strategy

### Long-term memory

Examples:

- user preferences
- project conventions
- recurring operational facts

Load policy:

- read on startup/reset
- not every ordinary turn

### Working memory

Examples:

- current objective
- active blockers
- latest decisions
- next planned steps

Load policy:

- read on startup/reset
- refresh when task changes materially

### Live conversational context

Examples:

- recent turn-by-turn discussion
- active tool state
- immediate execution context

Load policy:

- rely on Claude session resume

## Implementation Direction

The next implementation pass should do the following.

## Implementation Checklist

### Phase 1: Proxy boundary correctness

- [x] Sanitize resumed user content so foreign cache metadata does not cross into Claude Code CLI.
- [ ] Detect OpenClaw startup/reset turns explicitly.
- [ ] Force bootstrap on startup/reset turns even when a reusable Claude session mapping exists.
- [ ] Keep ordinary continuation turns on resume.
- [ ] Log the selected request mode clearly enough to distinguish ordinary bootstrap from forced startup/reset bootstrap.

### Phase 2: OpenClaw-owned context restoration

- [ ] Ensure OpenClaw emits a deterministic startup/reset instruction when baseline context must be restored.
- [ ] Ensure that startup/reset instruction tells the agent which memory files to read.
- [ ] Keep memory loading file-oriented rather than pasting memory text into each request.
- [ ] Verify that reset/new-session turns restore context without replaying full conversation history on every ordinary turn.

### Phase 3: Operational reliability

- [ ] Keep the installed runtime copy in sync with the repo copy after proxy changes.
- [ ] Verify the managed service restarts cleanly and continues listening on the configured port.
- [ ] Validate recent requests in the debug log to confirm startup/reset turns now bootstrap instead of resume.
- [ ] Confirm ordinary continuation turns still resume and remain token-efficient.

### Proxy changes

1. Keep resume sanitization for latest user turn.
2. Add an explicit notion of startup/reset boundary handling.
3. On startup/reset boundaries, force bootstrap even if a Claude session mapping exists.
4. Preserve ordinary continuation resume for token efficiency.

### OpenClaw changes

1. Define a stable startup sequence.
2. Explicitly instruct agents which memory files to read.
3. Ensure reset/new-session messages are deliberate and not emitted accidentally.
4. Keep startup context short and file-oriented rather than transcript-heavy.

## Success Criteria

The architecture is working correctly when all of the following are true.

1. Ordinary continued conversations are cheap and use resume.
2. Startup/reset turns reliably restore OpenClaw-owned context.
3. Memory files are read when needed without being pasted into every request.
4. Persona and required context remain under OpenClaw control.
5. Foreign cache metadata does not reach Claude Code CLI resume requests.
6. Users do not experience unexpected “fresh slate” behavior except on true resets.

## Non-Goals

This project is not trying to:

- replace OpenClaw with Claude Code CLI
- turn Claude Code CLI into a raw Anthropic pass-through transport
- inline all memory into every request
- preserve every OpenClaw-specific message block exactly as-is across the proxy boundary

## Summary

The correct system is a hybrid:

- OpenClaw owns context policy
- the proxy owns compatibility and session mapping
- Claude Code CLI owns execution runtime

Token optimization should apply to ordinary continuation turns.
Context restoration should apply to startup and reset turns.

Those must be treated differently.