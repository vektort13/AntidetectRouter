// Network Module for VEKTORT13
// Handles Interfaces, DHCP, Firewall, and Diagnostics

const API_BASE = '/cgi-bin/vektort13';

// Initialize network tabs
function initNetworkTabs() {
    const networkPage = document.getElementById('page-network');
    if (!networkPage) return;

    const tabBtns = networkPage.querySelectorAll('.tab-btn');
    const tabContents = networkPage.querySelectorAll('.tab-content');
    
    if (!tabBtns.length) return;

    if (networkPage.dataset.tabsBound === '1') {
        const activeBtn = networkPage.querySelector('.tab-btn.active');
        const activeTab = activeBtn ? activeBtn.dataset.tab : 'interfaces';

        switch(activeTab) {
            case 'interfaces': loadInterfaces(); break;
            case 'dhcp': loadDHCP(); break;
            case 'firewall': loadFirewall(); break;
        }
        return;
    }

    networkPage.dataset.tabsBound = '1';
    
    tabBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            const tabName = btn.dataset.tab;
            
            tabBtns.forEach(b => b.classList.remove('active'));
            tabContents.forEach(c => c.classList.remove('active'));
            
            btn.classList.add('active');
            const target = document.getElementById(`tab-${tabName}`);
            if (target) target.classList.add('active');
            
            switch(tabName) {
                case 'interfaces': loadInterfaces(); break;
                case 'dhcp': loadDHCP(); break;
                case 'firewall': loadFirewall(); break;
            }
        });
    });
    
    // AUTO-OPEN FIRST TAB: Interfaces
    const firstTabBtn = networkPage.querySelector('.tab-btn[data-tab="interfaces"]');
    const firstTabContent = document.getElementById('tab-interfaces');
    
    if (firstTabBtn && firstTabContent) {
        // Activate first button
        tabBtns.forEach(b => b.classList.remove('active'));
        firstTabBtn.classList.add('active');
        
        // Show first tab content
        tabContents.forEach(c => c.classList.remove('active'));
        firstTabContent.classList.add('active');
    }
    
    loadInterfaces();
}

// Load network interfaces
async function loadInterfaces() {
    const container = document.getElementById('interfaces-list');
    if (!container) return;
    
    container.innerHTML = '<div class="loading">Loading interfaces...</div>';
    
    try {
        const response = await fetch(`${API_BASE}/network-interfaces.sh?action=list`);
        const data = await response.json();
        
        if (data.status === 'ok') {
            container.innerHTML = data.interfaces.map(iface => `
                <div class="interface-card">
                    <div class="interface-header">
                        <span class="interface-name">${iface.name}</span>
                        <span class="interface-type ${iface.type}">${iface.type}</span>
                        <span class="status-badge ${iface.status}">${iface.status}</span>
                    </div>
                    <div class="interface-details">
                        <div class="detail-row">
                            <div class="detail-item">
                                <span class="label">IP:</span>
                                <span class="value">${iface.ip}</span>
                            </div>
                            <div class="detail-item">
                                <span class="label">MAC:</span>
                                <span class="value">${iface.mac}</span>
                            </div>
                        </div>
                        <div class="detail-row">
                            <div class="detail-item">
                                <span class="label">RX:</span>
                                <span class="value">${formatBytes(iface.rx_bytes)}</span>
                            </div>
                            <div class="detail-item">
                                <span class="label">TX:</span>
                                <span class="value">${formatBytes(iface.tx_bytes)}</span>
                            </div>
                        </div>
                        <div class="detail-row">
                            <div class="detail-item">
                                <span class="label">MTU:</span>
                                <span class="value">${iface.mtu}</span>
                            </div>
                            <div class="detail-item">
                                <span class="label">Speed:</span>
                                <span class="value">${iface.speed}</span>
                            </div>
                        </div>
                    </div>
                    <div class="interface-actions">
                        <button onclick="controlInterface('${iface.name}', 'up')" class="btn btn-success btn-sm">⬆ Up</button>
                        <button onclick="controlInterface('${iface.name}', 'down')" class="btn btn-danger btn-sm">⬇ Down</button>
                        <button onclick="controlInterface('${iface.name}', 'restart')" class="btn btn-primary btn-sm">🔄 Restart</button>
                    </div>
                </div>
            `).join('');
        } else {
            container.innerHTML = '<div class="error">Failed to load interfaces</div>';
        }
    } catch (err) {
        container.innerHTML = '<div class="error">Error loading interfaces</div>';
        console.error(err);
    }
}

// Control interface
window.controlInterface = async function(name, cmd) {
    if (typeof showToast === 'function') {
        showToast('Info', `${cmd} ${name}...`, 'info');
    }
    
    try {
        const response = await fetch(`${API_BASE}/network-interfaces.sh?action=control&interface=${name}&command=${cmd}`);
        const data = await response.json();
        
        if (data.status === 'ok') {
            if (typeof showToast === 'function') {
                showToast('Success', data.message, 'success');
            }
            setTimeout(loadInterfaces, 1000);
        } else {
            if (typeof showToast === 'function') {
                showToast('Error', data.message, 'error');
            }
        }
    } catch (err) {
        if (typeof showToast === 'function') {
            showToast('Error', 'Operation failed', 'error');
        }
    }
};

// Load DHCP & DNS
async function loadDHCP() {
    // Load leases
    const leasesContainer = document.getElementById('dhcp-leases');
    if (leasesContainer) {
        leasesContainer.innerHTML = '<div class="loading">Loading...</div>';
        
        try {
            const response = await fetch(`${API_BASE}/network-dhcp.sh?action=leases`);
            const data = await response.json();
            
            if (data.status === 'ok' && data.leases.length > 0) {
                leasesContainer.innerHTML = `
                    <table class="data-table">
                        <thead>
                            <tr>
                                <th>Hostname</th>
                                <th>IP Address</th>
                                <th>MAC Address</th>
                                <th>Expires</th>
                            </tr>
                        </thead>
                        <tbody>
                            ${data.leases.map(l => `
                                <tr>
                                    <td>${l.hostname || 'Unknown'}</td>
                                    <td>${l.ip}</td>
                                    <td>${l.mac}</td>
                                    <td>${l.expires}</td>
                                </tr>
                            `).join('')}
                        </tbody>
                    </table>
                `;
            } else {
                leasesContainer.innerHTML = '<div class="empty">No active leases</div>';
            }
        } catch (err) {
            leasesContainer.innerHTML = '<div class="error">Failed to load leases</div>';
        }
    }
    
    // Load DNS servers
    const dnsContainer = document.getElementById('dns-servers');
    if (dnsContainer) {
        try {
            const response = await fetch(`${API_BASE}/network-dhcp.sh?action=dns`);
            const data = await response.json();
            
            if (data.status === 'ok') {
                dnsContainer.innerHTML = `
                    <div class="dns-list">
                        ${data.dns_servers.map(dns => `<div class="dns-item">📡 ${dns}</div>`).join('')}
                    </div>
                `;
            }
        } catch (err) {
            dnsContainer.innerHTML = '<div class="error">Failed to load DNS</div>';
        }
    }
    
    // Load static leases
    const staticContainer = document.getElementById('static-leases');
    if (staticContainer) {
        try {
            const response = await fetch(`${API_BASE}/network-dhcp.sh?action=static`);
            const data = await response.json();
            
            if (data.status === 'ok' && data.static_leases.length > 0) {
                staticContainer.innerHTML = `
                    <table class="data-table">
                        <thead>
                            <tr>
                                <th>Name</th>
                                <th>IP</th>
                                <th>MAC</th>
                            </tr>
                        </thead>
                        <tbody>
                            ${data.static_leases.map(l => `
                                <tr>
                                    <td>${l.name}</td>
                                    <td>${l.ip}</td>
                                    <td>${l.mac}</td>
                                </tr>
                            `).join('')}
                        </tbody>
                    </table>
                `;
            } else {
                staticContainer.innerHTML = '<div class="empty">No static leases</div>';
            }
        } catch (err) {
            staticContainer.innerHTML = '<div class="error">Failed to load static leases</div>';
        }
    }
}

// Load Firewall rules
async function loadFirewall() {
    const container = document.getElementById('firewall-rules');
    if (!container) return;
    
    container.innerHTML = '<div class="loading">Loading rules...</div>';
    
    try {
        const response = await fetch(`${API_BASE}/network-firewall.sh?action=list`);
        const data = await response.json();
        
        if (data.status === 'ok' && data.rules.length > 0) {
            container.innerHTML = `
                <table class="data-table">
                    <thead>
                        <tr>
                            <th>Name</th>
                            <th>Source</th>
                            <th>Destination</th>
                            <th>Port</th>
                            <th>Action</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${data.rules.map(r => `
                            <tr>
                                <td>${r.name || 'Unnamed'}</td>
                                <td>${r.src}</td>
                                <td>${r.dest}</td>
                                <td>${r.port}</td>
                                <td><span class="badge ${r.target.toLowerCase()}">${r.target}</span></td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>
            `;
        } else {
            container.innerHTML = '<div class="empty">No firewall rules</div>';
        }
    } catch (err) {
        container.innerHTML = '<div class="error">Failed to load rules</div>';
    }
}

// Diagnostics tools
window.runDiagnostic = async function(tool) {
    let host, count, resultsDiv;
    
    switch(tool) {
        case 'ping':
            host = document.getElementById('ping-host').value;
            count = document.getElementById('ping-count').value;
            resultsDiv = document.getElementById('ping-results');
            resultsDiv.innerHTML = '<div class="loading">Pinging...</div>';
            
            try {
                const response = await fetch(`${API_BASE}/network-diagnostics.sh?action=ping&host=${encodeURIComponent(host)}&count=${count}`);
                const data = await response.json();
                
                if (data.status === 'ok') {
                    resultsDiv.innerHTML = `
                        <div class="results-success">
                            <h5>🏓 Results for ${data.host}:</h5>
                            ${data.results.map(r => `<div class="result-line">seq=${r.seq} time=${r.time} ttl=${r.ttl}</div>`).join('')}
                        </div>
                    `;
                }
            } catch (err) {
                resultsDiv.innerHTML = '<div class="error">Ping failed</div>';
            }
            break;
            
        case 'traceroute':
            host = document.getElementById('trace-host').value;
            resultsDiv = document.getElementById('trace-results');
            resultsDiv.innerHTML = '<div class="loading">Running traceroute...</div>';
            
            try {
                const response = await fetch(`${API_BASE}/network-diagnostics.sh?action=traceroute&host=${encodeURIComponent(host)}`);
                const data = await response.json();
                
                if (data.status === 'ok') {
                    resultsDiv.innerHTML = `
                        <div class="results-success">
                            <h5>🗺️ Route to ${data.host}:</h5>
                            ${data.hops.map(h => `<div class="result-line">${h.hop}. ${h.ip} - ${h.time}</div>`).join('')}
                        </div>
                    `;
                }
            } catch (err) {
                resultsDiv.innerHTML = '<div class="error">Traceroute failed</div>';
            }
            break;
            
        case 'nslookup':
            host = document.getElementById('nslookup-host').value;
            resultsDiv = document.getElementById('nslookup-results');
            resultsDiv.innerHTML = '<div class="loading">Looking up...</div>';
            
            try {
                const response = await fetch(`${API_BASE}/network-diagnostics.sh?action=nslookup&host=${encodeURIComponent(host)}`);
                const data = await response.json();
                
                if (data.status === 'ok') {
                    resultsDiv.innerHTML = `
                        <div class="results-success">
                            <h5>🔍 ${data.host} resolves to:</h5>
                            ${data.addresses.map(ip => `<div class="result-line">${ip}</div>`).join('')}
                        </div>
                    `;
                }
            } catch (err) {
                resultsDiv.innerHTML = '<div class="error">Lookup failed</div>';
            }
            break;
            
        case 'scan':
            resultsDiv = document.getElementById('scan-results');
            resultsDiv.innerHTML = '<div class="loading">Scanning network...</div>';
            
            try {
                const response = await fetch(`${API_BASE}/network-diagnostics.sh?action=scan`);
                const data = await response.json();
                
                if (data.status === 'ok') {
                    resultsDiv.innerHTML = `
                        <div class="results-success">
                            <h5>📡 Devices found:</h5>
                            <table class="data-table">
                                <thead>
                                    <tr><th>IP</th><th>MAC</th><th>State</th></tr>
                                </thead>
                                <tbody>
                                    ${data.devices.map(d => `
                                        <tr>
                                            <td>${d.ip}</td>
                                            <td>${d.mac}</td>
                                            <td>${d.state}</td>
                                        </tr>
                                    `).join('')}
                                </tbody>
                            </table>
                        </div>
                    `;
                }
            } catch (err) {
                resultsDiv.innerHTML = '<div class="error">Scan failed</div>';
            }
            break;
    }
};

// Helper: Format bytes
function formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

// Change DNS servers
window.changeDNS = function() {
    const currentDNS = prompt('Enter DNS servers (comma-separated)\nExample: 8.8.8.8,1.1.1.1', '8.8.8.8,1.1.1.1');
    
    if (!currentDNS) return;
    
    const dnsServers = currentDNS.split(',').map(d => d.trim()).filter(d => d);
    
    if (dnsServers.length === 0) {
        alert('Please enter at least one DNS server');
        return;
    }
    
    // Show loading
    const dnsContainer = document.getElementById('dns-servers');
    if (dnsContainer) {
        dnsContainer.innerHTML = '<div class="loading">Applying DNS changes...</div>';
    }
    
    // Send request to backend
    fetch(`${API_BASE}/network-dhcp.sh?action=set_dns&dns=${encodeURIComponent(dnsServers.join(','))}`)
        .then(r => r.json())
        .then(data => {
            if (data.status === 'ok') {
                alert('DNS servers updated successfully!\n\n' + dnsServers.join('\n'));
                // Reload DNS list
                setTimeout(() => {
                    loadDHCP();
                }, 1000);
            } else {
                alert('Failed to update DNS: ' + (data.message || 'Unknown error'));
            }
        })
        .catch(err => {
            alert('Error updating DNS: ' + err);
            console.error('DNS update error:', err);
        });
};

// Initialize when DOM ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
        setTimeout(initNetworkTabs, 500);
    });
} else {
    setTimeout(initNetworkTabs, 500);
}
