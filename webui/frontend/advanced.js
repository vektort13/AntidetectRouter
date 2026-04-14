const API='/cgi-bin/vektort13';

async function loadAdminSettings(){
    try{
        const r=await fetch(`${API}/exec.sh?action=get_ports`);
        const d=await r.json();
        if(d.status==='ok'){
            document.getElementById('ssh-port').value=d.ssh_port;
            document.getElementById('luci-port').value=d.luci_port;
        }
    }catch(e){}
}

async function setSSHPort(){
    const port=document.getElementById('ssh-port').value;
    if(!port){alert('Port required');return;}
    try{
        const r=await fetch(`${API}/exec.sh?action=ssh_port&port=${port}`);
        const d=await r.json();
        if(d.status==='ok'&&typeof showToast==='function')showToast('Success',d.message,'success');
        else alert(d.message);
    }catch(e){alert('Failed');}
}

async function setLuCIPort(){
    const port=document.getElementById('luci-port').value;
    if(!port){alert('Port required');return;}
    if(!confirm('LuCI will restart. Continue?'))return;
    try{
        // Отправляем запрос без ожидания ответа (LuCI перезапустится)
        fetch(`${API}/exec.sh?action=luci_port&port=${port}`,{keepalive:false});
        alert(`LuCI port changed to ${port}!\n\nReload page manually:\n${window.location.protocol}//${window.location.hostname}:${port}`);
    }catch(e){
        alert(`Request sent. Reload page on new port: ${port}`);
    }
}

async function setPassword(){
    const pass=document.getElementById('root-password').value;
    if(!pass){alert('Password required');return;}
    if(pass.length<6){alert('Min 6 chars');return;}
    try{
        const r=await fetch(`${API}/exec.sh?action=password`,{method:'POST',body:JSON.stringify({password:pass})});
        const d=await r.json();
        if(d.status==='ok'){
            if(typeof showToast==='function')showToast('Success','Password changed','success');
            document.getElementById('root-password').value='';
        }else alert(d.message);
    }catch(e){alert('Failed');}
}

async function loadPackages(){
    const el=document.getElementById('packages-list');
    const btn=document.querySelector('[onclick*="loadPackages"]');
    if(!el)return;
    
    // Toggle: если список открыт - закрываем
    if(el.style.display==='block'){
        el.style.display='none';
        if(btn)btn.innerHTML='Open List';
        return;
    }
    
    el.style.display='block';
    if(btn)btn.innerHTML='Close List';
    el.innerHTML='<div class="loading">Loading packages...</div>';
    try{
        const r=await fetch(`${API}/software-manager.sh?action=list`);
        const d=await r.json();
        if(d.status==='ok'){
            // Создаем красивую таблицу пакетов
            let html='<div class="packages-table">';
            html+='<div class="packages-header"><span>Package Name</span><span>Version</span></div>';
            html+='<div class="packages-body">';
            d.packages.forEach(p=>{
                html+=`<div class="package-row">
                    <span class="package-name">${p.name}</span>
                    <span class="package-version">${p.version}</span>
                </div>`;
            });
            html+='</div></div>';
            el.innerHTML=html;
        }
    }catch(e){el.innerHTML='<div class="error">Failed to load packages</div>';}
}

async function updatePackageLists(){
    const btn=document.querySelector('[onclick*="updatePackageLists"]');
    if(btn){
        btn.disabled=true;
        btn.innerHTML='🔄 Updating...';
    }
    if(typeof showToast==='function')showToast('Info','Updating...','info');
    try{
        const r=await fetch(`${API}/exec.sh?action=update_lists`);
        const d=await r.json();
        if(d.status==='ok'){
            if(typeof showToast==='function')showToast('Success',d.message,'success');
            if(btn){
                btn.innerHTML='✅ Updated';
            }
        }else alert(d.message||'Update failed');
    }catch(e){alert('Failed');}finally{
        if(btn){
            setTimeout(()=>{
                btn.disabled=false;
                btn.innerHTML='🔄 Update Lists';
            },2000);
        }
    }
}

async function installPackage(){
    const pkg=document.getElementById('package-name').value;
    if(!pkg){alert('Package required');return;}
    if(!confirm(`Install ${pkg}?`))return;
    if(typeof showToast==='function')showToast('Info','Installing...','info');
    try{
        const r=await fetch(`${API}/exec.sh?action=install&package=${pkg}`);
        const d=await r.json();
        if(d.status==='ok'){
            if(typeof showToast==='function')showToast('Success',d.message,'success');
            setTimeout(loadPackages,1000);
        }else alert(d.message);
    }catch(e){alert('Failed');}
}

async function loadServices(){
    const el=document.getElementById('services-list');
    const btn=document.querySelector('[onclick*="loadServices"]');
    if(!el)return;
    
    // Toggle: если список открыт - закрываем
    if(el.style.display==='block'){
        el.style.display='none';
        if(btn)btn.innerHTML='Open Startup Services';
        return;
    }
    
    el.style.display='block';
    if(btn)btn.innerHTML='Close Startup Services';
    el.innerHTML='<div class="loading">Loading services...</div>';
    try{
        const r=await fetch(`${API}/startup-manager.sh?action=list`);
        const d=await r.json();
        if(d.status==='ok'){
            el.innerHTML=d.services.map(s=>`<div class="service-item">${s.name} <span class="status ${s.enabled?'enabled':'disabled'}">${s.enabled?'Enabled':'Disabled'}</span></div>`).join('');
        }
    }catch(e){el.innerHTML='<div class="error">Failed to load services</div>';}
}

async function loadSystemInfo(){
    const el=document.getElementById('system-uptime');
    if(!el)return;
    try{
        const r=await fetch(`${API}/exec.sh?action=uptime`);
        const d=await r.json();
        if(d.status==='ok')el.textContent=d.uptime;
    }catch(e){}
}

async function backupConfig(){
    try{
        const r=await fetch(`${API}/system-control.sh?action=backup`);
        const d=await r.json();
        if(d.status==='ok'){
            window.location.href=d.file;
        }else alert(d.message);
    }catch(e){alert('Failed');}
}

async function restoreConfig(file){
    if(!file){
        alert('Backup file required');
        return;
    }
    if(!confirm(`Restore configuration from ${file.name}? Router may reboot.`)) return;

    try{
        const formData=new FormData();
        formData.append('backup_file', file, file.name);

        const r=await fetch(`${API}/system-control.sh?action=restore`, {
            method:'POST',
            body:formData
        });
        const d=await r.json();

        if(d.status==='ok'){
            alert(d.message || 'Restore started. Wait for reboot.');
        }else{
            alert(d.message || 'Restore failed');
        }
    }catch(e){
        alert('Restore failed');
    }
}

function initRestoreUploader(){
    const restoreInput=document.getElementById('restore-file');
    if(!restoreInput || restoreInput.dataset.bound==='1') return;

    restoreInput.dataset.bound='1';
    restoreInput.addEventListener('change',()=>{
        const file=restoreInput.files && restoreInput.files[0];
        restoreConfig(file);
        restoreInput.value='';
    });
}

async function createSnapshot(){
    const btn = document.getElementById('btn-snapshot');
    if (!btn) return;
    
    // Disable button and show loading
    btn.disabled = true;
    btn.textContent = '⏳ Creating...';
    
    try {
        // Step 1: Create snapshot
        const response = await fetch(`${API}/snapshot.sh?action=create`);
        const data = await response.json();
        
        if (data.status === 'ok') {
            btn.textContent = '⬇️ Downloading...';
            
            // Step 2: Download the archive
            const downloadUrl = `${API}/snapshot.sh?action=download&file=${data.snapshot_name}.tar.gz`;
            
            // Create hidden link and trigger download
            const link = document.createElement('a');
            link.href = downloadUrl;
            link.download = `${data.snapshot_name}.tar.gz`;
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
            
            // Show success
            btn.textContent = '✅ Downloaded!';
            setTimeout(() => {
                btn.textContent = 'Create Snapshot';
                btn.disabled = false;
            }, 2000);
            
            // Success message
            alert(`Snapshot created successfully!\n\nFile: ${data.snapshot_name}.tar.gz\nCheck your Downloads folder.`);
        } else {
            throw new Error(data.message || 'Snapshot creation failed');
        }
    } catch (error) {
        console.error('Snapshot error:', error);
        btn.textContent = '❌ Failed';
        setTimeout(() => {
            btn.textContent = 'Create Snapshot';
            btn.disabled = false;
        }, 2000);
        alert('Snapshot creation failed: ' + error.message);
    }
}

async function rebootSystem(){
    if(!confirm('REBOOT NOW?'))return;
    if(!confirm('Are you SURE?'))return;
    try{
        await fetch(`${API}/exec.sh?action=reboot`);
        alert('Rebooting... Wait 1-2 minutes.');
    }catch(e){}
}

function initAdvanced(){
    const page=document.getElementById('page-advanced');
    if(page&&page.classList.contains('active')){
        loadAdminSettings();
    }
    initRestoreUploader();
}

if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',()=>{
        setTimeout(initAdvanced,200);
    });
}else{
    setTimeout(initAdvanced,200);
}

const menuItems=document.querySelectorAll('.menu-item[data-page="advanced"]');
menuItems.forEach(item=>{
    item.addEventListener('click',()=>{
        setTimeout(initAdvanced,100);
    });
});
