// DALI2 Web UI - Frontend Application

const API = '';
let lastLogTime = 0;
let selectedAgent = '';
let pollInterval = null;
let monacoEditor = null;
let currentAgentFile = '';

// ============================================================
// API Calls
// ============================================================

async function api(path, opts = {}) {
    try {
        const resp = await fetch(API + path, {
            headers: { 'Content-Type': 'application/json' },
            ...opts
        });
        return await resp.json();
    } catch (e) {
        console.error('API error:', path, e);
        return null;
    }
}

const getStatus = () => api('/api/status');
const getAgents = () => api('/api/agents');
const getLogs = (agent, since) => api(`/api/logs?agent=${agent}&since=${since}`);
const getBeliefs = (agent) => api(`/api/beliefs?agent=${agent}`);
const getPast = (agent) => api(`/api/past?agent=${agent}`);
const getBlackboard = () => api('/api/blackboard');
const getSource = () => api('/api/source');

const postSend = (to, content) => api('/api/send', {
    method: 'POST', body: JSON.stringify({ to, content })
});

const postInject = (agent, event) => api('/api/inject', {
    method: 'POST', body: JSON.stringify({ agent, event })
});

const postStart = (agent) => api('/api/start', {
    method: 'POST', body: JSON.stringify({ agent })
});

const postStop = (agent) => api('/api/stop', {
    method: 'POST', body: JSON.stringify({ agent })
});

const postReload = (file) => api('/api/reload', {
    method: 'POST', body: JSON.stringify({ file: file || '' })
});

const postSave = (content) => api('/api/save', {
    method: 'POST', body: JSON.stringify({ content })
});

const postSaveFile = (filename, content) => api('/api/save_file', {
    method: 'POST', body: JSON.stringify({ filename, content })
});

// AI Oracle API
const getAiStatus = () => api('/api/ai/status');
const postAiKey = (key) => api('/api/ai/key', {
    method: 'POST', body: JSON.stringify({ key })
});
const postAiModel = (model) => api('/api/ai/model', {
    method: 'POST', body: JSON.stringify({ model })
});
const postAiAsk = (context) => api('/api/ai/ask', {
    method: 'POST', body: JSON.stringify({ context })
});

// Cluster API (Redis-based agent registry)
const getCluster = () => api('/api/cluster');

// ============================================================
// UI Updates
// ============================================================

function formatTime(timestamp) {
    const d = new Date(timestamp);
    return d.toLocaleTimeString('it-IT', { hour12: false });
}

function updateStatus(data) {
    const dot = document.getElementById('status-indicator');
    const text = document.getElementById('status-text');
    const nodeLabel = document.getElementById('node-name');
    if (data) {
        dot.className = 'status-dot connected';
        const redisInfo = data.redis ? ' | Redis' : ' | no Redis';
        const clusterInfo = data.cluster_agents > data.agents ? ` | ${data.cluster_agents} in cluster` : '';
        text.textContent = `${data.agents} agent${data.agents !== 1 ? 's' : ''} active${redisInfo}${clusterInfo}`;
        if (data.node) nodeLabel.textContent = data.node;
    } else {
        dot.className = 'status-dot error';
        text.textContent = 'Disconnected';
    }
}

function updateAgentsList(agents) {
    const list = document.getElementById('agents-list');
    const filter = document.getElementById('log-filter');
    const sendTo = document.getElementById('send-to');

    // Preserve selections
    const filterVal = filter.value;
    const sendVal = sendTo.value;

    list.innerHTML = '';
    filter.innerHTML = '<option value="">All agents</option>';
    sendTo.innerHTML = '';

    if (!agents) return;

    agents.forEach(a => {
        // Agent list item
        const item = document.createElement('div');
        item.className = `agent-item${selectedAgent === a.name ? ' selected' : ''}`;
        item.innerHTML = `
            <span class="agent-dot ${a.status}"></span>
            <span class="agent-name">${a.name}</span>
            <span class="agent-cycle">${a.cycle}s</span>
        `;
        item.onclick = () => selectAgent(a.name);
        list.appendChild(item);

        // Filter option
        const opt1 = document.createElement('option');
        opt1.value = a.name;
        opt1.textContent = a.name;
        filter.appendChild(opt1);

        // Send-to option
        const opt2 = document.createElement('option');
        opt2.value = a.name;
        opt2.textContent = a.name;
        sendTo.appendChild(opt2);
    });

    filter.value = filterVal;
    sendTo.value = sendVal || (agents.length > 0 ? agents[0].name : '');
}

function appendLogs(logs) {
    if (!logs || logs.length === 0) return;

    const container = document.getElementById('log-container');
    const autoScroll = document.getElementById('auto-scroll').checked;
    const filterAgent = document.getElementById('log-filter').value;

    logs.forEach(log => {
        if (filterAgent && log.agent !== filterAgent) return;

        const entry = document.createElement('div');
        let cls = 'log-entry';
        const msg = String(log.message);
        if (msg.includes('error') || msg.includes('Error')) cls += ' error';
        else if (msg.includes('Sent to')) cls += ' sent';
        else if (msg.includes('Received from')) cls += ' received';

        entry.className = cls;
        entry.innerHTML = `
            <span class="log-time">${formatTime(log.time)}</span>
            <span class="log-agent">${log.agent}</span>
            <span class="log-msg">${escapeHtml(msg)}</span>
        `;
        container.appendChild(entry);

        if (log.time > lastLogTime) lastLogTime = log.time;
    });

    // Trim old entries (keep last 500)
    while (container.children.length > 500) {
        container.removeChild(container.firstChild);
    }

    if (autoScroll) {
        container.scrollTop = container.scrollHeight;
    }
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

async function selectAgent(name) {
    selectedAgent = name;

    // Update selection highlight
    document.querySelectorAll('.agent-item').forEach(el => {
        el.classList.toggle('selected',
            el.querySelector('.agent-name').textContent === name);
    });

    const details = document.getElementById('agent-details');
    details.style.display = 'block';
    document.getElementById('detail-name').textContent = name;

    // Get agent info
    const agentsData = await getAgents();
    if (agentsData) {
        const agent = agentsData.agents.find(a => a.name === name);
        if (agent) {
            document.getElementById('detail-status').textContent = agent.status;
            document.getElementById('detail-status').className = `badge ${agent.status}`;
            document.getElementById('detail-cycle').textContent = `${agent.cycle}s`;
        }
    }

    // Beliefs
    const beliefsData = await getBeliefs(name);
    const beliefsList = document.getElementById('detail-beliefs');
    beliefsList.innerHTML = '';
    if (beliefsData && beliefsData.beliefs) {
        beliefsData.beliefs.forEach(b => {
            const li = document.createElement('li');
            li.textContent = b.belief;
            beliefsList.appendChild(li);
        });
        if (beliefsData.beliefs.length === 0) {
            beliefsList.innerHTML = '<li style="color:var(--text-muted)">No beliefs</li>';
        }
    }

    // Past events
    const pastData = await getPast(name);
    const pastList = document.getElementById('detail-past');
    pastList.innerHTML = '';
    if (pastData && pastData.past) {
        const pastCount = document.getElementById('past-count');
        pastCount.textContent = `(${pastData.past.length})`;
        // Show last 20
        pastData.past.slice(-20).forEach(p => {
            const li = document.createElement('li');
            li.textContent = `${p.event}`;
            pastList.appendChild(li);
        });
        if (pastData.past.length === 0) {
            pastList.innerHTML = '<li style="color:var(--text-muted)">No past events</li>';
        }
    }

    // Wire up start/stop buttons
    const startBtn = details.querySelector('.btn-start');
    const stopBtn = details.querySelector('.btn-stop');
    startBtn.onclick = async () => { await postStart(name); poll(); };
    stopBtn.onclick = async () => { await postStop(name); poll(); };
}

async function updateBlackboard() {
    const data = await getBlackboard();
    const list = document.getElementById('blackboard-list');
    list.innerHTML = '';
    if (data && data.tuples) {
        data.tuples.forEach(t => {
            const li = document.createElement('li');
            li.textContent = t;
            list.appendChild(li);
        });
        if (data.tuples.length === 0) {
            list.innerHTML = '<li style="color:var(--text-muted)">Empty</li>';
        }
    }
}

// ============================================================
// View Toggle Functions (Log / File editor)
// ============================================================

function switchView(view) {
    const logsView = document.getElementById('logs-view');
    const fileView = document.getElementById('file-view');
    const btnLogs = document.getElementById('btn-view-logs');
    const btnFile = document.getElementById('btn-view-file');
    const logControls = document.querySelector('.log-controls');
    const fileControls = document.querySelector('.file-controls');

    if (view === 'logs') {
        logsView.style.display = 'block';
        fileView.style.display = 'none';
        btnLogs.classList.add('active');
        btnFile.classList.remove('active');
        logControls.style.display = 'flex';
        fileControls.style.display = 'none';
    } else {
        logsView.style.display = 'none';
        fileView.style.display = 'block';
        btnLogs.classList.remove('active');
        btnFile.classList.add('active');
        logControls.style.display = 'none';
        fileControls.style.display = 'flex';
    }
}

async function loadFileView() {
    const data = await getSource();
    if (data && data.content) {
        currentAgentFile = data.file || '';
        document.getElementById('file-name').textContent = currentAgentFile || 'Untitled';

        if (!monacoEditor) {
            await initMonacoEditor(data.content);
        } else {
            monacoEditor.setValue(data.content);
        }
    }
}

async function preloadFileEditor() {
    try {
        const data = await getSource();
        if (data && data.content) {
            currentAgentFile = data.file || '';
            document.getElementById('file-name').textContent = currentAgentFile || 'Untitled';
            await initMonacoEditor(data.content);
        }
    } catch (e) {
        console.error('Error preloading editor:', e);
    }
}

function initMonacoEditor(content) {
    return new Promise((resolve) => {
        require.config({ paths: { 'vs': 'https://cdnjs.cloudflare.com/ajax/libs/monaco-editor/0.44.0/min/vs' }});

        require(['vs/editor/editor.main'], function() {
            // Register DALI/Prolog language highlighting
            monaco.languages.register({ id: 'prolog' });

            monaco.languages.setMonarchTokensProvider('prolog', {
                tokenizer: {
                    root: [
                        // Comments
                        [/%.*/, 'comment'],
                        [/\/\*/, 'comment', '@comment'],

                        // Strings
                        [/'([^'\\]|\\.)*'/, 'string'],
                        [/"([^"\\]|\\.)*"/, 'string'],

                        // DALI operators
                        [/:>|:<|~\/|<\/|\?\/|:~/, 'operator'],
                        [/:-|-->/, 'operator'],

                        // Predicates and atoms (lowercase start or in quotes)
                        [/[a-z_]\w*(?=\s*\()/, 'function'],
                        [/[a-z_]\w*/, 'identifier'],

                        // Variables (uppercase start or underscore)
                        [/[A-Z_]\w*/, 'type'],

                        // Numbers
                        [/\d+\.\d+/, 'number'],
                        [/\d+/, 'number'],

                        // Operators and punctuation
                        [/[(){}\[\],.|]/, 'delimiter'],
                        [/[+\-*/=<>\\]/, 'operator'],
                    ],
                    comment: [
                        [/[^*/]+/, 'comment'],
                        [/\*\//, 'comment', '@pop'],
                        [/[*/]/, 'comment'],
                    ],
                },
            });

            monacoEditor = monaco.editor.create(document.getElementById('monaco-editor'), {
                value: content,
                language: 'prolog',
                theme: 'vs-dark',
                automaticLayout: true,
                minimap: { enabled: true },
                fontSize: 13,
                fontFamily: "'JetBrains Mono', Consolas, monospace",
                lineNumbers: 'on',
                scrollBeyondLastLine: false,
                tabSize: 4,
                wordWrap: 'on',
                formatOnPaste: true,
                defaultFormatter: null,
                padding: { bottom: 360 }
            });

            // Handle Ctrl+S for save
            monacoEditor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
                document.getElementById('btn-file-save').click();
            });

            resolve(monacoEditor);
        });
    });
}

// ============================================================
// Polling Loop
// ============================================================

async function poll() {
    const [status, agents, logs] = await Promise.all([
        getStatus(),
        getAgents(),
        getLogs('', lastLogTime)
    ]);

    updateStatus(status);
    if (agents) updateAgentsList(agents.agents);
    if (logs) appendLogs(logs.logs);

    // Update details if agent selected
    if (selectedAgent) {
        // Lightweight: only update status badge
        if (agents && agents.agents) {
            const a = agents.agents.find(x => x.name === selectedAgent);
            if (a) {
                document.getElementById('detail-status').textContent = a.status;
                document.getElementById('detail-status').className = `badge ${a.status}`;
            }
        }
    }
}

// ============================================================
// Event Handlers
// ============================================================

function init() {
    // Send button
    document.getElementById('btn-send').addEventListener('click', async () => {
        const to = document.getElementById('send-to').value;
        const content = document.getElementById('send-content').value.trim();
        if (!to || !content) return;
        const result = await postSend(to, content);
        if (result && result.ok) {
            document.getElementById('send-content').value = '';
        }
        poll();
    });

    // Enter key in send field
    document.getElementById('send-content').addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            document.getElementById('btn-send').click();
        }
    });

    // Reload button
    document.getElementById('btn-reload').addEventListener('click', async () => {
        if (confirm('Reload all agents?')) {
            await postReload();
            lastLogTime = 0;
            document.getElementById('log-container').innerHTML = '';
            poll();
        }
    });

    // Clear logs
    document.getElementById('btn-clear-logs').addEventListener('click', () => {
        document.getElementById('log-container').innerHTML = '';
        lastLogTime = Date.now();
    });

    // Log filter change
    document.getElementById('log-filter').addEventListener('change', () => {
        // Re-fetch all logs with new filter
        document.getElementById('log-container').innerHTML = '';
        lastLogTime = 0;
        poll();
    });

    // Source editor
    document.getElementById('btn-close-editor').addEventListener('click', () => {
        document.getElementById('editor-modal').style.display = 'none';
    });

    document.getElementById('btn-save-source').addEventListener('click', async () => {
        const content = document.getElementById('source-editor').value;
        await postSave(content);
        await postReload();
        document.getElementById('editor-modal').style.display = 'none';
        lastLogTime = 0;
        document.getElementById('log-container').innerHTML = '';
        poll();
    });

    // --- AI Oracle ---
    document.getElementById('btn-set-key').addEventListener('click', async () => {
        const key = document.getElementById('ai-key-input').value.trim();
        if (!key) return;
        const res = await postAiKey(key);
        if (res && res.ok) {
            document.getElementById('ai-key-input').value = '';
            updateAiStatus();
        }
    });

    document.getElementById('ai-model-select').addEventListener('change', async () => {
        const model = document.getElementById('ai-model-select').value;
        await postAiModel(model);
        updateAiStatus();
    });

    document.getElementById('btn-ask-ai').addEventListener('click', async () => {
        const ctx = document.getElementById('ai-context').value.trim();
        if (!ctx) return;
        const respDiv = document.getElementById('ai-response');
        respDiv.style.display = 'block';
        respDiv.textContent = 'Querying AI...';
        respDiv.className = 'ai-response loading';
        const res = await postAiAsk(ctx);
        if (res && res.ok) {
            respDiv.textContent = res.result;
            respDiv.className = 'ai-response success';
        } else {
            respDiv.textContent = res ? (res.error || 'Error') : 'Connection error';
            respDiv.className = 'ai-response error';
        }
    });

    document.getElementById('ai-context').addEventListener('keydown', (e) => {
        if (e.key === 'Enter') document.getElementById('btn-ask-ai').click();
    });

    // Double-click header to open editor
    document.querySelector('.header-left').addEventListener('dblclick', async () => {
        const data = await getSource();
        if (data) {
            document.getElementById('source-editor').value = data.content || '';
            document.getElementById('editor-modal').style.display = 'flex';
        }
    });

    // --- View Toggle (Logs vs File) ---
    document.getElementById('btn-view-logs').addEventListener('click', () => {
        switchView('logs');
    });
    document.getElementById('btn-view-file').addEventListener('click', () => {
        switchView('file');
        loadFileView();
    });

    // --- File Save ---
    document.getElementById('btn-file-save').addEventListener('click', async () => {
        if (!monacoEditor) return;
        const content = monacoEditor.getValue();
        const btnSave = document.getElementById('btn-file-save');
        const originalText = btnSave.textContent;

        btnSave.disabled = true;
        btnSave.textContent = 'Saving...';

        const result = await postSaveFile(currentAgentFile, content);

        if (result && result.ok) {
            btnSave.textContent = 'Saved!';
            setTimeout(() => {
                btnSave.textContent = originalText;
                btnSave.disabled = false;
            }, 1500);
        } else {
            const errorMsg = result ? (result.error || 'Unknown error') : 'No response';
            console.error('Save error:', errorMsg);
            btnSave.textContent = 'Save Failed';
            setTimeout(() => {
                btnSave.textContent = originalText;
                btnSave.disabled = false;
            }, 2000);
        }
    });

    // Start polling
    poll();
    pollInterval = setInterval(poll, 1500);

    // Update blackboard every 5s
    updateBlackboard();
    setInterval(updateBlackboard, 5000);

    // AI status
    updateAiStatus();
    setInterval(updateAiStatus, 10000);

    // Cluster status (Redis agent registry)
    updateCluster();
    setInterval(updateCluster, 5000);

    // Preload Monaco editor in background (no await - runs silently)
    preloadFileEditor();
}

async function updateAiStatus() {
    const data = await getAiStatus();
    const badge = document.getElementById('ai-status-badge');
    if (data) {
        if (data.enabled) {
            badge.textContent = data.model || 'ON';
            badge.className = 'badge badge-on';
        } else {
            badge.textContent = 'OFF';
            badge.className = 'badge badge-off';
        }
        // Sync model selector
        const sel = document.getElementById('ai-model-select');
        if (data.model && sel) {
            for (const opt of sel.options) {
                if (opt.value === data.model) { sel.value = data.model; break; }
            }
        }
    }
}

async function updateCluster() {
    const data = await getCluster();
    const statusEl = document.getElementById('cluster-status');
    const nodesEl = document.getElementById('cluster-nodes');
    const countEl = document.getElementById('cluster-count');
    if (!data) {
        statusEl.innerHTML = '<span class="cluster-offline">Redis not connected</span>';
        nodesEl.innerHTML = '';
        countEl.textContent = '';
        return;
    }
    statusEl.innerHTML = data.redis
        ? '<span class="cluster-online">Redis connected</span>'
        : '<span class="cluster-offline">Redis not connected</span>';
    const nodes = data.nodes || [];
    const totalAgents = nodes.reduce((s, n) => s + (n.agents ? n.agents.length : 0), 0);
    countEl.textContent = nodes.length > 1 ? `(${nodes.length} nodes, ${totalAgents} agents)` : '';
    nodesEl.innerHTML = '';
    nodes.forEach(n => {
        const isMe = n.node === data.node;
        const div = document.createElement('div');
        div.className = 'cluster-node' + (isMe ? ' cluster-node-self' : '');
        const agentList = (n.agents || []).map(a =>
            `<span class="cluster-agent">${a}</span>`
        ).join('');
        div.innerHTML = `
            <div class="cluster-node-header">
                <span class="cluster-node-dot"></span>
                <span class="cluster-node-name">${n.node}</span>
                ${isMe ? '<span class="cluster-node-badge">this</span>' : ''}
            </div>
            <div class="cluster-agent-list">${agentList || '<em>no agents</em>'}</div>
        `;
        nodesEl.appendChild(div);
    });
}

document.addEventListener('DOMContentLoaded', init);
