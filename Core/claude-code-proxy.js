const http = require('http');
const { spawn } = require('child_process');
const fs = require('fs');
const crypto = require('crypto');
const os = require('os');
const path = require('path');

const PORT = process.env.PORT || 8787;
const TEMP_DIR = os.tmpdir();
const DEBUG_LOG = path.join(TEMP_DIR, 'claude-code-proxy-debug.log');
const SESSION_STATE_PATH = path.join(TEMP_DIR, 'claude-code-proxy-state.json');
const SESSION_TTL_MS = 6 * 60 * 60 * 1000;
const CLAUDE_ALLOWED_TOOLS = ['Read', 'Edit', 'Write', 'Bash', 'Grep', 'Glob', 'TodoWrite'];
const CLAUDE_DISALLOWED_TOOLS = [
    'mcp__claude_ai_Gmail__authenticate',
    'mcp__claude_ai_Google_Calendar__authenticate'
];

function isExpiredSession(entry, now = Date.now()) {
    if (!entry || typeof entry !== 'object') {
        return true;
    }

    if (typeof entry.updatedAt !== 'string' || !entry.updatedAt) {
        return true;
    }

    const updatedAtMs = Date.parse(entry.updatedAt);
    if (Number.isNaN(updatedAtMs)) {
        return true;
    }

    return now - updatedAtMs > SESSION_TTL_MS;
}

function pruneExpiredSessions(state, now = Date.now()) {
    const sessions = state && state.sessions && typeof state.sessions === 'object'
        ? state.sessions
        : {};
    const prunedSessions = {};
    let removedCount = 0;

    for (const [key, value] of Object.entries(sessions)) {
        if (isExpiredSession(value, now)) {
            removedCount += 1;
            continue;
        }

        prunedSessions[key] = value;
    }

    return {
        state: { sessions: prunedSessions },
        removedCount
    };
}

function loadSessionState() {
    try {
        const raw = fs.readFileSync(SESSION_STATE_PATH, 'utf8');
        const parsed = JSON.parse(raw);
        if (parsed && typeof parsed === 'object' && parsed.sessions && typeof parsed.sessions === 'object') {
            return pruneExpiredSessions(parsed).state;
        }
    } catch (error) {
        // Ignore missing or invalid state.
    }

    return { sessions: {} };
}

let sessionState = loadSessionState();

function persistSessionState() {
    try {
        sessionState = pruneExpiredSessions(sessionState).state;
        fs.writeFileSync(SESSION_STATE_PATH, JSON.stringify(sessionState, null, 2));
    } catch (error) {
        debugLog({
            event: 'session_state_write_failed',
            error: error.message
        });
    }
}

function debugLog(payload) {
    try {
        fs.appendFileSync(DEBUG_LOG, `${JSON.stringify({ timestamp: new Date().toISOString(), ...payload })}\n`);
    } catch (error) {
        // Ignore debug logging failures.
    }
}

function normalizeUsage(usage) {
    if (!usage) {
        return {
            input_tokens: 0,
            output_tokens: 0,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0
        };
    }

    return {
        input_tokens: usage.input_tokens || 0,
        output_tokens: usage.output_tokens || 0,
        cache_creation_input_tokens: usage.cache_creation_input_tokens || 0,
        cache_read_input_tokens: usage.cache_read_input_tokens || 0
    };
}

function extractText(content) {
    if (typeof content === 'string') {
        return content;
    }

    if (!Array.isArray(content)) {
        return '';
    }

    return content
        .filter((block) => block && block.type === 'text' && typeof block.text === 'string')
        .map((block) => block.text)
        .join('');
}

function serializeContent(content) {
    if (typeof content === 'string') {
        return content;
    }

    if (!Array.isArray(content)) {
        return '';
    }

    return content
        .map((block) => {
            if (!block || typeof block !== 'object') {
                return '';
            }

            if (block.type === 'text' && typeof block.text === 'string') {
                return block.text;
            }

            if (block.type === 'tool_use') {
                return `[tool_use:${block.name || 'unknown'}]\n${JSON.stringify(block.input || {})}`;
            }

            if (block.type === 'tool_result') {
                return `[tool_result]\n${serializeContent(block.content)}`;
            }

            if (block.type === 'image') {
                return '[image omitted]';
            }

            return `[${block.type || 'unknown'} omitted]`;
        })
        .filter(Boolean)
        .join('\n');
}

function extractSystemText(system) {
    if (typeof system === 'string') {
        return system;
    }

    if (Array.isArray(system)) {
        return serializeContent(system);
    }

    return '';
}

function buildToolBridgeNotice() {
    return [
        'Proxy tool mode:',
        '- Available executable tools in this session are limited to read, edit, write, exec/bash, grep, glob, and todo writing.',
        '- Do not call browser, canvas, nodes, cron, Gmail auth, Calendar auth, or other upstream OpenClaw-only tools through this Claude session.',
        '- If a requested action needs an unavailable tool family, answer directly and state the limitation instead of attempting the tool.'
    ].join('\n');
}

function getHeaderValue(headers, name) {
    const value = headers[name];
    if (Array.isArray(value)) {
        return value[0] || null;
    }
    return typeof value === 'string' && value.trim() ? value.trim() : null;
}

function hashText(value) {
    return crypto.createHash('sha256').update(value).digest('hex').slice(0, 16);
}

function buildHistoryLookupKey(request, messages) {
    if (!Array.isArray(messages) || messages.length === 0) {
        return null;
    }

    const systemText = extractSystemText(request.system || null);
    const transcript = messages
        .map((message) => {
            const role = message && typeof message.role === 'string' ? message.role : 'unknown';
            const content = message && Object.prototype.hasOwnProperty.call(message, 'content')
                ? serializeContent(message.content)
                : '';
            return `${role.toUpperCase()}:\n${content}`;
        })
        .join('\n\n');

    return `history:${hashText(`${systemText}\n\n${transcript}`)}`;
}

function getSessionLookupKey(req, request) {
    const headerSessionId =
        getHeaderValue(req.headers, 'session_id') ||
        getHeaderValue(req.headers, 'x-session-id') ||
        getHeaderValue(req.headers, 'x-openclaw-session-id');

    if (headerSessionId) {
        return `header:${headerSessionId}`;
    }

    const metadataSessionId = request && request.metadata && typeof request.metadata.session_id === 'string'
        ? request.metadata.session_id.trim()
        : null;

    if (metadataSessionId) {
        return `metadata:${metadataSessionId}`;
    }

    const messages = Array.isArray(request.messages) ? request.messages : [];
    const priorMessages = messages.slice(0, -1);

    return buildHistoryLookupKey(request, priorMessages);
}

function buildNextSessionLookupKey(request, assistantMessage) {
    const messages = Array.isArray(request.messages) ? request.messages : [];
    if (messages.length === 0 || !assistantMessage) {
        return null;
    }

    const nextMessages = messages.concat([
        {
            role: 'assistant',
            content: assistantMessage.content
        }
    ]);

    return buildHistoryLookupKey(request, nextMessages);
}

function saveSessionMapping(sessionLookupKey, nextSessionLookupKey, claudeSessionId, effectiveModel) {
    if (!claudeSessionId) {
        return;
    }

    sessionState = pruneExpiredSessions(sessionState).state;

    const value = {
        claudeSessionId,
        effectiveModel,
        updatedAt: new Date().toISOString()
    };

    if (sessionLookupKey) {
        sessionState.sessions[sessionLookupKey] = value;
    }

    if (nextSessionLookupKey) {
        sessionState.sessions[nextSessionLookupKey] = value;
    }

    persistSessionState();
}

function cloneMessage(message) {
    return JSON.parse(JSON.stringify(message));
}

function sanitizeResumeContent(content) {
    if (typeof content === 'string') {
        return content;
    }

    if (!Array.isArray(content)) {
        return '';
    }

    const textBlocks = content
        .filter((block) => block && block.type === 'text' && typeof block.text === 'string')
        .map((block) => ({
            type: 'text',
            text: block.text
        }));

    if (textBlocks.length > 0) {
        return textBlocks;
    }

    const serialized = serializeContent(content);
    return serialized ? [{ type: 'text', text: serialized }] : [];
}

function normalizeUserMessage(message) {
    const normalized = cloneMessage(message);
    normalized.role = 'user';
    normalized.content = sanitizeResumeContent(normalized.content);
    return normalized;
}

function normalizeRequestedModel(model) {
    if (typeof model !== 'string' || !model.trim()) {
        return 'opus';
    }

    const normalized = model.trim();
    const modelMap = {
        'claude-opus-4-6': 'claude-opus-4-5',
        'claude-sonnet-4-6': 'claude-sonnet-4-5',
        'claude-haiku-4-6': 'claude-haiku-4-5'
    };

    return modelMap[normalized] || normalized;
}

function shouldForceBootstrapForTurn(message) {
    const contentText = serializeContent(message && message.content);
    if (!contentText) {
        return false;
    }

    const normalizedText = contentText.toLowerCase();
    const startupMarkers = [
        'a new session was started via /new or /reset',
        'execute your session startup sequence now',
        'read the required files before responding',
        'new session was started via /new',
        'session startup sequence'
    ];

    return startupMarkers.some((marker) => normalizedText.includes(marker));
}

function buildSdkInput(request, options) {
    const messages = Array.isArray(request.messages) ? request.messages : [];
    const lastUserIndex = [...messages]
        .map((message, index) => ({ message, index }))
        .filter(({ message }) => message && message.role === 'user')
        .map(({ index }) => index)
        .pop();

    if (lastUserIndex == null) {
        return { error: 'No user message found' };
    }

    const lastUserMsg = messages[lastUserIndex];
    const priorMessages = messages.slice(0, lastUserIndex);
    const systemText = extractSystemText(request.system);
    const resumedClaudeSessionId = options && options.claudeSessionId ? options.claudeSessionId : null;
    const forceBootstrap = shouldForceBootstrapForTurn(lastUserMsg);

    if (resumedClaudeSessionId && !forceBootstrap) {
        return {
            sdkInput: [
                {
                    type: 'user',
                    message: normalizeUserMessage(lastUserMsg),
                    parent_tool_use_id: null,
                    session_id: resumedClaudeSessionId
                }
            ],
            mode: 'resume'
        };
    }

    const sections = [];

    if (systemText) {
        sections.push(`System instructions:\n${systemText}\n\n${buildToolBridgeNotice()}`);
    } else {
        sections.push(`System instructions:\n${buildToolBridgeNotice()}`);
    }

    if (priorMessages.length > 0) {
        const transcript = priorMessages
            .map((message) => {
                const role = (message.role || 'unknown').toUpperCase();
                const content = serializeContent(message.content);
                return `${role}:\n${content}`;
            })
            .join('\n\n');

        if (transcript) {
            sections.push(`Conversation history:\n${transcript}`);
        }
    }

    sections.push(`Current user message:\n${serializeContent(lastUserMsg.content)}`);

    const userContent = [
        {
            type: 'text',
            text: sections.join('\n\n')
        }
    ];

    const sdkInput = [];

    sdkInput.push({
        type: 'user',
        message: {
            role: 'user',
            content: userContent
        },
        parent_tool_use_id: null
    });

    return {
        sdkInput,
        mode: forceBootstrap ? 'bootstrap-reset' : 'bootstrap'
    };
}

function buildAssistantMessage(msg, requestModel, fallbackResult) {
    const usage = normalizeUsage(msg && msg.usage);
    const text = msg ? extractText(msg.content) : fallbackResult;

    return {
        id: (msg && msg.id) || `msg_proxy_${Date.now()}`,
        type: 'message',
        role: 'assistant',
        model: (msg && msg.model) || requestModel || 'claude-code-proxy',
        content: text ? [{ type: 'text', text }] : [],
        stop_reason: (msg && msg.stop_reason) || 'end_turn',
        stop_sequence: (msg && msg.stop_sequence) || null,
        usage
    };
}

function extractSessionIdFromOutputMessage(message) {
    if (!message || typeof message !== 'object') {
        return null;
    }

    return typeof message.session_id === 'string' && message.session_id.trim()
        ? message.session_id
        : null;
}

function writeSseEvent(res, event, payload) {
    res.write(`event: ${event}\n`);
    res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

function streamAnthropicMessage(res, assistantMessage) {
    const text = extractText(assistantMessage.content);

    writeSseEvent(res, 'message_start', {
        type: 'message_start',
        message: {
            id: assistantMessage.id,
            type: 'message',
            role: 'assistant',
            model: assistantMessage.model,
            content: [],
            stop_reason: null,
            stop_sequence: null,
            usage: {
                input_tokens: assistantMessage.usage.input_tokens,
                output_tokens: 0,
                cache_creation_input_tokens: assistantMessage.usage.cache_creation_input_tokens,
                cache_read_input_tokens: assistantMessage.usage.cache_read_input_tokens
            }
        }
    });

    if (text) {
        writeSseEvent(res, 'content_block_start', {
            type: 'content_block_start',
            index: 0,
            content_block: {
                type: 'text',
                text: ''
            }
        });

        writeSseEvent(res, 'content_block_delta', {
            type: 'content_block_delta',
            index: 0,
            delta: {
                type: 'text_delta',
                text
            }
        });

        writeSseEvent(res, 'content_block_stop', {
            type: 'content_block_stop',
            index: 0
        });
    }

    writeSseEvent(res, 'message_delta', {
        type: 'message_delta',
        delta: {
            stop_reason: assistantMessage.stop_reason,
            stop_sequence: assistantMessage.stop_sequence
        },
        usage: {
            output_tokens: assistantMessage.usage.output_tokens
        }
    });

    writeSseEvent(res, 'message_stop', {
        type: 'message_stop'
    });
}

function parseClaudeOutput(output, requestModel) {
    const lines = output.split('\n').filter((line) => line.trim());
    let finalAssistant = null;
    let fallbackResult = null;
    let sessionId = null;

    for (const line of lines) {
        try {
            const msg = JSON.parse(line);
            sessionId = extractSessionIdFromOutputMessage(msg) || sessionId;
            if (msg.type === 'assistant' && msg.message) {
                finalAssistant = msg.message;
            }
            if (msg.type === 'result' && msg.result) {
                fallbackResult = msg;
            }
        } catch (error) {
            // Skip non-JSON lines.
        }
    }

    if (finalAssistant) {
        return {
            assistantMessage: buildAssistantMessage(finalAssistant, requestModel),
            sessionId
        };
    }

    if (fallbackResult && fallbackResult.result) {
        return {
            assistantMessage: buildAssistantMessage(null, requestModel, fallbackResult.result),
            sessionId
        };
    }

    return null;
}

const server = http.createServer(async (req, res) => {
    if (req.method !== 'POST' || !req.url.startsWith('/v1/messages')) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Not found' }));
        return;
    }

    let body = '';
    for await (const chunk of req) {
        body += chunk;
    }

    let request;
    try {
        request = JSON.parse(body);
    } catch (error) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid JSON' }));
        return;
    }

    debugLog({
        event: 'request_received',
        path: req.url,
        method: req.method,
        model: request.model || null,
        stream: request.stream === true,
        messageCount: Array.isArray(request.messages) ? request.messages.length : 0,
        sessionLookupKey: getSessionLookupKey(req, request),
        systemPreview: extractSystemText(request.system).slice(0, 400)
    });

    const isStreaming = request.stream === true;
    const effectiveModel = normalizeRequestedModel(request.model);
    const sessionLookupKey = getSessionLookupKey(req, request);
    sessionState = pruneExpiredSessions(sessionState).state;
    const existingSession = sessionLookupKey ? sessionState.sessions[sessionLookupKey] : null;
    const claudeSessionId = existingSession && existingSession.effectiveModel === effectiveModel
        ? existingSession.claudeSessionId
        : null;

    const inputBuild = buildSdkInput(request, { claudeSessionId });

    if (inputBuild.error) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: inputBuild.error }));
        return;
    }

    const { sdkInput, mode } = inputBuild;

    console.log(`[${new Date().toISOString()}] Request: ${JSON.stringify(sdkInput[sdkInput.length - 1]).slice(0, 100)}...`);
    debugLog({
        event: 'request_translated',
        model: request.model || null,
        effectiveModel,
        mode,
        sessionLookupKey,
        claudeSessionId,
        translatedUserPreview: JSON.stringify(sdkInput[sdkInput.length - 1]).slice(0, 800)
    });

    const claudeArgs = [
        '--print',
        '--input-format=stream-json',
        '--output-format=stream-json',
        '--model', effectiveModel,
        '--tools', CLAUDE_ALLOWED_TOOLS.join(','),
        '--disallowedTools', ...CLAUDE_DISALLOWED_TOOLS,
        '--verbose'
    ];

    const claude = spawn('claude', claudeArgs, {
        stdio: ['pipe', 'pipe', 'pipe']
    });

    for (const message of sdkInput) {
        claude.stdin.write(`${JSON.stringify(message)}\n`);
    }
    claude.stdin.end();

    if (isStreaming) {
        res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            Connection: 'keep-alive'
        });

        let output = '';

        claude.stdout.on('data', (data) => {
            output += data.toString();
        });

        claude.on('close', () => {
            const parsedOutput = parseClaudeOutput(output, request.model);
            if (parsedOutput) {
                const { assistantMessage, sessionId } = parsedOutput;
                const nextSessionLookupKey = buildNextSessionLookupKey(request, assistantMessage);
                saveSessionMapping(sessionLookupKey, nextSessionLookupKey, sessionId, effectiveModel);
                debugLog({
                    event: 'stream_success',
                    model: request.model || null,
                    effectiveModel,
                    sessionLookupKey,
                    nextSessionLookupKey,
                    claudeSessionId: sessionId || claudeSessionId,
                    responsePreview: extractText(assistantMessage.content).slice(0, 400)
                });
                streamAnthropicMessage(res, assistantMessage);
            } else if (!res.headersSent) {
                debugLog({
                    event: 'stream_no_response',
                    model: request.model || null,
                    effectiveModel,
                    sessionLookupKey,
                    claudeSessionId,
                    rawOutputPreview: output.slice(0, 1200)
                });
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.write(JSON.stringify({ error: 'No response from Claude Code' }));
            }
            res.end();
        });
    } else {
        let output = '';

        claude.stdout.on('data', (data) => {
            output += data.toString();
        });

        claude.on('close', () => {
            const parsedOutput = parseClaudeOutput(output, request.model);
            if (parsedOutput) {
                const { assistantMessage, sessionId } = parsedOutput;
                const nextSessionLookupKey = buildNextSessionLookupKey(request, assistantMessage);
                saveSessionMapping(sessionLookupKey, nextSessionLookupKey, sessionId, effectiveModel);
                debugLog({
                    event: 'non_stream_success',
                    model: request.model || null,
                    effectiveModel,
                    sessionLookupKey,
                    nextSessionLookupKey,
                    claudeSessionId: sessionId || claudeSessionId,
                    responsePreview: extractText(assistantMessage.content).slice(0, 400)
                });
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(assistantMessage));
                return;
            }

            debugLog({
                event: 'non_stream_no_response',
                model: request.model || null,
                effectiveModel,
                sessionLookupKey,
                claudeSessionId,
                rawOutputPreview: output.slice(0, 1200)
            });

            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'No response from Claude Code' }));
        });
    }

    claude.stderr.on('data', (data) => {
        console.error(`[stderr] ${data.toString()}`);
        debugLog({
            event: 'claude_stderr',
            model: request.model || null,
            effectiveModel,
            sessionLookupKey,
            claudeSessionId,
            stderrPreview: data.toString().slice(0, 800)
        });
    });

    claude.on('error', (error) => {
        console.error(`[error] ${error.message}`);
        debugLog({
            event: 'claude_process_error',
            model: request.model || null,
            effectiveModel,
            sessionLookupKey,
            claudeSessionId,
            error: error.message
        });
        if (!res.headersSent) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: error.message }));
        }
    });
});

server.listen(PORT, () => {
    console.log(`Claude Code Proxy listening on http://localhost:${PORT}`);
    console.log(`Configure OpenClaw with baseUrl: http://localhost:${PORT}`);
});