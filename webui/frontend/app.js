// ============================================
// VEKTORT13 Admin Panel - JavaScript v3.0
// Phase 2: VPN Control + Toast Notifications
// ============================================

(function() {
    'use strict';
    
    // ==================== CONFIG ====================
    
    const API_BASE = '/cgi-bin/vektort13';
    const UPDATE_INTERVAL = 5000; // 5 seconds - LIVE UPDATE!
    
    // ==================== TOAST NOTIFICATIONS ====================
    
    function showToast(title, message, type = 'info') {
        const container = document.getElementById('toast-container');
        
        const icons = {
            success: '✅',
            error: '❌',
            warning: '⚠️',
            info: 'ℹ️'
        };
        
        const toast = document.createElement('div');
        toast.className = `toast ${type}`;
        toast.innerHTML = `
            <div class="toast-icon">${icons[type]}</div>
            <div class="toast-content">
                <div class="toast-title">${title}</div>
                <div class="toast-message">${message}</div>
            </div>
            <button class="toast-close" onclick="this.parentElement.remove()">×</button>
        `;
        
        container.appendChild(toast);
        
        // Auto-remove after 5 seconds
        setTimeout(() => {
            toast.classList.add('removing');
            setTimeout(() => toast.remove(), 300);
        }, 5000);
    }
    
    // ==================== PAGE NAVIGATION ====================
    
    function initNavigation() {
        const menuItems = document.querySelectorAll('.menu-item');
        const pages = document.querySelectorAll('.page');
        
        console.log('Initializing navigation...');
        
        // Function to navigate to a page
        function navigateToPage(pageName) {
            console.log('Navigating to:', pageName);
            
            // Update active menu item
            menuItems.forEach(mi => {
                const miPage = mi.getAttribute('data-page');
                if (miPage === pageName) {
                    mi.classList.add('active');
                } else {
                    mi.classList.remove('active');
                }
            });
            
            // Show target page
            pages.forEach(page => {
                page.classList.remove('active');
                if (page.id === `page-${pageName}`) {
                    page.classList.add('active');
                    
                    // Trigger updates for specific pages
                    if (pageName === 'dashboard') {
                        console.log('→ Updating Dashboard');
                        updateDashboard();
                        // Start auto-update for Dashboard latency every 5 seconds
                        if (dashboardUpdateInterval) clearInterval(dashboardUpdateInterval);
                        dashboardUpdateInterval = setInterval(updateDashboard, 5000);
                        // Stop OpenVPN auto-update
                        if (openvpnUpdateInterval) {
                            clearInterval(openvpnUpdateInterval);
                            openvpnUpdateInterval = null;
                        }
                    } else if (pageName === 'openvpn') {
                        console.log('→ Loading OpenVPN');
                        loadOpenVPNConfigs();
                        // Start auto-update every 5 seconds to catch status changes
                        if (openvpnUpdateInterval) clearInterval(openvpnUpdateInterval);
                        openvpnUpdateInterval = setInterval(loadOpenVPNConfigs, 5000);
                        // Stop Dashboard auto-update
                        if (dashboardUpdateInterval) {
                            clearInterval(dashboardUpdateInterval);
                            dashboardUpdateInterval = null;
                        }
                    } else if (pageName === 'passwall') {
                        console.log('→ Loading Passwall Settings (force)');
                        // Stop OpenVPN auto-update
                        if (openvpnUpdateInterval) {
                            clearInterval(openvpnUpdateInterval);
                            openvpnUpdateInterval = null;
                        }
                        // Stop Dashboard auto-update
                        if (dashboardUpdateInterval) {
                            clearInterval(dashboardUpdateInterval);
                            dashboardUpdateInterval = null;
                        }
                        // Initialize tabs first
                        initPasswallTabs();
                        // Then load settings
                        setTimeout(() => {
                            loadPasswallSettings();
                        }, 50);
                    } else if (pageName === 'network') {
                        console.log('→ Loading Network');
                        // Stop OpenVPN auto-update
                        if (openvpnUpdateInterval) {
                            clearInterval(openvpnUpdateInterval);
                            openvpnUpdateInterval = null;
                        }
                        // Stop Dashboard auto-update
                        if (dashboardUpdateInterval) {
                            clearInterval(dashboardUpdateInterval);
                            dashboardUpdateInterval = null;
                        }
                        if (typeof initNetworkTabs === 'function') {
                            setTimeout(initNetworkTabs, 100);
                        }
                    } else if (pageName === 'logs') {
                        console.log('→ Updating Logs');
                        // Stop OpenVPN auto-update
                        if (openvpnUpdateInterval) {
                            clearInterval(openvpnUpdateInterval);
                            openvpnUpdateInterval = null;
                        }
                        // Stop Dashboard auto-update
                        if (dashboardUpdateInterval) {
                            clearInterval(dashboardUpdateInterval);
                            dashboardUpdateInterval = null;
                        }
                        updateLogs();
                    }
                }
            });
        }
        
        // Handle hash changes
        function handleHashChange() {
            const hash = window.location.hash.replace('#/', '') || 'dashboard';
            navigateToPage(hash);
        }
        
        // Listen for hash changes
        window.addEventListener('hashchange', handleHashChange);
        
        // Handle initial hash on page load
        handleHashChange();
        
        // Menu item clicks
        menuItems.forEach(item => {
            item.addEventListener('click', (e) => {
                e.preventDefault();
                const targetPage = item.getAttribute('data-page');
                window.location.hash = `#/${targetPage}`;
            });
        });
    }
    
    // ==================== DASHBOARD UPDATES ====================
    
    function updateSystemStatus() {
        fetch(`${API_BASE}/status.sh`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok') {
                    document.getElementById('cpu-usage').textContent = data.data.cpu + '%';
                    document.getElementById('ram-usage').textContent = data.data.ram + '%';
                    document.getElementById('uptime').textContent = data.data.uptime;
                }
            })
            .catch(err => console.error('Status error:', err));
    }
    
    function updateConnectionInfo() {
        fetch(`${API_BASE}/status.sh`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok' && data.vpn) {
                    const vpn = data.vpn;
                    
                    // Update VPN status badge
                    const badge = document.getElementById('vpn-status-badge');
                    if (badge) {
                        badge.textContent = vpn.status || 'Unknown';
                        badge.className = vpn.status === 'Active' ? 'badge badge-success' : 'badge badge-danger';
                    }
                    
                    // Update mode
                    const mode = document.getElementById('vpn-mode');
                    if (mode) mode.textContent = vpn.mode || '--';
                    
                    // Update IP
                    const ip = document.getElementById('public-ip');
                    if (ip) ip.textContent = vpn.publicIp || 'N/A';
                    
                    // Update location
                    const location = document.getElementById('location');
                    if (location) {
                        location.textContent = vpn.location || 'Unknown, Unknown, Unknown';
                    }
                    
                    // Update latency
                    const latency = document.getElementById('latency');
                    if (latency) {
                        latency.textContent = vpn.latency || 'N/A';
                        
                        // Color based on latency value
                        const latencyMatch = vpn.latency ? vpn.latency.match(/(\d+\.?\d*)/) : null;
                        if (latencyMatch) {
                            const latencyValue = parseFloat(latencyMatch[1]);
                            if (!isNaN(latencyValue)) {
                                if (latencyValue < 60) {
                                    latency.className = 'latency-good';
                                } else if (latencyValue < 100) {
                                    latency.className = 'latency-fair';
                                } else {
                                    latency.className = 'latency-poor';
                                }
                            }
                        }
                    }
                }
            })
            .catch(err => console.error('Connection info error:', err));
    }
    
    function updateConnectionHistory() {
        fetch(`${API_BASE}/connection-history.sh?action=read`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok') {
                    const container = document.getElementById('connection-history');
                    if (!container) return;
                    
                    // Filter out N/A entries
                    const validEntries = data.entries.filter(entry => 
                        entry.latency !== 'N/A' && 
                        entry.ip !== 'N/A' && 
                        entry.mode !== 'Unknown'
                    );
                    
                    if (validEntries.length === 0) {
                        container.innerHTML = '<div class="history-loading">No history yet...</div>';
                        return;
                    }
                    
                    // Reverse to show newest first
                    const entries = validEntries.reverse();
                    
                    container.innerHTML = entries.map(entry => {
                        // Parse latency value
                        const latencyValue = parseFloat(entry.latency);
                        let latencyClass = '';
                        if (!isNaN(latencyValue)) {
                            if (latencyValue < 60) latencyClass = 'good';
                            else if (latencyValue < 100) latencyClass = 'fair';
                            else latencyClass = 'poor';
                        }
                        
                        // Format: TIME | LATENCY | IP (MODE)
                        return `
                            <div class="history-entry">
                                <span class="history-time">${entry.timestamp}</span>
                                <span class="history-latency ${latencyClass}">${entry.latency}</span>
                                <span class="history-ip">${entry.ip}</span>
                                <span class="history-mode">${entry.mode}</span>
                            </div>
                        `;
                    }).join('');
                }
            })
            .catch(err => console.error('Connection history error:', err));
    }
    
    function updateDashboard() {
        updateSystemStatus();
        updateConnectionInfo();
        updateConnectionHistory();
    }
    
    // ==================== VPN CONTROL ====================
    
    function updateVPNStatus() {
        // Update Passwall status
        fetch(`${API_BASE}/vpn-control.sh?vpn=passwall&action=status`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok' && data.data) {
                    const indicator = document.getElementById('passwall-indicator');
                    const statusText = document.getElementById('passwall-status-text');
                    
                    if (indicator && statusText) {
                        if (data.data.running) {
                            indicator.classList.add('active');
                            statusText.textContent = 'Active';
                        } else {
                            indicator.classList.remove('active');
                            statusText.textContent = 'Inactive';
                        }
                    }
                }
            })
            .catch(err => console.error('Passwall status error:', err));
        
        // Update OpenVPN status
        fetch(`${API_BASE}/vpn-control.sh?vpn=openvpn&action=status`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok' && data.data) {
                    const indicator = document.getElementById('openvpn-indicator');
                    const statusText = document.getElementById('openvpn-status-text');
                    
                    if (indicator && statusText) {
                        if (data.data.running) {
                            indicator.classList.add('active');
                            statusText.textContent = 'Active';
                        } else {
                            indicator.classList.remove('active');
                            statusText.textContent = 'Inactive';
                        }
                    }
                }
            })
            .catch(err => console.error('OpenVPN status error:', err));
    }
    
    async function controlVPN(vpn, action, button) {
        // Show loading
        button.classList.add('loading');
        button.disabled = true;
        
        try {
            const response = await fetch(`${API_BASE}/vpn-control.sh?vpn=${vpn}&action=${action}`);
            const data = await response.json();
            
            // Remove loading
            button.classList.remove('loading');
            button.disabled = false;
            
            if (data.result === 'success') {
                // Success toast
                const vpnName = vpn === 'passwall' ? 'Passwall' : 'OpenVPN';
                const actionText = action === 'start' ? 'подключен' : action === 'stop' ? 'отключен' : 'перезапущен';
                
                showToast(
                    `${vpnName} ${actionText}`,
                    data.message,
                    'success'
                );
                
                // Update VPN status immediately
                setTimeout(() => {
                    updateVPNStatus();
                    updateConnectionInfo(); // Update dashboard too
                }, 1000);
            } else {
                // Error toast
                showToast(
                    'Ошибка',
                    data.message || `Failed to ${action} ${vpn}`,
                    'error'
                );
            }
        } catch (error) {
            // Remove loading
            button.classList.remove('loading');
            button.disabled = false;
            
            // Error toast
            showToast(
                'Ошибка подключения',
                'Не удалось выполнить команду. Проверьте соединение с роутером.',
                'error'
            );
            console.error('VPN control error:', error);
        }
    }
    
    function initVPNButtons() {
        const buttons = document.querySelectorAll('.vpn-buttons .btn');
        
        buttons.forEach(btn => {
            btn.addEventListener('click', function() {
                const vpn = this.getAttribute('data-vpn');
                const action = this.getAttribute('data-action');
                
                if (!vpn || !action) return;
                
                // Confirmation for stop action
                if (action === 'stop') {
                    if (!confirm(`Отключить ${vpn === 'passwall' ? 'Passwall' : 'OpenVPN'}?`)) {
                        return;
                    }
                }
                
                // Execute control
                controlVPN(vpn, action, this);
            });
        });
    }
    
    // ==================== LOGOUT ====================
    
    function initLogout() {
        const logoutBtn = document.querySelector('.logout-btn');
        
        logoutBtn.addEventListener('click', () => {
            if (confirm('Are you sure you want to logout?')) {
                window.location.href = '/cgi-bin/luci/admin/logout';
            }
        });
    }
    
    // ==================== LINK ITEMS ====================
    
    function initLinkItems() {
        const linkItems = document.querySelectorAll('.link-item');
        
        linkItems.forEach(link => {
            link.addEventListener('click', (e) => {
                if (link.getAttribute('href') === '#') {
                    e.preventDefault();
                    const linkText = link.querySelector('span:nth-child(2)').textContent;
                    showToast('Переход', `Открытие ${linkText}...`, 'info');
                }
            });
        });
    }
    
    // ==================== LOGS PAGE ====================

    function initLogs() {
        // Legacy hook kept for compatibility.
    }

    function updateLogs() {
        const logContentEl = document.getElementById('system-log-content');
        if (!logContentEl) return;

        fetch(`${API_BASE}/logs.sh`)
            .then(r => r.text())
            .then(logs => {
                logContentEl.textContent = logs;
                const logContainer = document.getElementById('system-log-container');
                if (logContainer) {
                    logContainer.scrollTop = logContainer.scrollHeight;
                }
            })
            .catch(err => console.error('Logs error:', err));
    }
    
    // ==================== AUTO-UPDATE ====================
    
    function startAutoUpdate() {
        // Update dashboard data every 30 seconds if on dashboard page
        setInterval(() => {
            const dashboardPage = document.getElementById('page-dashboard');
            if (dashboardPage && dashboardPage.classList.contains('active')) {
                updateSystemStatus();
                updateConnectionInfo();
            }
            
            // Update VPN status on VPN page
            const vpnPage = document.getElementById('page-openvpn');
            if (vpnPage && vpnPage.classList.contains('active')) {
                updateVPNStatus();
            }
        }, UPDATE_INTERVAL);
    }
    
    // ==================== PASSWALL SETTINGS ====================
    
    let currentNodes = [];
    let selectedNodeId = null;
    let pwLogPaused = false;
    
    // Init Passwall tabs
    function initPasswallTabs() {
        const passwallPage = document.getElementById('page-passwall');
        if (!passwallPage) return;

        const tabBtns = passwallPage.querySelectorAll('.tab-btn');
        const tabContents = passwallPage.querySelectorAll('.tab-content');
        
        console.log('Initializing Passwall tabs...');
        
        tabBtns.forEach(btn => {
            btn.addEventListener('click', function() {
                const targetTab = this.getAttribute('data-tab');
                
                console.log('Passwall tab clicked:', targetTab);
                
                // Update active tab button
                tabBtns.forEach(b => b.classList.remove('active'));
                this.classList.add('active');
                
                // Show target tab content
                tabContents.forEach(content => {
                    content.classList.remove('active');
                    if (content.id === `tab-${targetTab}`) {
                        content.classList.add('active');
                        
                        // Load data when tab is opened (LIVE UPDATE!)
                        if (targetTab === 'basic') {
                            console.log('→ Loading Basic Settings...');
                            loadPasswallSettings();
                        } else if (targetTab === 'nodelist') {
                            console.log('→ Loading Node List...');
                            loadNodeList();
                        } else if (targetTab === 'nodeconfig') {
                            console.log('→ Node Config (loads on edit)');
                        } else if (targetTab === 'passwallogs') {
                            console.log('→ Loading Passwall Logs...');
                            loadPasswallLogs();
                        }
                    }
                });
            });
        });
        
        // AUTO-OPEN FIRST TAB: Basic Settings
        console.log('Auto-opening first Passwall tab: Basic Settings');
        const firstTabBtn = passwallPage.querySelector('.tab-btn[data-tab="basic"]');
        const firstTabContent = document.getElementById('tab-basic');
        
        if (firstTabBtn && firstTabContent) {
            // Activate first button
            tabBtns.forEach(b => b.classList.remove('active'));
            firstTabBtn.classList.add('active');
            
            // Show first tab content
            tabContents.forEach(c => c.classList.remove('active'));
            firstTabContent.classList.add('active');
        }
        
        // ВАЖНО: Принудительная загрузка Basic Settings при инициализации
        console.log('Initial Passwall load: Basic Settings');
        setTimeout(() => {
            loadPasswallSettings();
        }, 100);
    }
    
    // Load Passwall settings
    function loadPasswallSettings() {
        console.log('Loading Passwall settings...');
        
        // Load current settings
        fetch(`${API_BASE}/passwall-settings.sh?action=get`)
            .then(r => r.json())
            .then(data => {
                console.log('Passwall settings loaded:', data);
                
                if (data.status === 'ok') {
                    const d = data.data;
                    
                    // Set enabled switches
                    const pwEnabled = document.getElementById('pw-enabled');
                    const socksEnabled = document.getElementById('pw-socks-enabled');
                    
                    if (pwEnabled) pwEnabled.checked = d.enabled == 1;
                    if (socksEnabled) socksEnabled.checked = d.socks_enabled == 1;
                    
                    // Set DNS settings
                    const dnsMode = document.getElementById('pw-dns-mode');
                    const dnsShunt = document.getElementById('pw-dns-shunt');
                    const remoteDns = document.getElementById('pw-remote-dns');
                    const filterIpv6 = document.getElementById('pw-filter-ipv6');
                    const dnsRedirect = document.getElementById('pw-dns-redirect');
                    const forceHttps = document.getElementById('pw-force-https');
                    
                    if (dnsMode) dnsMode.value = d.dns_mode || 'tcp';
                    if (dnsShunt) dnsShunt.value = d.dns_shunt || 'chinadns-ng';
                    if (remoteDns) remoteDns.value = d.remote_dns || '1.1.1.1';
                    if (filterIpv6) filterIpv6.checked = d.filter_proxy_ipv6 == 1;
                    if (dnsRedirect) dnsRedirect.checked = d.dns_redirect == 1;
                    if (forceHttps) forceHttps.checked = d.force_https_soa == 1;
                    
                    // Load nodes list for dropdowns
                    loadNodesForDropdowns(d.tcp_node, d.udp_node, d.socks_node);
                }
            })
            .catch(err => {
                console.error('Load settings error:', err);
                showToast('Error', 'Failed to load settings: ' + err.message, 'error');
            });
    }
    
    // Load nodes for dropdowns
    function loadNodesForDropdowns(tcpNode, udpNode, socksNode) {
        console.log('Loading nodes for dropdowns...', {tcpNode, udpNode, socksNode});
        
        fetch(`${API_BASE}/passwall-nodes.sh?action=list`)
            .then(r => r.json())
            .then(data => {
                console.log('Nodes API response:', data);
                
                if (data.status === 'ok' && data.nodes) {
                    currentNodes = data.nodes;
                    
                    // Populate dropdowns
                    const tcpSelect = document.getElementById('pw-tcp-node');
                    const udpSelect = document.getElementById('pw-udp-node');
                    const socksSelect = document.getElementById('pw-socks-node');
                    
                    if (!tcpSelect || !udpSelect || !socksSelect) {
                        console.error('Dropdown elements not found!');
                        return;
                    }
                    
                    // Clear and add default options
                    tcpSelect.innerHTML = '<option value="nil">None</option>';
                    udpSelect.innerHTML = '<option value="nil">None</option><option value="tcp">Same as TCP</option>';
                    socksSelect.innerHTML = '<option value="nil">None</option>';
                    
                    // Add nodes
                    data.nodes.forEach(node => {
                        // Skip shunt nodes
                        if (node.protocol === '_shunt') {
                            return;
                        }
                        
                        const option = `<option value="${node.id}">${node.name || node.id}</option>`;
                        tcpSelect.innerHTML += option;
                        udpSelect.innerHTML += option;
                        socksSelect.innerHTML += option;
                    });
                    
                    // Set selected values (handle empty/nil values)
                    tcpSelect.value = tcpNode && tcpNode !== 'nil' ? tcpNode : 'nil';
                    udpSelect.value = udpNode && udpNode !== 'nil' ? udpNode : 'nil';
                    socksSelect.value = socksNode && socksNode !== 'nil' ? socksNode : 'nil';
                    
                    console.log('Dropdowns populated successfully', {
                        tcpSelected: tcpSelect.value,
                        udpSelected: udpSelect.value,
                        socksSelected: socksSelect.value
                    });
                } else {
                    console.error('Invalid nodes response:', data);
                    showToast('Error', 'Failed to load nodes', 'error');
                }
            })
            .catch(err => {
                console.error('Load nodes error:', err);
                showToast('Error', 'Failed to load nodes: ' + err.message, 'error');
            });
    }
    
    // Save Passwall settings
    function savePasswallSettings(apply = false) {
        const enabled = document.getElementById('pw-enabled').checked ? '1' : '0';
        const socksEnabled = document.getElementById('pw-socks-enabled').checked ? '1' : '0';
        const tcpNode = document.getElementById('pw-tcp-node').value;
        const udpNode = document.getElementById('pw-udp-node').value;
        const socksNode = document.getElementById('pw-socks-node').value;
        
        // DNS settings
        const dnsMode = document.getElementById('pw-dns-mode').value;
        const dnsShunt = document.getElementById('pw-dns-shunt').value;
        const remoteDns = document.getElementById('pw-remote-dns').value;
        const filterIpv6 = document.getElementById('pw-filter-ipv6').checked ? '1' : '0';
        const dnsRedirect = document.getElementById('pw-dns-redirect').checked ? '1' : '0';
        const forceHttps = document.getElementById('pw-force-https').checked ? '1' : '0';
        
        const params = `action=set&enabled=${enabled}&socks_enabled=${socksEnabled}&tcp_node=${tcpNode}&udp_node=${udpNode}&socks_node=${socksNode}&dns_mode=${dnsMode}&dns_shunt=${dnsShunt}&remote_dns=${encodeURIComponent(remoteDns)}&filter_ipv6=${filterIpv6}&dns_redirect=${dnsRedirect}&force_https=${forceHttps}`;
        
        console.log('Saving Passwall settings:', params);
        
        fetch(`${API_BASE}/passwall-settings.sh?${params}`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok') {
                    showToast('Settings Saved', data.message, 'success');
                    
                    // Apply if requested
                    if (apply) {
                        applyPasswallSettings();
                    }
                } else {
                    showToast('Error', data.message, 'error');
                }
            })
            .catch(err => {
                showToast('Error', 'Failed to save settings', 'error');
                console.error('Save error:', err);
            });
    }
    
    // Apply Passwall settings (restart)
    function applyPasswallSettings() {
        showToast('Applying...', 'Restarting Passwall...', 'info');
        
        fetch(`${API_BASE}/passwall-settings.sh?action=apply`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok') {
                    showToast('Applied', 'Passwall restarting...', 'success');
                    
                    // Update dashboard after 3 seconds
                    setTimeout(() => {
                        updateConnectionInfo();
                        updateVPNStatus();
                    }, 3000);
                }
            })
            .catch(err => console.error('Apply error:', err));
    }
    
    // Init Passwall buttons
    
    // ==================== TOAST NOTIFICATION ====================
    function showNotification(message, type = 'info') {
        const existingToast = document.querySelector('.toast-notification');
        if (existingToast) existingToast.remove();
        
        const toast = document.createElement('div');
        toast.className = `toast-notification toast-${type}`;
        toast.textContent = message;
        
        const icon = document.createElement('span');
        icon.className = 'toast-icon';
        icon.textContent = type === 'success' ? '✓' : (type === 'error' ? '✗' : 'ℹ');
        toast.insertBefore(icon, toast.firstChild);
        
        document.body.appendChild(toast);
        setTimeout(() => toast.classList.add('show'), 10);
        setTimeout(() => {
            toast.classList.remove('show');
            setTimeout(() => toast.remove(), 300);
        }, 3000);
    }
    
    // ==================== STOP PASSWALL ====================
    function stopPasswall() {
        if (!confirm('Stop Passwall service?')) return;
        
        const btnStop = document.getElementById('btn-pw-stop');
        if (!btnStop) return;
        
        btnStop.disabled = true;
        let dotCount = 0;
        const animateButton = setInterval(() => {
            dotCount = (dotCount + 1) % 4;
            btnStop.textContent = 'Stopping' + '.'.repeat(dotCount);
        }, 400);
        
        fetch(`${API_BASE}/passwall-settings.sh?action=stop`)
            .then(r => r.json())
            .then(data => {
                clearInterval(animateButton);
                if (data.status === 'ok') {
                    showNotification(data.message || 'Passwall stopped successfully', 'success');
                    const pwEnabled = document.getElementById('pw-enabled');
                    const socksEnabled = document.getElementById('pw-socks-enabled');
                    if (pwEnabled) pwEnabled.checked = false;
                    if (socksEnabled) socksEnabled.checked = false;
                    btnStop.textContent = 'Stop';
                    btnStop.disabled = false;
                    setTimeout(() => loadPasswallSettings(), 1500);
                } else {
                    showNotification(data.message || 'Failed to stop Passwall', 'error');
                    btnStop.textContent = 'Stop';
                    btnStop.disabled = false;
                }
            })
            .catch(err => {
                clearInterval(animateButton);
                console.error('Stop error:', err);
                showNotification('Failed to stop Passwall', 'error');
                btnStop.textContent = 'Stop';
                btnStop.disabled = false;
            });
    }
    
    function initPasswallButtons() {
        const btnSave = document.getElementById('btn-pw-save');
        const btnApply = document.getElementById('btn-pw-apply');
        const btnAddNode = document.getElementById('btn-add-node');
        
        if (btnSave) {
            btnSave.addEventListener('click', () => savePasswallSettings(false));
        }
        
        if (btnApply) {
            btnApply.addEventListener('click', () => savePasswallSettings(true));
        }
        
        const btnStop = document.getElementById('btn-pw-stop');
        if (btnStop) {
            btnStop.addEventListener('click', stopPasswall);
        }
        
        if (btnAddNode) {
            btnAddNode.addEventListener('click', () => {
                // Switch to Node Config tab
                const nodeConfigTab = document.querySelector('.tab-btn[data-tab="nodeconfig"]');
                if (nodeConfigTab) {
                    nodeConfigTab.click();
                }
                
                // Render empty form for new node
                renderNewNodeForm();
            });
        }
    }
    
    // ==================== NODE LIST ====================
    
    // Load node list
    function loadNodeList() {
        const container = document.getElementById('node-list-container');
        container.innerHTML = '<p>Loading nodes...</p>';
        
        fetch(`${API_BASE}/passwall-nodes.sh?action=list`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok') {
                    currentNodes = data.nodes;
                    renderNodeList(data.nodes);
                } else {
                    container.innerHTML = '<p>Error loading nodes</p>';
                }
            })
            .catch(err => {
                console.error('Load nodes error:', err);
                container.innerHTML = '<p>Error loading nodes</p>';
            });
    }
    
    // Render node list
    function renderNodeList(nodes) {
        const container = document.getElementById('node-list-container');
        
        if (nodes.length === 0) {
            container.innerHTML = '<p>No nodes configured. Click "Add Node" to create one.</p>';
            return;
        }
        
        let html = '';
        
        nodes.forEach(node => {
            html += `
                <div class="node-item" data-node-id="${node.id}">
                    <div class="node-info">
                        <div class="node-title">${node.name || 'Unknown'}</div>
                        <div class="node-details">
                            ${node.type} / ${node.protocol || 'N/A'}
                        </div>
                    </div>
                    <div class="node-latency" data-node-id="${node.id}">
                        <button class="btn-icon" onclick="pingNode('${node.id}')" title="Test">🔄</button>
                    </div>
                    <div class="node-actions">
                        <button class="btn-icon" onclick="editNode('${node.id}')" title="Edit">✏️</button>
                        <button class="btn-icon delete" onclick="deleteNode('${node.id}')" title="Delete">🗑️</button>
                    </div>
                </div>
            `;
        });
        
        container.innerHTML = html;
    }
    
    // Ping node (global function for onclick)
    window.pingNode = function(nodeId) {
        const latencyEl = document.querySelector(`.node-latency[data-node-id="${nodeId}"]`);
        const originalHtml = latencyEl.innerHTML;
        latencyEl.innerHTML = '<span style="color: #999;">...</span>';
        
        fetch(`${API_BASE}/passwall-nodes.sh?action=ping&node=${nodeId}`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok') {
                    latencyEl.innerHTML = `<span style="color: var(--status-success);">${data.latency}</span>`;
                } else {
                    latencyEl.innerHTML = '<span style="color: var(--status-danger);">Failed</span>';
                }
                
                // Reset after 5 seconds
                setTimeout(() => {
                    latencyEl.innerHTML = originalHtml;
                }, 5000);
            })
            .catch(err => {
                latencyEl.innerHTML = '<span style="color: var(--status-danger);">Error</span>';
                setTimeout(() => {
                    latencyEl.innerHTML = originalHtml;
                }, 5000);
            });
    };
    
    // Edit node (global function for onclick)
    window.editNode = function(nodeId) {
        selectedNodeId = nodeId;
        
        // Switch to Node Config tab
        document.querySelector('.tab-btn[data-tab="nodeconfig"]').click();
        
        // Load node details
        loadNodeConfig(nodeId);
    };
    
    // Delete node (global function for onclick)
    window.deleteNode = function(nodeId) {
        const node = currentNodes.find(n => n.id === nodeId);
        const nodeName = node ? node.remarks : nodeId;
        
        if (!confirm(`Delete node "${nodeName}"?`)) {
            return;
        }
        
        fetch(`${API_BASE}/passwall-nodes.sh?action=delete&node=${nodeId}`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok') {
                    showToast('Deleted', data.message, 'success');
                    loadNodeList(); // Reload list
                } else {
                    showToast('Error', data.message, 'error');
                }
            })
            .catch(err => {
                showToast('Error', 'Failed to delete node', 'error');
                console.error('Delete error:', err);
            });
    };
    
    // ==================== NODE CONFIG ====================
    
    // Load node config
    function loadNodeConfig(nodeId) {
        const container = document.getElementById('node-config-form');
        container.innerHTML = '<p>Loading node configuration...</p>';
        
        fetch(`${API_BASE}/passwall-nodes.sh?action=get&node=${nodeId}`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok') {
                    renderNodeConfigForm(data.node);
                } else {
                    container.innerHTML = '<p>Error loading node</p>';
                }
            })
            .catch(err => {
                console.error('Load node config error:', err);
                container.innerHTML = '<p>Error loading node</p>';
            });
    }
    
    // Render node config form
    function renderNodeConfigForm(node) {
        const container = document.getElementById('node-config-form');
        
        container.innerHTML = `
            <div class="form-grid">
                <div class="form-row">
                    <label>Node Remarks:</label>
                    <input type="text" id="nc-remarks" value="${node.remarks}" class="select-input">
                </div>
                
                <div class="form-row">
                    <label>Type:</label>
                    <select id="nc-type" class="select-input">
                        <option value="Xray" ${node.type === 'Xray' ? 'selected' : ''}>Xray</option>
                        <option value="V2ray" ${node.type === 'V2ray' ? 'selected' : ''}>V2ray</option>
                    </select>
                </div>
                
                <div class="form-row">
                    <label>Protocol:</label>
                    <select id="nc-protocol" class="select-input">
                        <option value="vmess" ${node.protocol === 'vmess' ? 'selected' : ''}>VMess</option>
                        <option value="vless" ${node.protocol === 'vless' ? 'selected' : ''}>VLESS</option>
                        <option value="socks" ${node.protocol === 'socks' ? 'selected' : ''}>Socks</option>
                        <option value="http" ${node.protocol === 'http' ? 'selected' : ''}>HTTP</option>
                        <option value="shadowsocks" ${node.protocol === 'shadowsocks' ? 'selected' : ''}>Shadowsocks</option>
                        <option value="trojan" ${node.protocol === 'trojan' ? 'selected' : ''}>Trojan</option>
                        <option value="wireguard" ${node.protocol === 'wireguard' ? 'selected' : ''}>WireGuard</option>
                        <option value="_balancing" ${node.protocol === '_balancing' ? 'selected' : ''}>Balancing</option>
                        <option value="_shunt" ${node.protocol === '_shunt' ? 'selected' : ''}>Shunt</option>
                        <option value="_iface" ${node.protocol === '_iface' ? 'selected' : ''}>Custom Interface</option>
                    </select>
                </div>
                
                <div class="form-row">
                    <label>Address:</label>
                    <input type="text" id="nc-address" value="${node.address}" class="select-input">
                </div>
                
                <div class="form-row">
                    <label>Port:</label>
                    <input type="number" id="nc-port" value="${node.port}" class="select-input">
                </div>
                
                <div class="form-row">
                    <label>Username:</label>
                    <input type="text" id="nc-username" value="${node.username || ''}" class="select-input" placeholder="For SOCKS protocol">
                </div>
                
                <div class="form-row">
                    <label>Password:</label>
                    <input type="text" id="nc-password" value="${node.password || ''}" class="select-input" placeholder="For SOCKS protocol">
                </div>
                
                <div class="form-row">
                    <label>UUID / ID:</label>
                    <input type="text" id="nc-uuid" value="${node.uuid}" class="select-input">
                </div>
                
                <div class="form-row">
                    <label>Encryption:</label>
                    <select id="nc-encryption" class="select-input">
                        <option value="none" ${node.encryption === 'none' ? 'selected' : ''}>None</option>
                        <option value="auto" ${node.encryption === 'auto' ? 'selected' : ''}>Auto</option>
                        <option value="aes-128-gcm" ${node.encryption === 'aes-128-gcm' ? 'selected' : ''}>AES-128-GCM</option>
                        <option value="chacha20-poly1305" ${node.encryption === 'chacha20-poly1305' ? 'selected' : ''}>ChaCha20-Poly1305</option>
                    </select>
                </div>
                
                <div class="form-row">
                    <label>Transport:</label>
                    <select id="nc-transport" class="select-input">
                        <option value="tcp" ${node.transport === 'tcp' ? 'selected' : ''}>TCP</option>
                        <option value="ws" ${node.transport === 'ws' ? 'selected' : ''}>WebSocket</option>
                        <option value="grpc" ${node.transport === 'grpc' ? 'selected' : ''}>gRPC</option>
                    </select>
                </div>
                
                <div class="form-row">
                    <label>TLS:</label>
                    <input type="checkbox" id="nc-tls" ${node.tls == '1' ? 'checked' : ''} class="switch">
                </div>
            </div>
            
            <div class="button-group">
                <button class="btn btn-success" id="btn-save-node">Save Node</button>
                <button class="btn btn-primary" id="btn-test-node">Test Connection</button>
                <button class="btn btn-secondary" id="btn-cancel-node">Cancel</button>
            </div>
        `;
        
        // Attach event listeners
        document.getElementById('btn-save-node').addEventListener('click', () => saveNodeConfig(node.id));
        document.getElementById('btn-test-node').addEventListener('click', () => pingNode(node.id));
        document.getElementById('btn-cancel-node').addEventListener('click', () => {
            document.querySelector('.tab-btn[data-tab="nodelist"]').click();
        });
    }
    
    // Render new node form
    function renderNewNodeForm() {
        const container = document.getElementById('node-config-form');
        const protocol = 'socks'; // Default protocol
        
        const formHtml = window.generateNodeForm ? window.generateNodeForm(protocol, null) : generateFallbackForm();
        
        container.innerHTML = `
            ${formHtml}
            <div class="button-group">
                <button class="btn btn-success" id="btn-save-node">Create Node</button>
                <button class="btn btn-secondary" id="btn-cancel-node">Cancel</button>
            </div>
        `;
        
        // Attach event listeners
        if (window.attachFormEventListeners) {
            window.attachFormEventListeners('new');
        } else {
            // Fallback
            document.getElementById('btn-save-node').addEventListener('click', () => saveNodeConfig('new'));
            document.getElementById('btn-cancel-node').addEventListener('click', () => {
                document.querySelector('.tab-btn[data-tab="nodelist"]').click();
            });
        }
    }
    
    // Fallback form if dynamic generator not loaded
    function generateFallbackForm() {
        return `
            <div class="form-grid">
                <div class="form-row">
                    <label>Node Remarks *:</label>
                    <input type="text" id="nc-remarks" value="" class="select-input" placeholder="Enter node name">
                </div>
                <div class="form-row">
                    <label>Type:</label>
                    <select id="nc-type" class="select-input">
                        <option value="Xray" selected>Xray</option>
                        <option value="V2ray">V2ray</option>
                    </select>
                </div>
                <div class="form-row">
                    <label>Protocol *:</label>
                    <select id="nc-protocol" class="select-input">
                        <option value="socks" selected>Socks</option>
                        <option value="vmess">VMess</option>
                        <option value="vless">VLESS</option>
                        <option value="http">HTTP</option>
                        <option value="shadowsocks">Shadowsocks</option>
                        <option value="trojan">Trojan</option>
                        <option value="wireguard">WireGuard</option>
                    </select>
                </div>
                <div class="form-row">
                    <label>Address *:</label>
                    <input type="text" id="nc-address" value="" class="select-input" placeholder="IP or domain">
                </div>
                <div class="form-row">
                    <label>Port *:</label>
                    <input type="number" id="nc-port" value="1080" class="select-input">
                </div>
                <div class="form-row">
                    <label>Username:</label>
                    <input type="text" id="nc-username" value="" class="select-input" placeholder="For SOCKS protocol">
                </div>
                <div class="form-row">
                    <label>Password:</label>
                    <input type="password" id="nc-password" value="" class="select-input" placeholder="For SOCKS protocol">
                </div>
                <div class="form-row">
                    <label>UUID / ID:</label>
                    <input type="text" id="nc-uuid" value="" class="select-input" placeholder="For VMess/VLESS">
                </div>
                <div class="form-row">
                    <label>Encryption:</label>
                    <select id="nc-encryption" class="select-input">
                        <option value="none">None</option>
                        <option value="auto" selected>Auto</option>
                        <option value="aes-128-gcm">AES-128-GCM</option>
                        <option value="chacha20-poly1305">ChaCha20-Poly1305</option>
                    </select>
                </div>
                <div class="form-row">
                    <label>Transport:</label>
                    <select id="nc-transport" class="select-input">
                        <option value="tcp" selected>TCP</option>
                        <option value="ws">WebSocket</option>
                        <option value="grpc">gRPC</option>
                    </select>
                </div>
                <div class="form-row">
                    <label>TLS:</label>
                    <input type="checkbox" id="nc-tls" class="switch">
                </div>
            </div>
        `;
    }
    
    // Save node config
    function saveNodeConfig(nodeId) {
        // Get all form values dynamically
        const formData = {};
        const formInputs = document.querySelectorAll('#node-config-form input, #node-config-form select');
        
        formInputs.forEach(input => {
            if (input.id && input.id.startsWith('nc-')) {
                const fieldName = input.id.replace('nc-', '');
                
                if (input.type === 'checkbox') {
                    formData[fieldName] = input.checked ? '1' : '0';
                } else {
                    formData[fieldName] = input.value || '';
                }
            }
        });
        
        // Validate required fields
        if (!formData.remarks || formData.remarks.trim() === '') {
            showToast('Error', 'Node remarks is required', 'error');
            return;
        }
        
        if (!formData.protocol) {
            showToast('Error', 'Protocol is required', 'error');
            return;
        }
        
        const body = new URLSearchParams();
        body.set('action', 'save');
        body.set('node', nodeId);

        for (const [key, value] of Object.entries(formData)) {
            if (value !== '') {
                body.set(key, value);
            }
        }

        fetch(`${API_BASE}/passwall-node-config.sh`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8'
            },
            body: body.toString()
        })
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok') {
                    showToast('Saved', data.message || 'Node saved successfully', 'success');
                    
                    // Reload node list
                    loadNodeList();
                    
                    // Go back to node list
                    setTimeout(() => {
                        document.querySelector('.tab-btn[data-tab="nodelist"]').click();
                    }, 1000);
                } else {
                    showToast('Error', data.message || 'Failed to save node', 'error');
                }
            })
            .catch(err => {
                showToast('Error', 'Failed to save node', 'error');
                console.error('Save node error:', err);
            });
    }
    
    // Make saveNodeConfig available globally for dynamic form
    window.saveNodeConfig = saveNodeConfig;
    
    // ==================== PASSWALL LOGS ====================
    
    let pwLogUpdateInterval;
    
    function initPasswallLogs() {
        const btnPause = document.getElementById('btn-pw-pause');
        const btnClear = document.getElementById('btn-pw-clear');
        const btnDownload = document.getElementById('btn-pw-download');
        
        if (btnPause) {
            btnPause.addEventListener('click', () => {
                pwLogPaused = !pwLogPaused;
                
                if (pwLogPaused) {
                    btnPause.innerHTML = '⏸️ Resume';
                    document.getElementById('pw-log-status-text').textContent = 'Paused';
                } else {
                    btnPause.innerHTML = '⏸️ Pause';
                    document.getElementById('pw-log-status-text').textContent = 'Live';
                    loadPasswallLogs();
                }
            });
        }
        
        if (btnClear) {
            btnClear.addEventListener('click', () => {
                if (confirm('Clear display?')) {
                    document.getElementById('pw-log-content').textContent = 'Display cleared. Logs will reload on next update...';
                }
            });
        }
        
        if (btnDownload) {
            btnDownload.addEventListener('click', () => {
                const content = document.getElementById('pw-log-content').textContent;
                const blob = new Blob([content], { type: 'text/plain' });
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = `passwall-${Date.now()}.log`;
                a.click();
                URL.revokeObjectURL(url);
            });
        }
    }
    
    function loadPasswallLogs() {
        if (pwLogPaused) return;
        
        fetch(`${API_BASE}/passwall-logs.sh`)
            .then(r => r.text())
            .then(logs => {
                const logContent = document.getElementById('pw-log-content');
                if (logContent) {
                    logContent.textContent = logs;
                    
                    // Scroll to bottom
                    const logContainer = logContent.parentElement;
                    logContainer.scrollTop = logContainer.scrollHeight;
                }
            })
            .catch(err => {
                console.error('Passwall logs error:', err);
            });
    }
    
    // Auto-update Passwall logs
    function startPasswallLogsAutoUpdate() {
        pwLogUpdateInterval = setInterval(() => {
            const passwallPage = document.getElementById('page-passwall');
            const logsTab = document.getElementById('tab-passwallogs');
            
            if (passwallPage && passwallPage.classList.contains('active') && 
                logsTab && logsTab.classList.contains('active')) {
                loadPasswallLogs();
            }
        }, 5000); // Every 5 seconds
    }
    
    // ==================== INIT ====================
    
    function init() {
        initNavigation();
        initLogout();
        initVPNButtons();
        initLinkItems();
        initPasswallTabs();
        initPasswallButtons();
        initPasswallLogs();
        initOpenVPNUpload();
        initConfigEditor();
        
        // Initial updates
        updateDashboard();
        updateVPNStatus();
        
        // Start auto-updates
        startAutoUpdate();
        startPasswallLogsAutoUpdate();
        
        console.log('VEKTORT13 v5.1 OpenVPN');
    }
    
    // ==================== OPENVPN ====================
    
    let openvpnUpdateInterval = null;
    let dashboardUpdateInterval = null;
    
    function loadOpenVPNConfigs() {
        const container = document.getElementById('openvpn-configs-container');
        if (!container) return;
        
        // Only show "Loading..." on first load (empty container)
        const hasContent = container.querySelector('.vpn-config-item');
        if (!hasContent) {
            container.innerHTML = '<p>Loading...</p>';
        }
        
        fetch(`${API_BASE}/openvpn-control.sh?action=list`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok' && data.configs) {
                    renderOpenVPNConfigs(data.configs);
                } else {
                    container.innerHTML = '<p>Error loading</p>';
                }
            })
            .catch(err => {
                console.error('OpenVPN error:', err);
                container.innerHTML = '<p>Error loading</p>';
            });
    }
    
    function renderOpenVPNConfigs(configs) {
        const container = document.getElementById('openvpn-configs-container');
        
        if (configs.length === 0) {
            container.innerHTML = '<p>No configs found. Upload .ovpn file below.</p>';
            return;
        }
        
        // Check if we need full re-render or just status update
        const existingItems = container.querySelectorAll('.vpn-config-item');
        const needFullRender = (existingItems.length !== configs.filter(c => c.name !== 'rw').length);
        
        if (needFullRender) {
            // Full render - first load or config count changed
            let html = '';
            
            configs.forEach(cfg => {
                if (cfg.name === 'rw') return;
                
                let statusClass, statusText;
                const status = cfg.status || 'stopped';
                
                switch(status) {
                    case 'connected':
                        statusClass = 'badge-success';
                        statusText = '✓ Connected';
                        break;
                    case 'connecting':
                        statusClass = 'badge-info';
                        statusText = '🔄 Connecting...';
                        break;
                    case 'starting':
                        statusClass = 'badge-warning';
                        statusText = '⏳ Starting...';
                        break;
                    default:
                        statusClass = 'badge-secondary';
                        statusText = 'Stopped';
                }
                
                const isRunning = (status !== 'stopped');
                
                html += `
                    <div class="vpn-config-item" data-config="${cfg.name}">
                        <div class="vpn-config-info">
                            <div class="vpn-config-name">${cfg.name}</div>
                            <div class="vpn-config-details">
                                📄 ${cfg.file || ''}
                                ${cfg.enabled == '1' ? '✓ Enabled' : ''}
                            </div>
                        </div>
                        <div class="vpn-config-status">
                            <span class="badge ${statusClass}" data-status="${status}">${statusText}</span>
                        </div>
                        <div class="vpn-config-actions">
                            ${isRunning ? 
                                `<button class="btn btn-sm btn-primary btn-vpn-action" onclick="controlOpenVPN('${cfg.name}','restart')">🔄 Restart</button>
                                 <button class="btn btn-sm btn-danger btn-vpn-action" onclick="controlOpenVPN('${cfg.name}','stop')">⏹️ Stop</button>` :
                                `<button class="btn btn-sm btn-success btn-vpn-action" onclick="controlOpenVPN('${cfg.name}','start')">▶️ Start</button>`
                            }
                            <button class="btn btn-sm btn-info btn-vpn-action" onclick="viewOpenVPNLogs('${cfg.name}')">📋 Logs</button>
                            <button class="btn btn-sm btn-secondary btn-vpn-action" onclick="viewOpenVPNConfig('${cfg.name}')">✏️ Edit</button>
                            <button class="btn btn-sm btn-danger btn-vpn-action" onclick="deleteOpenVPN('${cfg.name}')">🗑️ Delete</button>
                        </div>
                    </div>
                `;
            });
            
            container.innerHTML = html;
        } else {
            // Just update statuses - no flicker
            configs.forEach(cfg => {
                if (cfg.name === 'rw') return;
                
                const item = container.querySelector(`.vpn-config-item[data-config="${cfg.name}"]`);
                if (!item) return;
                
                const badge = item.querySelector('.badge');
                const currentStatus = badge ? badge.dataset.status : null;
                const newStatus = cfg.status || 'stopped';
                
                // Only update if status changed
                if (currentStatus !== newStatus) {
                    let statusClass, statusText;
                    
                    switch(newStatus) {
                        case 'connected':
                            statusClass = 'badge-success';
                            statusText = '✓ Connected';
                            break;
                        case 'connecting':
                            statusClass = 'badge-info';
                            statusText = '🔄 Connecting...';
                            break;
                        case 'starting':
                            statusClass = 'badge-warning';
                            statusText = '⏳ Starting...';
                            break;
                        default:
                            statusClass = 'badge-secondary';
                            statusText = 'Stopped';
                    }
                    
                    if (badge) {
                        badge.className = `badge ${statusClass}`;
                        badge.dataset.status = newStatus;
                        badge.textContent = statusText;
                    }
                    
                    // Update buttons
                    const actions = item.querySelector('.vpn-config-actions');
                    const isRunning = (newStatus !== 'stopped');
                    
                    if (actions) {
                        actions.innerHTML = `
                            ${isRunning ? 
                                `<button class="btn btn-sm btn-primary btn-vpn-action" onclick="controlOpenVPN('${cfg.name}','restart')">🔄 Restart</button>
                                 <button class="btn btn-sm btn-danger btn-vpn-action" onclick="controlOpenVPN('${cfg.name}','stop')">⏹️ Stop</button>` :
                                `<button class="btn btn-sm btn-success btn-vpn-action" onclick="controlOpenVPN('${cfg.name}','start')">▶️ Start</button>`
                            }
                            <button class="btn btn-sm btn-info btn-vpn-action" onclick="viewOpenVPNLogs('${cfg.name}')">📋 Logs</button>
                            <button class="btn btn-sm btn-secondary btn-vpn-action" onclick="viewOpenVPNConfig('${cfg.name}')">✏️ Edit</button>
                            <button class="btn btn-sm btn-danger btn-vpn-action" onclick="deleteOpenVPN('${cfg.name}')">🗑️ Delete</button>
                        `;
                    }
                }
            });
        }
    }
    
    window.controlOpenVPN = function(config, command) {
        const messages = {
            start: 'Запускаю OpenVPN...',
            stop: 'Останавливаю OpenVPN...',
            restart: 'Перезапускаю OpenVPN...',
            enable: 'Включаю конфиг...',
            disable: 'Отключаю конфиг...'
        };
        
        showToast('OpenVPN', messages[command] || `${command}ing...`, 'info');
        
        fetch(`${API_BASE}/openvpn-control.sh?action=control&config=${config}&command=${command}`)
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok') {
                    showToast('Success', data.message, 'success');
                    
                    // Immediate update for stop command with verification
                    if (command === 'stop') {
                        setTimeout(() => {
                            loadOpenVPNConfigs();
                            // Verify stop worked after 2 seconds
                            setTimeout(() => {
                                fetch(`${API_BASE}/openvpn-control.sh?action=list`)
                                    .then(r => r.json())
                                    .then(data => {
                                        if (data.status === 'ok' && data.configs) {
                                            const cfg = data.configs.find(c => c.name === config);
                                            if (cfg && cfg.status !== 'stopped') {
                                                showToast('Warning', `${config} may still be running. Check logs.`, 'warning');
                                            }
                                        }
                                    });
                            }, 2000);
                        }, 500);
                    } else {
                        setTimeout(() => loadOpenVPNConfigs(), 1000);
                        setTimeout(() => loadOpenVPNConfigs(), 3000);
                    }
                } else if (data.status === 'warning') {
                    showToast('Warning', data.message, 'warning');
                    setTimeout(() => loadOpenVPNConfigs(), 500);
                    setTimeout(() => loadOpenVPNConfigs(), 2000);
                } else {
                    // Check for Options error
                    if (data.message && data.message.includes('Options error')) {
                        const match = data.message.match(/Options error: (.+)/);
                        const errorMsg = match ? match[1] : data.message;
                        showToast('Config Error', errorMsg, 'error');
                    } else {
                        showToast('Error', data.message, 'error');
                    }
                }
            })
            .catch(err => {
                showToast('Error', 'Failed', 'error');
                console.error(err);
            });
    };
    
    let currentEditConfig = null;
    
    window.editOpenVPN = function(config) {
        viewOpenVPNConfig(config);
    };
    
    window.viewOpenVPNConfig = function(config) {
        showToast('Loading', `Loading ${config} config...`, 'info');
        
        fetch(`${API_BASE}/openvpn-get-content.sh?config=${config}`)
            .then(r => {
                const contentType = r.headers.get('content-type');
                // Check if it's an error (JSON) or success (text/plain)
                if (contentType && contentType.includes('application/json')) {
                    return r.json().then(data => ({ type: 'error', data }));
                } else {
                    return r.text().then(text => ({ type: 'success', data: text }));
                }
            })
            .then(result => {
                if (result.type === 'success') {
                    // Plain text response - file content
                    currentEditConfig = config;
                    document.getElementById('editor-title').textContent = `Edit Config: ${config}`;
                    document.getElementById('editor-content').value = result.data;
                    
                    // Scan for unsupported directives
                    const warnings = scanConfigWarnings(result.data);
                    const warningsEl = document.getElementById('editor-warnings');
                    if (warnings.length > 0) {
                        warningsEl.innerHTML = '⚠️ ' + warnings.join('<br>⚠️ ');
                    } else {
                        warningsEl.innerHTML = '';
                    }
                    
                    document.getElementById('openvpn-editor-modal').style.display = 'block';
                } else {
                    // Error response
                    const msg = result.data.message || 'Failed to load config';
                    if (confirm(`${msg}\n\nThis appears to be a UCI-only config.\nOpen in LuCI instead?`)) {
                        window.open(`/cgi-bin/luci/admin/vpn/openvpn/basic/${config}`, '_blank');
                    }
                }
            })
            .catch(err => {
                showToast('Error', 'Failed to load config', 'error');
                console.error(err);
            });
    };
    
    function scanConfigWarnings(content) {
        const warnings = [];
        const lines = content.split('\n');
        
        lines.forEach((line, idx) => {
            const trimmed = line.trim();
            const lineNum = idx + 1;
            
            // Skip comments and empty lines
            if (trimmed.startsWith('#') || trimmed === '') return;
            
            // Check for unsupported directives
            if (trimmed.match(/^block-outside-dns/i)) {
                warnings.push(`Line ${lineNum}: 'block-outside-dns' (Windows-only, not supported)`);
            }
            
            if (trimmed.match(/^dhcp-option\s+DNS6/i)) {
                warnings.push(`Line ${lineNum}: 'dhcp-option DNS6' (IPv6 DNS not fully supported)`);
            }
            
            if (trimmed.match(/^route-ipv6/i)) {
                warnings.push(`Line ${lineNum}: 'route-ipv6' (IPv6 routing may not work)`);
            }
            
            if (trimmed.match(/^tun-ipv6/i)) {
                warnings.push(`Line ${lineNum}: 'tun-ipv6' (IPv6 may not be fully supported)`);
            }
        });
        
        return warnings;
    }
    
    function initConfigEditor() {
        const btnClose = document.getElementById('btn-close-editor');
        const btnSave = document.getElementById('btn-save-config');
        const modal = document.getElementById('openvpn-editor-modal');
        
        if (btnClose) {
            btnClose.addEventListener('click', () => {
                modal.style.display = 'none';
                currentEditConfig = null;
            });
        }
        
        if (btnSave) {
            btnSave.addEventListener('click', () => {
                if (!currentEditConfig) return;
                
                const content = document.getElementById('editor-content').value;
                
                // Scan for warnings before saving
                const warnings = scanConfigWarnings(content);
                if (warnings.length > 0) {
                    const warningsText = warnings.join('\n');
                    if (!confirm(`⚠️ Config has unsupported directives:\n\n${warningsText}\n\nSave anyway?`)) {
                        return;
                    }
                }
                
                showToast('Saving', 'Saving config...', 'info');
                
                // Encode content as base64 (UTF-8 safe)
                const contentB64 = btoa(unescape(encodeURIComponent(content)));
                
                // Use POST with JSON body
                fetch(`${API_BASE}/openvpn-save-content.sh`, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                        config: currentEditConfig,
                        content_b64: contentB64
                    })
                })
                    .then(r => r.json())
                    .then(data => {
                        if (data.status === 'ok') {
                            showToast('Success', 'Config saved!', 'success');
                            modal.style.display = 'none';
                            currentEditConfig = null;
                        } else {
                            showToast('Error', data.message || 'Save failed', 'error');
                        }
                    })
                    .catch(err => {
                        showToast('Error', 'Save failed', 'error');
                        console.error(err);
                    });
            });
        }
        
        // Close on background click
        if (modal) {
            modal.addEventListener('click', (e) => {
                if (e.target === modal) {
                    modal.style.display = 'none';
                    currentEditConfig = null;
                }
            });
        }
    }
    
    window.deleteOpenVPN = function(config) {
        if (!confirm(`Delete config "${config}"?\n\nОтключит и удалит конфиг.`)) return;
        
        showToast('Deleting', `Останавливаю и удаляю ${config}...`, 'info');
        
        // First stop the config if running, then delete
        fetch(`${API_BASE}/openvpn-control.sh?action=control&config=${config}&command=stop`)
            .then(() => {
                // Wait a bit for process to stop
                return new Promise(resolve => setTimeout(resolve, 500));
            })
            .then(() => {
                // Now delete
                return fetch(`${API_BASE}/openvpn-control.sh?action=delete&config=${config}`);
            })
            .then(r => r.json())
            .then(data => {
                if (data.status === 'ok') {
                    showToast('Success', 'Конфиг удалён', 'success');
                    setTimeout(() => loadOpenVPNConfigs(), 500);
                } else {
                    showToast('Error', data.message, 'error');
                }
            })
            .catch(err => {
                showToast('Error', 'Failed to delete', 'error');
                console.error(err);
            });
    };
    
    // Logs Modal
    let logsUpdateInterval = null;
    
    window.viewOpenVPNLogs = function(config) {
        const modal = document.getElementById('logs-modal');
        const title = document.getElementById('logs-modal-title');
        const body = document.getElementById('logs-modal-body');
        const pauseBtn = document.getElementById('logs-pause-btn');
        const logIndicator = modal ? modal.querySelector('.log-indicator') : null;
        const logStatusText = document.getElementById('log-status-text');
        
        if (!modal || !title || !body || !pauseBtn) {
            console.error('Logs modal elements not found');
            showToast('Error', 'Logs modal not initialized', 'error');
            return;
        }
        
        title.textContent = `OpenVPN Logs - ${config}`;
        modal.classList.add('active');
        
        let isPaused = false;
        
        function updateLogs() {
            if (isPaused) return;
            
            fetch(`${API_BASE}/openvpn-control.sh?action=get_logs&config=${config}`)
                .then(r => r.json())
                .then(data => {
                    if (data.status === 'ok' && data.logs) {
                        const lines = data.logs.split('\n').filter(l => l.trim());
                        let html = '';
                        
                        lines.forEach(line => {
                            let className = 'log-line';
                            if (line.includes('error') || line.includes('ERROR')) className += ' error';
                            else if (line.includes('warn') || line.includes('WARN')) className += ' warning';
                            else if (line.includes('notice') || line.includes('NOTICE')) className += ' notice';
                            
                            html += `<div class="${className}">${escapeHtml(line)}</div>`;
                        });
                        
                        body.innerHTML = html || '<p>No logs found</p>';
                        body.scrollTop = body.scrollHeight; // Auto-scroll to bottom
                    }
                })
                .catch(err => {
                    console.error('Failed to load logs:', err);
                    body.innerHTML = '<p style="color:red;">Failed to load logs. Check console.</p>';
                });
        }
        
        updateLogs();
        logsUpdateInterval = setInterval(updateLogs, 5000);
        
        pauseBtn.textContent = '⏸️ Pause';
        pauseBtn.onclick = () => {
            isPaused = !isPaused;
            pauseBtn.textContent = isPaused ? '▶️ Resume' : '⏸️ Pause';
            
            // Update indicator
            if (logIndicator && logStatusText) {
                if (isPaused) {
                    logIndicator.classList.remove('live');
                    logIndicator.classList.add('paused');
                    logStatusText.textContent = 'Paused';
                } else {
                    logIndicator.classList.remove('paused');
                    logIndicator.classList.add('live');
                    logStatusText.textContent = 'Live';
                    updateLogs(); // Immediate update
                }
            }
        };
        
        document.getElementById('logs-clear-btn').onclick = () => {
            if (confirm('Clear all logs for this config?')) {
                body.innerHTML = '<p>Logs cleared (reload to see new entries)</p>';
            }
        };
        
        document.getElementById('logs-refresh-btn').onclick = () => {
            updateLogs();  // Force immediate update
        };
        
        document.getElementById('logs-download-btn').onclick = () => {
            const text = body.innerText;
            const blob = new Blob([text], { type: 'text/plain' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `openvpn-${config}-logs.txt`;
            a.click();
            URL.revokeObjectURL(url);
        };
    };
    
    window.closeLogsModal = function() {
        const modal = document.getElementById('logs-modal');
        if (!modal) {
            console.warn('Logs modal not found when closing');
            return;
        }
        
        modal.classList.remove('active');
        
        // Clear interval
        if (logsUpdateInterval) {
            clearInterval(logsUpdateInterval);
            logsUpdateInterval = null;
        }
        
        // Clear body
        const body = document.getElementById('logs-modal-body');
        if (body) {
            body.innerHTML = 'Loading logs...';
        }
    };
    
    function escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
    
    function initOpenVPNUpload() {
        const btnUpload = document.getElementById('btn-ovpn-upload');
        if (!btnUpload) return;
        
        // Prevent multiple event listeners
        if (btnUpload.dataset.initialized === 'true') return;
        btnUpload.dataset.initialized = 'true';
        
        btnUpload.addEventListener('click', async () => {
            let name = document.getElementById('ovpn-upload-name').value.trim();
            const fileInput = document.getElementById('ovpn-upload-file');
            const username = document.getElementById('ovpn-upload-user').value.trim();
            const password = document.getElementById('ovpn-upload-pass').value.trim();
            
            if (!fileInput.files || !fileInput.files[0]) {
                showToast('Error', 'Please select .ovpn file', 'error');
                return;
            }
            
            const file = fileInput.files[0];
            
            // If no name provided, use filename without extension
            if (!name) {
                name = file.name.replace(/\.(ovpn|conf)$/i, '');
            }
            
            showToast('Uploading', 'Uploading config...', 'info');
            
            try {
                const formData = new FormData();
                formData.append('instance_name', name);
                formData.append('ovpn_file', file);
                if (username) formData.append('username', username);
                if (password) formData.append('password', password);
                
                const response = await fetch(`${API_BASE}/openvpn-upload.sh`, {
                    method: 'POST',
                    body: formData
                });
                
                const data = await response.json();
                
                if (data.status === 'ok') {
                    showToast('Success', 'Config uploaded!', 'success');
                    document.getElementById('ovpn-upload-name').value = '';
                    document.getElementById('ovpn-upload-user').value = '';
                    document.getElementById('ovpn-upload-pass').value = '';
                    fileInput.value = '';
                    setTimeout(() => loadOpenVPNConfigs(), 500);
                } else {
                    showToast('Error', data.message || 'Upload failed', 'error');
                }
            } catch (err) {
                showToast('Error', 'Upload failed: ' + err.message, 'error');
                console.error(err);
            }
        });
    }
    
    // ==================== SYSTEM LOGS ====================
    
    let systemLogsInterval = null;
    let systemLogsPaused = false;
    
    function initSystemLogsPage() {
        const pauseBtn = document.getElementById('system-logs-pause-btn');
        const refreshBtn = document.getElementById('system-logs-refresh-btn');
        const clearBtn = document.getElementById('system-logs-clear-btn');
        const downloadBtn = document.getElementById('system-logs-download-btn');
        const indicator = document.querySelector('#page-logs .log-indicator');
        const statusText = document.getElementById('system-log-status-text');
        
        if (!pauseBtn) return;
        
        function loadSystemLogs() {
            if (systemLogsPaused) return;
            
            fetch(`${API_BASE}/logs.sh`)
                .then(r => r.text())
                .then(logs => {
                    const container = document.getElementById('system-log-content');
                    
                    // Colorize logs
                    const lines = logs.split('\n');
                    let html = '';
                    
                    lines.forEach(line => {
                        let className = 'log-line';
                        if (line.match(/error|ERROR|fail|FAIL/i)) className += ' error';
                        else if (line.match(/warn|WARN|warning|WARNING/i)) className += ' warning';
                        else if (line.match(/notice|NOTICE/i)) className += ' notice';
                        else if (line.match(/info|INFO/i)) className += ' info';
                        
                        html += `<div class="${className}">${escapeHtml(line)}</div>`;
                    });
                    
                    container.innerHTML = html || '<div>No logs available</div>';
                    
                    // Auto-scroll to bottom
                    const logContainer = document.getElementById('system-log-container');
                    logContainer.scrollTop = logContainer.scrollHeight;
                })
                .catch(err => {
                    console.error('Failed to load system logs:', err);
                    document.getElementById('system-log-content').textContent = 'Error loading logs: ' + err.message;
                });
        }
        
        pauseBtn.onclick = () => {
            systemLogsPaused = !systemLogsPaused;
            pauseBtn.textContent = systemLogsPaused ? '▶️ Resume' : '⏸️ Pause';
            
            if (indicator && statusText) {
                if (systemLogsPaused) {
                    indicator.classList.remove('live');
                    indicator.classList.add('paused');
                    statusText.textContent = 'Paused';
                } else {
                    indicator.classList.remove('paused');
                    indicator.classList.add('live');
                    statusText.textContent = 'Live';
                    loadSystemLogs();
                }
            }
        };
        
        refreshBtn.onclick = () => loadSystemLogs();
        
        clearBtn.onclick = () => {
            if (confirm('Clear display? (This does not delete the log file)')) {
                document.getElementById('system-log-content').textContent = 'Display cleared. Logs will reload on next update...';
            }
        };
        
        downloadBtn.onclick = () => {
            const content = document.getElementById('system-log-content').innerText;
            const blob = new Blob([content], { type: 'text/plain' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = `system-logs-${Date.now()}.txt`;
            a.click();
            URL.revokeObjectURL(url);
        };
        
        // Initial load
        loadSystemLogs();
        
        // Auto-update every 5 seconds
        if (systemLogsInterval) clearInterval(systemLogsInterval);
        systemLogsInterval = setInterval(loadSystemLogs, 5000);
    }
    
    // Initialize System Logs when page loads
    window.addEventListener('hashchange', () => {
        if (window.location.hash === '#/logs') {
            initSystemLogsPage();
        } else {
            // Stop auto-update when leaving logs page
            if (systemLogsInterval) {
                clearInterval(systemLogsInterval);
                systemLogsInterval = null;
            }
        }
    });
    
    // Start when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
    
    // Check if on logs page after init
    setTimeout(() => {
        if (window.location.hash === '#/logs') {
            initSystemLogsPage();
        }
    }, 500);
    
})();
