(function() {
    'use strict';

    function escapeHtml(value) {
        return String(value || '')
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function option(selected, value, label) {
        return `<option value="${value}" ${selected === value ? 'selected' : ''}>${label}</option>`;
    }

    window.generateNodeForm = function(protocol, node) {
        const n = node || {};
        const p = protocol || n.protocol || 'socks';

        return `
            <div class="form-grid">
                <div class="form-row">
                    <label>Node Remarks *:</label>
                    <input type="text" id="nc-remarks" value="${escapeHtml(n.remarks)}" class="select-input" placeholder="Node name">
                </div>
                <div class="form-row">
                    <label>Type:</label>
                    <select id="nc-type" class="select-input">
                        ${option(n.type || 'Xray', 'Xray', 'Xray')}
                        ${option(n.type || 'Xray', 'V2ray', 'V2ray')}
                    </select>
                </div>
                <div class="form-row">
                    <label>Protocol *:</label>
                    <select id="nc-protocol" class="select-input">
                        ${option(p, 'socks', 'Socks')}
                        ${option(p, 'vmess', 'VMess')}
                        ${option(p, 'vless', 'VLESS')}
                        ${option(p, 'http', 'HTTP')}
                        ${option(p, 'shadowsocks', 'Shadowsocks')}
                        ${option(p, 'trojan', 'Trojan')}
                        ${option(p, 'wireguard', 'WireGuard')}
                    </select>
                </div>
                <div class="form-row">
                    <label>Address *:</label>
                    <input type="text" id="nc-address" value="${escapeHtml(n.address)}" class="select-input" placeholder="IP or domain">
                </div>
                <div class="form-row">
                    <label>Port *:</label>
                    <input type="number" id="nc-port" value="${escapeHtml(n.port || '1080')}" class="select-input">
                </div>
                <div class="form-row">
                    <label>Username:</label>
                    <input type="text" id="nc-username" value="${escapeHtml(n.username)}" class="select-input" placeholder="Optional">
                </div>
                <div class="form-row">
                    <label>Password:</label>
                    <input type="password" id="nc-password" value="${escapeHtml(n.password)}" class="select-input" placeholder="Optional">
                </div>
                <div class="form-row">
                    <label>UUID / ID:</label>
                    <input type="text" id="nc-uuid" value="${escapeHtml(n.uuid)}" class="select-input" placeholder="For VMess/VLESS">
                </div>
                <div class="form-row">
                    <label>Encryption:</label>
                    <select id="nc-encryption" class="select-input">
                        ${option(n.encryption || 'auto', 'none', 'None')}
                        ${option(n.encryption || 'auto', 'auto', 'Auto')}
                        ${option(n.encryption || 'auto', 'aes-128-gcm', 'AES-128-GCM')}
                        ${option(n.encryption || 'auto', 'chacha20-poly1305', 'ChaCha20-Poly1305')}
                    </select>
                </div>
                <div class="form-row">
                    <label>Transport:</label>
                    <select id="nc-transport" class="select-input">
                        ${option(n.transport || 'tcp', 'tcp', 'TCP')}
                        ${option(n.transport || 'tcp', 'ws', 'WebSocket')}
                        ${option(n.transport || 'tcp', 'grpc', 'gRPC')}
                    </select>
                </div>
                <div class="form-row">
                    <label>TLS:</label>
                    <input type="checkbox" id="nc-tls" ${String(n.tls || '') === '1' ? 'checked' : ''} class="switch">
                </div>
            </div>
        `;
    };

    window.attachFormEventListeners = function(nodeId) {
        const saveBtn = document.getElementById('btn-save-node');
        const cancelBtn = document.getElementById('btn-cancel-node');

        if (saveBtn && typeof window.saveNodeConfig === 'function') {
            saveBtn.addEventListener('click', () => window.saveNodeConfig(nodeId || 'new'));
        }

        if (cancelBtn) {
            cancelBtn.addEventListener('click', () => {
                const tab = document.querySelector('.tab-btn[data-tab="nodelist"]');
                if (tab) tab.click();
            });
        }
    };
})();
