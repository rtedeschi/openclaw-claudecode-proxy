const http = require('http');
const { spawn } = require('child_process');
const fs = require('fs');
const crypto = require('crypto');
const os = require('os');
const path = require('path');

const USER_HOME = os.homedir();
const OPENCLAW_HOME = path.join(USER_HOME, '.openclaw');
const OPENCLAW_WORKSPACE = path.join(OPENCLAW_HOME, 'workspace');
const DEFAULT_WORKING_DIRECTORY = fs.existsSync(OPENCLAW_WORKSPACE) ? OPENCLAW_WORKSPACE : USER_HOME;
const PORT = process.env.PORT || 8787;
const REQUEST_TIMEOUT_MS = Number.parseInt(process.env.OC_PROXY_REQUEST_TIMEOUT_MS || '900000', 10);
const TEMP_DIR = os.tmpdir();
const DEBUG_LOG = path.join(TEMP_DIR, 'claude-code-proxy-debug.log');
const SESSION_STATE_PATH = path.join(TEMP_DIR, 'claude-code-proxy-state.json');
const SESSION_TTL_MS = 6 * 60 * 60 * 1000;
const MAX_CONTEXT_MESSAGES = 8;
const MAX_CONTEXT_CHARS_PER_MESSAGE = 1200;
const MAX_MEMORY_EXCERPT_CHARS = 2200;
const MAX_DAILY_EXCERPT_CHARS = 2200;
const MAX_RECENT_MEMORY_FILES = 3;
const CLAUDE_ALLOWED_TOOLS = ['Read', 'Edit', 'Write', 'Bash', 'Grep', 'Glob', 'TodoWrite'];
const CLAUDE_DISALLOWED_TOOLS = [
    'mcp__claude_ai_Gmail__authenticate',
    'mcp__claude_ai_Google_Calendar__authenticate'
];

try {
    process.chdir(DEFAULT_WORKING_DIRECTORY);
} catch (error) {
    // If this fails, keep the inherited cwd and continue.
}

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

function createRequestId() {
    if (typeof crypto.randomUUID === 'function') {
        return crypto.randomUUID();
    }

    return `req_${Date.now()}_${crypto.randomBytes(4).toString('hex')}`;
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

function getMemoryBootstrapContext() {
    const workspaceRoot = OPENCLAW_WORKSPACE;
    const memoryFile = path.join(workspaceRoot, 'MEMORY.md');
    const memoryDir = path.join(workspaceRoot, 'memory');
    const memoryFiles = [];

    try {
        const entries = fs.readdirSync(memoryDir, { withFileTypes: true });
        for (const entry of entries) {
            if (!entry.isFile() || !entry.name.endsWith('.md')) {
                continue;
            }

            memoryFiles.push(path.join(memoryDir, entry.name));
        }
    } catch (error) {
        // Ignore missing directory or read errors; the notice will reflect the file inventory we could observe.
    }

    memoryFiles.sort();

    const todaysMemoryFile = path.join(memoryDir, `${new Date().toISOString().slice(0, 10)}.md`);
    const recentMemoryFiles = memoryFiles.slice(-5).reverse();

    return {
        workspaceRoot,
        memoryFile,
        memoryDir,
        memoryFiles,
        recentMemoryFiles,
        todaysMemoryFile,
        hasLongTermMemory: fs.existsSync(memoryFile),
        hasTodayMemory: fs.existsSync(todaysMemoryFile)
    };
}

function buildMemoryBootstrapNotice() {
    const context = getMemoryBootstrapContext();
    const recentFilesSection = context.recentMemoryFiles.length > 0
        ? context.recentMemoryFiles.map((filePath) => `- ${filePath}`).join('\n')
        : '- No markdown files were detected in the memory directory at proxy translation time.';

    return [
        'Required startup memory loading:',
        `- Workspace root: ${context.workspaceRoot}`,
        `- Read baseline long-term memory from: ${context.memoryFile}`,
        `- Long-term memory present right now: ${context.hasLongTermMemory ? 'yes' : 'no'}`,
        `- Daily memory directory: ${context.memoryDir}`,
        `- Daily memory markdown files present right now: ${context.memoryFiles.length}`,
        `- Today's daily memory file path: ${context.todaysMemoryFile}`,
        `- Today's daily memory file present right now: ${context.hasTodayMemory ? 'yes' : 'no'}`,
        '- Most recent daily memory files observed on disk:',
        recentFilesSection,
        '- Do not claim that no daily memory files exist unless this inventory is empty and the listed paths cannot be read.',
        '- If the user asks about ongoing work, prior commitments, or daily context, consult those memory files before answering.',
        '- Treat these files as OpenClaw-owned context that should be loaded on startup/reset boundaries.'
    ].join('\n');
}

function buildMemoryAnsweringNotice() {
    return [
        'Memory-answering rules:',
        '- Answer the current user message directly after consulting memory.',
        '- Do not repeat the previous assistant memory summary unless the user explicitly asks for a recap, restatement, or comparison.',
        '- If the user is testing continuity, provide one or two specific facts that demonstrate recall, then stop.',
        '- Prefer incremental answers over re-dumping long-term memory.'
    ].join('\n');
}

function buildResponseFocusNotice() {
    return [
        'Response rules:',
        '- Use the memory digest and recent conversation context as background, not as the answer itself.',
        '- Answer the current user message directly and specifically.',
        '- Do not restate large memory sections unless the user explicitly asks for a recap or summary.',
        '- If you cite memory, mention only the facts needed to answer the current turn.'
    ].join('\n');
}

function truncateText(text, maxChars) {
    if (typeof text !== 'string') {
        return '';
    }

    if (text.length <= maxChars) {
        return text;
    }

    return `${text.slice(0, Math.max(0, maxChars - 16))}\n...[truncated]`;
}

function readExcerpt(filePath, maxChars) {
    try {
        return truncateText(fs.readFileSync(filePath, 'utf8').trim(), maxChars);
    } catch (error) {
        return '';
    }
}

function buildMemoryDigest() {
    const context = getMemoryBootstrapContext();
    const digestSections = [];
    const longTermExcerpt = context.hasLongTermMemory
        ? readExcerpt(context.memoryFile, MAX_MEMORY_EXCERPT_CHARS)
        : '';
    const todaysExcerpt = context.hasTodayMemory
        ? readExcerpt(context.todaysMemoryFile, MAX_DAILY_EXCERPT_CHARS)
        : '';
    const recentDailyFiles = context.memoryFiles
        .filter((filePath) => filePath !== context.todaysMemoryFile)
        .slice(-MAX_RECENT_MEMORY_FILES)
        .reverse();

    digestSections.push('Memory digest inventory:');
    digestSections.push(`- Long-term memory file: ${context.memoryFile} (${context.hasLongTermMemory ? 'present' : 'missing'})`);
    digestSections.push(`- Today's daily file: ${context.todaysMemoryFile} (${context.hasTodayMemory ? 'present' : 'missing'})`);
    digestSections.push(`- Daily markdown file count: ${context.memoryFiles.length}`);

    if (recentDailyFiles.length > 0) {
        digestSections.push('Recent daily files:');
        digestSections.push(recentDailyFiles.map((filePath) => `- ${filePath}`).join('\n'));
    }

    if (longTermExcerpt) {
        digestSections.push(`Long-term memory excerpt (${context.memoryFile}):\n${longTermExcerpt}`);
    }

    if (todaysExcerpt) {
        digestSections.push(`Today's daily memory excerpt (${context.todaysMemoryFile}):\n${todaysExcerpt}`);
    }

    return digestSections.join('\n\n');
}

function buildConversationContext(messages, lastUserIndex) {
    const priorMessages = messages.slice(0, lastUserIndex);
    const windowedMessages = priorMessages.slice(-MAX_CONTEXT_MESSAGES);

    if (windowedMessages.length === 0) {
        return '';
    }

    return windowedMessages
        .map((message) => {
            const role = (message.role || 'unknown').toUpperCase();
            const content = truncateText(serializeContent(message.content), MAX_CONTEXT_CHARS_PER_MESSAGE);
            return `${role}:\n${content}`;
        })
        .join('\n\n');
}

function includesAnyMarker(text, markers) {
    return markers.some((marker) => text.includes(marker));
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

function isStartupTurn(message) {
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

    return includesAnyMarker(normalizedText, startupMarkers);
}

function buildSdkInput(request) {
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
    const systemText = extractSystemText(request.system);
    const startupTurn = isStartupTurn(lastUserMsg);

    const sections = [];

    if (systemText) {
        sections.push(`System instructions:\n${systemText}\n\n${buildToolBridgeNotice()}`);
    } else {
        sections.push(`System instructions:\n${buildToolBridgeNotice()}`);
    }

    sections.push(buildResponseFocusNotice());
    sections.push(buildMemoryAnsweringNotice());
    sections.push(buildMemoryBootstrapNotice());
    sections.push(buildMemoryDigest());

    if (startupTurn) {
        sections.push('Startup turn rules:\n- Execute the startup sequence using the memory digest and recent conversation context before replying.\n- Keep the greeting concise.');
    }

    const transcript = buildConversationContext(messages, lastUserIndex);
    if (transcript) {
        sections.push(`Recent conversation context:\n${transcript}`);
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
        mode: startupTurn ? 'stateless-startup' : 'stateless'
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

function writeSseEvent(res, event, payload, writeChunk = null, writeMeta = null) {
    const chunk = `event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`;

    if (typeof writeChunk === 'function') {
        writeChunk(chunk, writeMeta || {
            kind: 'sse_event',
            sseEvent: event
        });
        return;
    }

    res.write(chunk);
}

function createStreamingResponseState(requestModel) {
    return {
        messageStarted: false,
        blockStarted: false,
        blockStopped: false,
        messageStopped: false,
        assistantId: `msg_proxy_${Date.now()}`,
        model: requestModel || 'claude-code-proxy',
        usage: normalizeUsage(null),
        streamedText: '',
        stopReason: 'end_turn',
        stopSequence: null
    };
}

function updateStreamingStateFromAssistantMessage(streamingState, assistantMessage, requestModel) {
    if (!assistantMessage || typeof assistantMessage !== 'object') {
        return;
    }

    if (assistantMessage.id) {
        streamingState.assistantId = assistantMessage.id;
    }

    if (assistantMessage.model || requestModel) {
        streamingState.model = assistantMessage.model || requestModel || streamingState.model;
    }

    streamingState.usage = normalizeUsage(assistantMessage.usage || streamingState.usage);
    streamingState.stopReason = assistantMessage.stop_reason || streamingState.stopReason;
    streamingState.stopSequence = assistantMessage.stop_sequence || streamingState.stopSequence;
}

function ensureStreamingMessageStart(res, streamingState, writeChunk = null) {
    if (streamingState.messageStarted) {
        return;
    }

    streamingState.messageStarted = true;

    writeSseEvent(res, 'message_start', {
        type: 'message_start',
        message: {
            id: streamingState.assistantId,
            type: 'message',
            role: 'assistant',
            model: streamingState.model,
            content: [],
            stop_reason: null,
            stop_sequence: null,
            usage: {
                input_tokens: streamingState.usage.input_tokens,
                output_tokens: 0,
                cache_creation_input_tokens: streamingState.usage.cache_creation_input_tokens,
                cache_read_input_tokens: streamingState.usage.cache_read_input_tokens
            }
        }
    }, writeChunk);
}

function ensureStreamingContentBlockStart(res, streamingState, writeChunk = null) {
    if (streamingState.blockStarted) {
        return;
    }

    streamingState.blockStarted = true;

    writeSseEvent(res, 'content_block_start', {
        type: 'content_block_start',
        index: 0,
        content_block: {
            type: 'text',
            text: ''
        }
    }, writeChunk);
}

function emitStreamingTextDelta(res, streamingState, nextText, writeChunk = null) {
    if (!nextText) {
        return;
    }

    ensureStreamingMessageStart(res, streamingState, writeChunk);
    ensureStreamingContentBlockStart(res, streamingState, writeChunk);

    let deltaText = '';
    if (nextText.startsWith(streamingState.streamedText)) {
        deltaText = nextText.slice(streamingState.streamedText.length);
    } else if (!streamingState.streamedText) {
        deltaText = nextText;
    } else {
        deltaText = nextText;
    }

    if (!deltaText) {
        return;
    }

    writeSseEvent(res, 'content_block_delta', {
        type: 'content_block_delta',
        index: 0,
        delta: {
            type: 'text_delta',
            text: deltaText
        }
    }, writeChunk, {
        kind: 'text_delta',
        deltaChars: deltaText.length,
        totalStreamedChars: nextText.length
    });

    streamingState.streamedText = nextText;
}

function finalizeStreamingResponse(res, streamingState, assistantMessage, requestModel, writeChunk = null) {
    if (streamingState.messageStopped) {
        return;
    }

    updateStreamingStateFromAssistantMessage(streamingState, assistantMessage, requestModel);

    const finalText = extractText(assistantMessage && assistantMessage.content);
    if (finalText) {
        emitStreamingTextDelta(res, streamingState, finalText, writeChunk);
    }

    ensureStreamingMessageStart(res, streamingState, writeChunk);

    if (streamingState.blockStarted && !streamingState.blockStopped) {
        streamingState.blockStopped = true;
        writeSseEvent(res, 'content_block_stop', {
            type: 'content_block_stop',
            index: 0
        }, writeChunk);
    }

    writeSseEvent(res, 'message_delta', {
        type: 'message_delta',
        delta: {
            stop_reason: streamingState.stopReason,
            stop_sequence: streamingState.stopSequence
        },
        usage: {
            output_tokens: streamingState.usage.output_tokens
        }
    }, writeChunk);

    writeSseEvent(res, 'message_stop', {
        type: 'message_stop'
    }, writeChunk);

    streamingState.messageStopped = true;
}

function updateStreamingStateFromResult(streamingState, resultMessage) {
    if (!resultMessage || typeof resultMessage !== 'object') {
        return;
    }

    streamingState.usage = normalizeUsage(resultMessage.usage || streamingState.usage);
    streamingState.stopReason = resultMessage.stop_reason || streamingState.stopReason;
    streamingState.stopSequence = resultMessage.stop_sequence || streamingState.stopSequence;
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
    const requestId = createRequestId();
    const requestStartedAt = Date.now();
    let request = null;
    let effectiveModel = null;
    let sessionLookupKey = null;
    let claude = null;
    let claudeOutput = '';
    let responseFinished = false;
    let responseClosed = false;
    let clientDisconnected = false;
    let streamingDebugState = null;

    const getElapsedMs = () => Date.now() - requestStartedAt;

    const getStreamingDebugSnapshot = () => {
        if (!streamingDebugState) {
            return {};
        }

        return {
            responseWriteCount: streamingDebugState.responseWriteCount,
            responseBytesWritten: streamingDebugState.responseBytesWritten,
            heartbeatCount: streamingDebugState.heartbeatCount,
            textDeltaCount: streamingDebugState.textDeltaCount,
            textDeltaChars: streamingDebugState.textDeltaChars,
            firstAssistantMessageElapsedMs: streamingDebugState.firstAssistantMessageElapsedMs,
            lastResponseWriteElapsedMs: streamingDebugState.lastResponseWriteElapsedMs,
            lastResponseWriteKind: streamingDebugState.lastResponseWriteKind,
            socketBytesWritten: streamingDebugState.lastObservedSocketBytesWritten
        };
    };

    const logStreamingWriteSummary = (reason) => {
        if (!streamingDebugState) {
            return;
        }

        logLifecycleEvent('stream_response_write_summary', {
            reason,
            ...getStreamingDebugSnapshot()
        });
    };

    const logLifecycleEvent = (event, extra = {}) => {
        debugLog({
            event,
            requestId,
            elapsedMs: getElapsedMs(),
            path: req.url,
            method: req.method,
            model: request && request.model ? request.model : null,
            effectiveModel,
            sessionLookupKey,
            ...extra
        });
    };

    const terminateClaudeProcess = (reason) => {
        if (!claude || claude.exitCode != null || claude.signalCode != null || claude.killed) {
            return;
        }

        logLifecycleEvent('claude_process_terminated', { reason });
        claude.kill('SIGTERM');
    };

    req.on('aborted', () => {
        clientDisconnected = true;
        logLifecycleEvent('request_aborted', {
            requestComplete: req.complete,
            readableAborted: req.readableAborted === true
        });
        terminateClaudeProcess('request_aborted');
    });

    req.on('close', () => {
        if (!req.complete) {
            clientDisconnected = true;
            logLifecycleEvent('request_stream_closed_before_complete', {
                requestComplete: req.complete,
                readableAborted: req.readableAborted === true
            });
            terminateClaudeProcess('request_stream_closed_before_complete');
        }
    });

    req.socket.on('timeout', () => {
        logLifecycleEvent('request_socket_timeout', {
            serverRequestTimeoutMs: server.requestTimeout,
            serverHeadersTimeoutMs: server.headersTimeout,
            serverSocketTimeoutMs: server.timeout,
            serverKeepAliveTimeoutMs: server.keepAliveTimeout
        });
    });

    res.on('finish', () => {
        responseFinished = true;
        logStreamingWriteSummary('response_finished');
        logLifecycleEvent('response_finished', {
            statusCode: res.statusCode,
            headersSent: res.headersSent,
            writableEnded: res.writableEnded,
            ...getStreamingDebugSnapshot()
        });
    });

    res.on('close', () => {
        responseClosed = true;
        if (!responseFinished) {
            clientDisconnected = true;
            logStreamingWriteSummary('response_closed_before_finish');
            logLifecycleEvent('response_closed_before_finish', {
                statusCode: res.statusCode,
                headersSent: res.headersSent,
                writableEnded: res.writableEnded,
                ...getStreamingDebugSnapshot()
            });
            terminateClaudeProcess('response_closed_before_finish');
        }
    });

    if (req.method !== 'POST' || !req.url.startsWith('/v1/messages')) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Not found' }));
        return;
    }

    let body = '';
    try {
        for await (const chunk of req) {
            body += chunk;
        }
    } catch (error) {
        logLifecycleEvent('request_body_read_failed', {
            error: error.message,
            requestComplete: req.complete,
            readableAborted: req.readableAborted === true
        });
        return;
    }

    try {
        request = JSON.parse(body);
    } catch (error) {
        logLifecycleEvent('request_json_parse_failed', {
            error: error.message,
            bodyPreview: body.slice(0, 800)
        });
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
    effectiveModel = normalizeRequestedModel(request.model);
    sessionLookupKey = getSessionLookupKey(req, request);
    const inputBuild = buildSdkInput(request);

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
        translatedUserPreview: JSON.stringify(sdkInput[sdkInput.length - 1]).slice(0, 800)
    });

    const claudeArgs = [
        '--print',
        '--input-format=stream-json',
        '--output-format=stream-json',
        '--dangerously-skip-permissions',
        '--model', effectiveModel,
        '--tools', CLAUDE_ALLOWED_TOOLS.join(','),
        '--disallowedTools', ...CLAUDE_DISALLOWED_TOOLS,
        '--verbose'
    ];

    claude = spawn('claude', claudeArgs, {
        stdio: ['pipe', 'pipe', 'pipe'],
        cwd: DEFAULT_WORKING_DIRECTORY
    });

    logLifecycleEvent('claude_process_spawned', {
        claudePid: claude.pid,
        stream: isStreaming,
        mode
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

        const streamingState = createStreamingResponseState(request.model);
        streamingDebugState = {
            responseWriteCount: 0,
            responseBytesWritten: 0,
            heartbeatCount: 0,
            textDeltaCount: 0,
            textDeltaChars: 0,
            firstAssistantMessageElapsedMs: null,
            lastResponseWriteElapsedMs: null,
            lastResponseWriteKind: null,
            lastObservedSocketBytesWritten: null
        };
        let stdoutBuffer = '';

        const writeStreamingChunk = (chunk, meta = {}) => {
            const chunkText = typeof chunk === 'string' ? chunk : String(chunk);
            const chunkBytes = Buffer.byteLength(chunkText);

            res.write(chunkText);

            streamingDebugState.responseWriteCount += 1;
            streamingDebugState.responseBytesWritten += chunkBytes;
            streamingDebugState.lastResponseWriteElapsedMs = getElapsedMs();
            streamingDebugState.lastResponseWriteKind = meta.kind || 'unknown';
            if (res.socket && typeof res.socket.bytesWritten === 'number') {
                streamingDebugState.lastObservedSocketBytesWritten = res.socket.bytesWritten;
            }

            if (meta.kind === 'heartbeat') {
                streamingDebugState.heartbeatCount += 1;
                logLifecycleEvent('stream_heartbeat_written', {
                    chunkBytes,
                    ...getStreamingDebugSnapshot()
                });
                return;
            }

            if (meta.kind === 'text_delta') {
                streamingDebugState.textDeltaCount += 1;
                streamingDebugState.textDeltaChars += meta.deltaChars || 0;
                logLifecycleEvent('stream_text_delta_written', {
                    chunkBytes,
                    deltaChars: meta.deltaChars || 0,
                    totalStreamedChars: meta.totalStreamedChars || 0,
                    ...getStreamingDebugSnapshot()
                });
            }
        };

        const noteFirstAssistantMessage = (assistantMessage, source) => {
            if (streamingDebugState.firstAssistantMessageElapsedMs != null) {
                return;
            }

            const assistantText = extractText(assistantMessage && assistantMessage.content);
            streamingDebugState.firstAssistantMessageElapsedMs = getElapsedMs();
            logLifecycleEvent('stream_first_assistant_message_parsed', {
                source,
                assistantContentChars: assistantText.length,
                claudeOutputChars: claudeOutput.length,
                stdoutBufferChars: stdoutBuffer.length,
                ...getStreamingDebugSnapshot()
            });
        };

        const heartbeat = setInterval(() => {
            if (!res.writableEnded) {
                writeStreamingChunk(': keep-alive\n\n', {
                    kind: 'heartbeat'
                });
            }
        }, 10000);

        ensureStreamingMessageStart(res, streamingState, writeStreamingChunk);

        claude.stdout.on('data', (data) => {
            const chunkText = data.toString();
            claudeOutput += chunkText;
            stdoutBuffer += chunkText;

            let newlineIndex = stdoutBuffer.indexOf('\n');
            while (newlineIndex !== -1) {
                const line = stdoutBuffer.slice(0, newlineIndex).trim();
                stdoutBuffer = stdoutBuffer.slice(newlineIndex + 1);

                if (line) {
                    try {
                        const msg = JSON.parse(line);

                        if (msg.type === 'assistant' && msg.message) {
                            noteFirstAssistantMessage(msg.message, 'stdout');
                            updateStreamingStateFromAssistantMessage(streamingState, msg.message, request.model);
                            emitStreamingTextDelta(res, streamingState, extractText(msg.message.content), writeStreamingChunk);
                        }

                        if (msg.type === 'result') {
                            updateStreamingStateFromResult(streamingState, msg);
                        }
                    } catch (error) {
                        logLifecycleEvent('stream_json_parse_failed', {
                            error: error.message,
                            linePreview: line.slice(0, 400)
                        });
                    }
                }

                newlineIndex = stdoutBuffer.indexOf('\n');
            }
        });

        claude.on('close', () => {
            clearInterval(heartbeat);

            const trailingLine = stdoutBuffer.trim();
            if (trailingLine) {
                try {
                    const msg = JSON.parse(trailingLine);

                    if (msg.type === 'assistant' && msg.message) {
                        noteFirstAssistantMessage(msg.message, 'close_trailing_line');
                        updateStreamingStateFromAssistantMessage(streamingState, msg.message, request.model);
                        emitStreamingTextDelta(res, streamingState, extractText(msg.message.content), writeStreamingChunk);
                    }

                    if (msg.type === 'result') {
                        updateStreamingStateFromResult(streamingState, msg);
                    }
                } catch (error) {
                    logLifecycleEvent('stream_json_parse_failed', {
                        error: error.message,
                        linePreview: trailingLine.slice(0, 400)
                    });
                }
            }

            if (clientDisconnected || responseClosed) {
                logLifecycleEvent('stream_response_skipped_after_disconnect', {
                    statusCode: res.statusCode,
                    headersSent: res.headersSent,
                    writableEnded: res.writableEnded
                });
                if (!res.writableEnded) {
                    res.end();
                }
                return;
            }

            const parsedOutput = parseClaudeOutput(claudeOutput, request.model);
            if (parsedOutput) {
                const { assistantMessage } = parsedOutput;
                debugLog({
                    event: 'stream_success',
                    requestId,
                    model: request.model || null,
                    effectiveModel,
                    sessionLookupKey,
                    elapsedMs: getElapsedMs(),
                    responsePreview: extractText(assistantMessage.content).slice(0, 400)
                });
                finalizeStreamingResponse(res, streamingState, assistantMessage, request.model, writeStreamingChunk);
            } else {
                debugLog({
                    event: 'stream_no_response',
                    requestId,
                    model: request.model || null,
                    effectiveModel,
                    sessionLookupKey,
                    elapsedMs: getElapsedMs(),
                    rawOutputPreview: claudeOutput.slice(0, 1200)
                });

                emitStreamingTextDelta(res, streamingState, 'No response from Claude Code', writeStreamingChunk);
                finalizeStreamingResponse(res, streamingState, null, request.model, writeStreamingChunk);
            }

            if (!res.writableEnded) {
                res.end();
            }
        });
    } else {
        claude.stdout.on('data', (data) => {
            claudeOutput += data.toString();
        });

        claude.on('close', () => {
            if (clientDisconnected || responseClosed) {
                logLifecycleEvent('non_stream_response_skipped_after_disconnect', {
                    statusCode: res.statusCode,
                    headersSent: res.headersSent,
                    writableEnded: res.writableEnded
                });
                if (!res.writableEnded) {
                    res.end();
                }
                return;
            }

            const parsedOutput = parseClaudeOutput(claudeOutput, request.model);
            if (parsedOutput) {
                const { assistantMessage } = parsedOutput;
                debugLog({
                    event: 'non_stream_success',
                    requestId,
                    model: request.model || null,
                    effectiveModel,
                    sessionLookupKey,
                    elapsedMs: getElapsedMs(),
                    responsePreview: extractText(assistantMessage.content).slice(0, 400)
                });
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(assistantMessage));
                return;
            }

            debugLog({
                event: 'non_stream_no_response',
                requestId,
                model: request.model || null,
                effectiveModel,
                sessionLookupKey,
                elapsedMs: getElapsedMs(),
                rawOutputPreview: claudeOutput.slice(0, 1200)
            });

            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'No response from Claude Code' }));
        });
    }

    claude.stderr.on('data', (data) => {
        console.error(`[stderr] ${data.toString()}`);
        debugLog({
            event: 'claude_stderr',
            requestId,
            model: request.model || null,
            effectiveModel,
            sessionLookupKey,
            elapsedMs: getElapsedMs(),
            stderrPreview: data.toString().slice(0, 800)
        });
    });

    claude.on('exit', (code, signal) => {
        logLifecycleEvent('claude_process_exit', {
            code,
            signal,
            clientDisconnected,
            responseFinished,
            responseClosed,
            outputChars: claudeOutput.length
        });
    });

    claude.on('error', (error) => {
        console.error(`[error] ${error.message}`);
        debugLog({
            event: 'claude_process_error',
            requestId,
            model: request.model || null,
            effectiveModel,
            sessionLookupKey,
            elapsedMs: getElapsedMs(),
            error: error.message
        });
        if (!res.headersSent) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: error.message }));
        }
    });
});

server.requestTimeout = Number.isFinite(REQUEST_TIMEOUT_MS) && REQUEST_TIMEOUT_MS > 0
    ? REQUEST_TIMEOUT_MS
    : 900000;

server.on('timeout', (socket) => {
    debugLog({
        event: 'server_socket_timeout',
        remoteAddress: socket.remoteAddress || null,
        remotePort: socket.remotePort || null,
        serverRequestTimeoutMs: server.requestTimeout,
        serverHeadersTimeoutMs: server.headersTimeout,
        serverSocketTimeoutMs: server.timeout,
        serverKeepAliveTimeoutMs: server.keepAliveTimeout
    });
});

server.listen(PORT, () => {
    console.log(`Claude Code Proxy listening on http://localhost:${PORT}`);
    console.log(`Configure OpenClaw with baseUrl: http://localhost:${PORT}`);
    console.log(`Server timeouts: request=${server.requestTimeout}ms headers=${server.headersTimeout}ms socket=${server.timeout}ms keepAlive=${server.keepAliveTimeout}ms`);
    debugLog({
        event: 'server_started',
        port: PORT,
        requestTimeoutMs: server.requestTimeout,
        headersTimeoutMs: server.headersTimeout,
        socketTimeoutMs: server.timeout,
        keepAliveTimeoutMs: server.keepAliveTimeout
    });
});