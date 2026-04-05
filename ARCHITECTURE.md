# Architecture

## Purpose

This project bridges OpenClaw to Claude Code CLI through a local Anthropic Messages-compatible proxy.

The proxy is not just a transport shim. It is the boundary that makes OpenClaw's context model usable through Claude Code CLI without depending on Claude session continuity to preserve memory and task state.

The current design is intentionally stateless per turn.

That is the key architectural decision.

## Design Goal

The system should satisfy these constraints:

1. OpenClaw remains authoritative for conversation history, startup semantics, memory conventions, and tool policy.
2. Claude Code CLI remains the execution/runtime engine that actually talks to Anthropic and runs tools.
3. The proxy should compose each turn deterministically from OpenClaw-owned context instead of relying on Claude-side resumed session state.

## Current Components

### OpenClaw

OpenClaw is the conversation owner.

It is responsible for:

- user and channel interaction
- agent orchestration
- memory file conventions
- startup and reset semantics
- provider selection
- conversation history

### Proxy

The proxy is the compatibility and context-composition boundary.

It is responsible for:

- accepting Anthropic Messages-style requests from OpenClaw
- normalizing those requests for Claude Code CLI
- composing a deterministic per-turn prompt package
- injecting memory inventory and memory excerpts
- limiting tool exposure to the bridge allowlist
- keeping the request shape stable across platforms

### Claude Code CLI

Claude Code CLI is the Claude runtime.

It is responsible for:

- upstream request execution
- Claude-side tool invocation
- model runtime behavior
- any provider-side prompt caching Anthropic decides to apply

Claude Code CLI is no longer treated as the source of truth for continuity.

## Why The Architecture Changed

The earlier design used a hybrid model:

- bootstrap when no reusable Claude session was available
- resume with Claude `session_id` for ordinary turns

That design failed in practice for this integration.

Observed failure modes:

1. A startup or memory-loading turn could work once, then the next resumed turn would behave as if memory had vanished.
2. Memory-oriented turns could overcorrect and dump large memory summaries repeatedly instead of answering the current question.
3. Startup/reset semantics from OpenClaw could drift out of alignment with Claude's internal session continuity.
4. Subtle wording changes in the user prompt changed whether the proxy chose bootstrap or resume.

The result was a system that was efficient when it worked and unreliable when it mattered.

That tradeoff was not acceptable.

## Current Request Model

### Stateless Per-Turn Composition

Every OpenClaw turn now becomes a fresh Claude Code request.

The proxy does not rely on a prior Claude `session_id` to preserve continuity for ordinary conversation.

Each translated request includes:

1. system instructions from OpenClaw
2. proxy tool-bridge rules
3. response-shaping rules to reduce context dumping
4. a host-verified memory inventory
5. a deterministic memory digest
6. a bounded recent-conversation window
7. the current user message

The live request modes are now:

- `stateless`
- `stateless-startup`

These modes differ only in whether startup-specific instructions are added.

### Memory Inventory

The proxy inspects the filesystem directly and injects facts such as:

- whether `~/.openclaw/workspace/MEMORY.md` exists
- whether today's daily note exists
- how many markdown memory files exist
- the most recent observed daily memory files

This removes ambiguity where the model might otherwise claim no daily files exist when they are present on disk.

### Memory Digest

The proxy builds a deterministic digest from OpenClaw-owned memory files.

Current sources:

- `~/.openclaw/workspace/MEMORY.md`
- today's daily note if present
- a short list of recent daily note paths

The proxy includes excerpts rather than asking Claude to discover everything through tool calls on each turn.

This trades some token cost for deterministic continuity.

### Recent Conversation Window

The proxy includes only a bounded slice of recent conversation rather than the full historical transcript.

Current implementation:

- last 8 prior messages
- each message truncated to a maximum character budget

This is a deliberate compromise:

- enough local context for conversational continuity
- not enough accumulated transcript weight to dominate the current user question

## Core Principle

OpenClaw owns context policy.

The proxy owns context packaging.

Claude Code CLI executes the packaged request.

That means continuity should come from deterministic reconstruction, not from hoping Claude retained the right state from an earlier turn.

## Current Behavioral Rules

### Rule 1: Every turn is reconstructible

The proxy must be able to reconstruct enough context for the current turn without relying on prior Claude session state.

### Rule 2: Memory is background, not the answer

The request explicitly tells Claude to use memory digest and recent context as background information.

It should answer the current user message directly, not restate the digest unless asked.

### Rule 3: Startup is explicit but not fundamentally different

Startup and reset turns still matter, but they now travel through the same stateless composition path.

The only difference is an added startup instruction block telling Claude to perform startup behavior using the supplied digest and recent context.

### Rule 4: Conversation context must be bounded

Full history replay on every turn is not the design target.

The proxy should provide only enough recent context to support the current response.

### Rule 5: Filesystem truth beats model inference

If the host can verify a memory file exists, the prompt should state that fact directly.

The model should not have to infer filesystem reality from weak hints.

## Responsibility Split

### OpenClaw owns

- startup and reset semantics
- high-level conversation history
- workspace and memory conventions
- persona and behavioral policy
- provider routing

### Proxy owns

- request normalization
- stateless prompt composition
- memory inventory generation
- memory digest generation
- recent-context windowing
- tool bridge restrictions
- debug logging of the translated request mode

### Claude Code CLI owns

- Claude execution
- tool running within the allowed bridge
- upstream Anthropic request behavior
- any incidental provider-side caching

## Prompt Assembly Shape

Conceptually, each translated turn is assembled like this:

1. `System instructions`
2. `Proxy tool rules`
3. `Response rules`
4. `Memory-answering rules`
5. `Memory inventory`
6. `Memory digest`
7. `Recent conversation context`
8. `Current user message`

This shape is deterministic and does not depend on Claude-side hidden state.

## Caching Expectations

Anthropic or Claude Code may still apply prompt caching to repeated prefixes.

However, the architecture does not depend on that behavior.

Required mental model:

- caching is an optimization bonus
- deterministic context reconstruction is the actual continuity mechanism

## Known Tradeoffs

### Advantages

- continuity no longer depends on Claude resume behavior
- startup and reset are easier to reason about
- filesystem-backed memory loading is deterministic
- debugging is simpler because each turn's context is explicit in the translated request

### Costs

- higher token usage than pure resume
- some duplicated context across turns
- memory digests may need tuning to avoid over-answering or over-reciting

These costs are accepted because correctness is more important than absolute token minimization for this bridge.

## Current Failure Modes To Watch

Even with stateless composition, these risks remain:

1. The memory digest may still be too large or too dominant, causing recap-heavy answers.
2. The recent conversation window may include prior assistant memory dumps that bias the next answer.
3. Daily memory selection may need refinement if today's file is absent but a nearby recent file is more relevant.
4. The digest may eventually need structured extraction instead of raw excerpt inclusion.

These are prompt-composition problems, not continuity-loss problems.

That is progress, because they are deterministic and inspectable.

## Implementation Status

### Completed

- [x] Proxy no longer relies on Claude resume for normal continuation turns.
- [x] Startup/reset detection still exists, but now selects a stateless startup-flavored request shape.
- [x] Proxy injects a host-verified memory inventory.
- [x] Proxy injects a deterministic memory digest from long-term memory and today's daily note.
- [x] Proxy uses a bounded recent-conversation window.
- [x] Proxy includes explicit response-shaping rules to reduce context dumping.
- [x] Runtime copy and repo copy have been kept in sync.

### Outstanding Tuning Work

- [ ] Filter prior assistant memory dumps out of the recent-conversation window when they would bias the next answer.
- [ ] Replace raw file excerpts with a more compact structured memory digest if responses still over-recite context.
- [ ] Revisit excerpt size limits if token cost becomes too high.
- [ ] Update README if operator-facing documentation should describe the stateless mode explicitly.

## Success Criteria

The architecture is working correctly when all of the following are true:

1. A fresh turn can answer correctly without depending on hidden Claude session state.
2. Startup/reset behavior is reliable and does not create a false fresh-slate response.
3. The model can reference long-term and daily memory consistently.
4. The model answers the current question instead of re-dumping context by default.
5. Debug logs make the translated request shape understandable enough to diagnose future prompt-composition issues.

## Non-Goals

This project is not trying to:

- turn Claude Code CLI into a raw pass-through transport
- preserve OpenClaw's original request structure byte-for-byte
- minimize tokens at all costs
- rely on Claude session ids as the primary continuity mechanism
- inline the entire OpenClaw memory corpus on every turn

## Summary

The current system is no longer a resume-first hybrid.

It is a stateless per-turn bridge:

- OpenClaw owns context policy and history
- the proxy builds a deterministic request package
- Claude Code CLI executes that package

That is the current architecture because it is easier to reason about, easier to debug, and more reliable than relying on Claude-side continuity to preserve OpenClaw memory semantics.
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