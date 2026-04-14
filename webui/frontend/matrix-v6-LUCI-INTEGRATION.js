// ============================================================
// MATRIX VEKTORT13 - EPIC v6 (LUCI INTEGRATION)
// ============================================================
// Integrated with LuCI login page
// Shows Matrix animation, then fades to login form after 5 sec
// ============================================================

(function() {
    'use strict';
    
    // Detect LuCI login page
    const isLuciLogin = 
        // Check for LuCI login form
        document.querySelector('form[method="post"]') && 
        (document.querySelector('input[name="luci_username"]') || 
         document.querySelector('input[name="username"]')) &&
        document.querySelector('input[type="password"]');
    
    if (!isLuciLogin) {
        console.log('Matrix: Not a LuCI login page, skipping');
        return;
    }
    
    console.log('Matrix: LuCI login detected, starting animation');
    
    const STORAGE_KEY = 'matrix_enabled';
    let matrixEnabled = localStorage.getItem(STORAGE_KEY) !== 'false';
    
    const CONFIG = {
        CIRCLE_SIZE: 950,
        SHRINK_DURATION: 2500,
        EXPLOSION_DURATION: 800,
        LOGO_TEXT: 'VEKTORT13',
        LOGO_SIZE: 72,
        MATRIX_SPEED: 33,
        FLICKER_INTERVAL: 100,
        SECRET_PHRASES: ['ya ronyau zapad', 'zdes byl kap'],
        SECRET_CHANCE: 0.002,
        TERMINAL_LINES: [
            'Initializing VEKTORT13 system...',
            'Loading neural network...',
            'Establishing secure connection...',
            'Access granted.'
        ],
        TEXT_HEIGHT_RATIO: 0.6,
        PARTICLE_FADE_DISTANCE: 50,
        SLOWDOWN_DISTANCE: 100,
        WAIT_BEFORE_LOGIN: 5000  // Wait 5 seconds before showing login
    };
    
    let canvas, ctx, matrixInterval, logo, terminal, circleCanvas, toggleBtn;
    const drops = [];
    let letterMap = new Set();
    let logoVisible = false;
    
    // Animation skip flag
    let animationSkipped = false;
    
    // Global keypress listener - skip animation on ANY key
    document.addEventListener('keydown', function skipAnimation(e) {
        if (animationSkipped) return;
        
        console.log('Matrix: Key pressed, skipping animation...');
        animationSkipped = true;
        
        // Remove this listener
        document.removeEventListener('keydown', skipAnimation);
        
        // Immediately transition to login
        transitionToLogin();
    }, { once: false });
    
    // Hide login form during animation
    const loginContainer = document.body;
    const originalOverflow = loginContainer.style.overflow;
    loginContainer.style.overflow = 'hidden';
    
    // Hide all content except what we'll create
    const allElements = document.querySelectorAll('body > *');
    const hiddenElements = [];
    allElements.forEach(el => {
        if (el.style.display !== 'none') {
            hiddenElements.push({
                element: el,
                display: el.style.display
            });
            el.style.display = 'none';
        }
    });
    
    // ==================== MATRIX RAIN ====================
    function initMatrixRain() {
        canvas = document.createElement('canvas');
        canvas.id = 'matrix-canvas';
        canvas.style.cssText = `
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            z-index: 9998;
            background: #000;
            pointer-events: none;
        `;
        document.body.insertBefore(canvas, document.body.firstChild);
        
        ctx = canvas.getContext('2d');
        
        const fontSize = 14;
        const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$%^&*()_+-=[]{}|;:,.<>?/'.split('');
        
        function resizeCanvas() {
            canvas.width = window.innerWidth;
            canvas.height = window.innerHeight;
            
            ctx.fillStyle = '#000';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            
            const columns = Math.floor(canvas.width / fontSize);
            
            drops.length = 0;
            for (let i = 0; i < columns; i++) {
                drops.push({
                    y: Math.random() * -100,
                    secret: null,
                    secretIndex: 0,
                    column: i
                });
            }
        }
        
        resizeCanvas();
        
        function drawMatrix() {
            ctx.fillStyle = 'rgba(0, 0, 0, 0.05)';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            ctx.font = fontSize + 'px monospace';
            
            for (let i = 0; i < drops.length; i++) {
                const drop = drops[i];
                
                if (logoVisible) {
                    const nextY = (drop.y + 1) * fontSize;
                    const currentX = drop.column * fontSize;
                    const key = `${Math.floor(currentX)},${Math.floor(nextY)}`;
                    
                    if (letterMap.has(key)) {
                        const direction = Math.random() < 0.5 ? -1 : 1;
                        const newColumn = drop.column + direction;
                        
                        if (newColumn >= 0 && newColumn < drops.length) {
                            drop.column = newColumn;
                        }
                    }
                }
                
                if (!drop.secret && Math.random() < CONFIG.SECRET_CHANCE) {
                    drop.secret = CONFIG.SECRET_PHRASES[Math.floor(Math.random() * CONFIG.SECRET_PHRASES.length)];
                    drop.secretIndex = 0;
                }
                
                let char;
                let color = '#0f0';
                
                if (drop.secret && drop.secretIndex < drop.secret.length) {
                    char = drop.secret[drop.secretIndex];
                    color = '#0a0';
                    drop.secretIndex++;
                    
                    if (drop.secretIndex >= drop.secret.length) {
                        drop.secret = null;
                        drop.secretIndex = 0;
                    }
                } else {
                    char = chars[Math.floor(Math.random() * chars.length)];
                }
                
                ctx.fillStyle = color;
                ctx.fillText(char, drop.column * fontSize, drop.y * fontSize);
                
                if (drop.y * fontSize > canvas.height && Math.random() > 0.975) {
                    drop.y = 0;
                }
                
                drop.y++;
            }
        }
        
        matrixInterval = setInterval(drawMatrix, CONFIG.MATRIX_SPEED);
        window.addEventListener('resize', resizeCanvas);
    }
    
    // ==================== TERMINAL ====================
    function initTerminal() {
        terminal = document.createElement('div');
        terminal.style.cssText = `
            position: fixed;
            top: 20%;
            left: 50%;
            transform: translateX(-50%);
            color: #0f0;
            font-family: 'Courier New', monospace;
            font-size: 18px;
            z-index: 9999;
            text-align: left;
            text-shadow: 0 0 10px #0f0;
        `;
        document.body.appendChild(terminal);
        
        let terminalLineIndex = 0;
        let terminalCharIndex = 0;
        
        function typeTerminal() {
            // Check if animation was skipped
            if (animationSkipped) {
                if (terminal) terminal.remove();
                return;
            }
            
            if (terminalLineIndex >= CONFIG.TERMINAL_LINES.length) {
                setTimeout(startCircleAnimation, 500);
                return;
            }
            
            const line = CONFIG.TERMINAL_LINES[terminalLineIndex];
            
            if (terminalCharIndex < line.length) {
                terminal.innerHTML += line[terminalCharIndex];
                terminalCharIndex++;
                setTimeout(typeTerminal, 50);
            } else {
                terminal.innerHTML += '<br>';
                terminalLineIndex++;
                terminalCharIndex = 0;
                setTimeout(typeTerminal, 300);
            }
        }
        
        setTimeout(typeTerminal, 500);
    }
    
    // ==================== ORGANIC BEZIER CIRCLE ====================
    function startCircleAnimation() {
        terminal.style.display = 'none';
        
        circleCanvas = document.createElement('canvas');
        circleCanvas.style.cssText = `
            position: fixed;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            z-index: 10000;
            pointer-events: none;
        `;
        circleCanvas.width = CONFIG.CIRCLE_SIZE;
        circleCanvas.height = CONFIG.CIRCLE_SIZE;
        
        document.body.appendChild(circleCanvas);
        
        const circleCtx = circleCanvas.getContext('2d');
        const centerX = CONFIG.CIRCLE_SIZE / 2;
        const centerY = CONFIG.CIRCLE_SIZE / 2;
        
        const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$%^&*()_+-=[]{}|;:,.<>?/'.split('');
        const secrets = CONFIG.SECRET_PHRASES;
        
        let radius = CONFIG.CIRCLE_SIZE / 2;
        const startTime = Date.now();
        
        const glowPoints = [];
        for (let i = 0; i < 8; i++) {
            glowPoints.push({
                angle: Math.random() * Math.PI * 2,
                intensity: Math.random() * 0.5 + 0.5,
                speed: Math.random() * 0.02 + 0.01
            });
        }
        
        function shrinkCircle() {
            // Check if animation was skipped
            if (animationSkipped) {
                circleCanvas.remove();
                return;
            }
            
            const elapsed = Date.now() - startTime;
            const progress = Math.min(elapsed / CONFIG.SHRINK_DURATION, 1);
            
            radius = (CONFIG.CIRCLE_SIZE / 2) * (1 - progress);
            if (radius < 1) radius = 1;
            
            circleCtx.clearRect(0, 0, CONFIG.CIRCLE_SIZE, CONFIG.CIRCLE_SIZE);
            
            glowPoints.forEach(gp => {
                gp.angle += gp.speed;
            });
            
            glowPoints.forEach(gp => {
                const glowX = centerX + Math.cos(gp.angle) * radius;
                const glowY = centerY + Math.sin(gp.angle) * radius;
                
                const gradient = circleCtx.createRadialGradient(glowX, glowY, 0, glowX, glowY, 30);
                gradient.addColorStop(0, `rgba(0, 255, 0, ${gp.intensity * 0.4})`);
                gradient.addColorStop(0.5, `rgba(0, 255, 0, ${gp.intensity * 0.2})`);
                gradient.addColorStop(1, 'rgba(0, 255, 0, 0)');
                
                circleCtx.fillStyle = gradient;
                circleCtx.fillRect(glowX - 30, glowY - 30, 60, 60);
            });
            
            const numSegments = 12;
            const angleStep = (Math.PI * 2) / numSegments;
            
            circleCtx.beginPath();
            
            for (let i = 0; i <= numSegments; i++) {
                const angle = i * angleStep;
                const radiusVar = radius + Math.sin(angle * 3 + elapsed * 0.001) * 10;
                const x1 = centerX + Math.cos(angle) * radiusVar;
                const y1 = centerY + Math.sin(angle) * radiusVar;
                
                if (i === 0) {
                    circleCtx.moveTo(x1, y1);
                } else {
                    const prevAngle = (i - 1) * angleStep;
                    const prevRadiusVar = radius + Math.sin(prevAngle * 3 + elapsed * 0.001) * 10;
                    const cpAngle = (prevAngle + angle) / 2;
                    const cpRadius = radiusVar + 15;
                    const cpX = centerX + Math.cos(cpAngle) * cpRadius;
                    const cpY = centerY + Math.sin(cpAngle) * cpRadius;
                    
                    circleCtx.quadraticCurveTo(cpX, cpY, x1, y1);
                }
            }
            
            circleCtx.closePath();
            circleCtx.strokeStyle = '#0f0';
            circleCtx.lineWidth = 2;
            circleCtx.shadowBlur = 20;
            circleCtx.shadowColor = '#0f0';
            circleCtx.stroke();
            
            const numChars = Math.floor(radius * 2 * Math.PI / 12);
            circleCtx.font = '12px monospace';
            circleCtx.shadowBlur = 15;
            circleCtx.shadowColor = '#0f0';
            
            for (let i = 0; i < numChars; i++) {
                const angle = (i / numChars) * Math.PI * 2;
                const charRadiusVar = radius + Math.sin(angle * 3 + elapsed * 0.001) * 10;
                const x = centerX + Math.cos(angle) * charRadiusVar;
                const y = centerY + Math.sin(angle) * charRadiusVar;
                
                let char, color;
                
                if (Math.random() < 0.015) {
                    const secretText = secrets[Math.floor(Math.random() * secrets.length)];
                    char = secretText[Math.floor(Math.random() * secretText.length)];
                    color = '#0a0';
                } else {
                    char = chars[Math.floor(Math.random() * chars.length)];
                    color = Math.random() < 0.3 ? '#0a0' : '#0f0';
                }
                
                circleCtx.fillStyle = color;
                circleCtx.fillText(char, x - 6, y + 4);
            }
            
            if (progress < 1) {
                requestAnimationFrame(shrinkCircle);
            } else {
                explodeCircle();
            }
        }
        
        shrinkCircle();
    }
    
    // ==================== EXPLOSION ====================
    function explodeCircle() {
        const particles = [];
        const particleCount = 150;
        const centerX = CONFIG.CIRCLE_SIZE / 2;
        const centerY = CONFIG.CIRCLE_SIZE / 2;
        
        for (let i = 0; i < particleCount; i++) {
            const angle = Math.random() * Math.PI * 2;
            const speed = Math.random() * 8 + 2;
            
            particles.push({
                x: centerX,
                y: centerY,
                vx: Math.cos(angle) * speed,
                vy: Math.sin(angle) * speed,
                life: 1.0,
                size: Math.random() * 3 + 1
            });
        }
        
        const circleCtx = circleCanvas.getContext('2d');
        
        function animateExplosion() {
            // Check if animation was skipped
            if (animationSkipped) {
                circleCanvas.remove();
                return;
            }
            
            circleCtx.clearRect(0, 0, CONFIG.CIRCLE_SIZE, CONFIG.CIRCLE_SIZE);
            
            let alive = false;
            for (const p of particles) {
                if (p.life > 0) {
                    alive = true;
                    p.x += p.vx;
                    p.y += p.vy;
                    p.life -= 0.015;
                    
                    circleCtx.fillStyle = `rgba(0, 255, 0, ${p.life})`;
                    circleCtx.shadowBlur = 10;
                    circleCtx.shadowColor = '#0f0';
                    circleCtx.fillRect(p.x, p.y, p.size, p.size);
                }
            }
            
            if (alive) {
                requestAnimationFrame(animateExplosion);
            } else {
                circleCanvas.remove();
                showLogo();
            }
        }
        
        animateExplosion();
    }
    
    // ==================== SMOOTH PARTICLE ASSEMBLY ====================
    function showLogo() {
        const tempCanvas = document.createElement('canvas');
        const tempCtx = tempCanvas.getContext('2d');
        
        const textWidth = CONFIG.LOGO_SIZE * CONFIG.LOGO_TEXT.length * 0.6;
        const textHeight = CONFIG.LOGO_SIZE * CONFIG.TEXT_HEIGHT_RATIO;
        
        tempCanvas.width = textWidth + 100;
        tempCanvas.height = textHeight + 100;
        
        tempCtx.font = `bold ${CONFIG.LOGO_SIZE}px 'Courier New', monospace`;
        tempCtx.fillStyle = '#fff';
        tempCtx.textAlign = 'center';
        tempCtx.textBaseline = 'middle';
        tempCtx.fillText(CONFIG.LOGO_TEXT, tempCanvas.width / 2, tempCanvas.height / 2);
        
        const imageData = tempCtx.getImageData(0, 0, tempCanvas.width, tempCanvas.height);
        const pixels = imageData.data;
        
        const letterPixels = [];
        for (let y = 0; y < tempCanvas.height; y += 2) {
            for (let x = 0; x < tempCanvas.width; x += 2) {
                const i = (y * tempCanvas.width + x) * 4;
                if (pixels[i] > 128) {
                    letterPixels.push({ x, y });
                }
            }
        }
        
        const particleCanvas = document.createElement('canvas');
        particleCanvas.style.cssText = `
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            z-index: 10001;
            pointer-events: none;
        `;
        particleCanvas.width = window.innerWidth;
        particleCanvas.height = window.innerHeight;
        document.body.appendChild(particleCanvas);
        
        const pCtx = particleCanvas.getContext('2d');
        
        const finalY = window.innerHeight * 0.5;
        const finalX = window.innerWidth / 2;
        
        const maxWidth = window.innerWidth * 0.8;
        const maxHeight = window.innerHeight * 0.4;
        const scaleX = maxWidth / tempCanvas.width;
        const scaleY = maxHeight / tempCanvas.height;
        const scale = Math.min(scaleX, scaleY, 1.2);
        
        const particles = [];
        const sampledPixels = [];
        
        for (let i = 0; i < letterPixels.length; i += 3) {
            sampledPixels.push(letterPixels[i]);
        }
        
        letterMap.clear();
        for (const pixel of sampledPixels) {
            const targetX = finalX + (pixel.x - tempCanvas.width / 2) * scale;
            const targetY = finalY + (pixel.y - tempCanvas.height / 2) * scale;
            
            const gridX = Math.floor(targetX);
            const gridY = Math.floor(targetY);
            letterMap.add(`${gridX},${gridY}`);
            
            for (let dx = -2; dx <= 2; dx++) {
                for (let dy = -2; dy <= 2; dy++) {
                    letterMap.add(`${gridX + dx},${gridY + dy}`);
                }
            }
            
            particles.push({
                x: Math.random() * window.innerWidth,
                y: Math.random() * window.innerHeight,
                targetX: targetX,
                targetY: targetY,
                arrived: false,
                size: Math.random() * 1.5 + 1,
                speed: Math.random() * 0.02 + 0.03
            });
        }
        
        const startTime = Date.now();
        const assemblyDuration = 3000;
        
        function easeOutCubic(t) {
            return 1 - Math.pow(1 - t, 3);
        }
        
        function animateParticles() {
            // Check if animation was skipped
            if (animationSkipped) {
                particleCanvas.remove();
                return;
            }
            
            const elapsed = Date.now() - startTime;
            const progress = Math.min(elapsed / assemblyDuration, 1);
            const easedProgress = easeOutCubic(progress);
            
            pCtx.clearRect(0, 0, particleCanvas.width, particleCanvas.height);
            
            let arrivedCount = 0;
            
            for (const p of particles) {
                if (!p.arrived) {
                    const dx = p.targetX - p.x;
                    const dy = p.targetY - p.y;
                    const dist = Math.sqrt(dx * dx + dy * dy);
                    
                    if (dist < 2) {
                        p.arrived = true;
                        p.x = p.targetX;
                        p.y = p.targetY;
                    } else {
                        let speedMultiplier = 1 + easedProgress * 2;
                        
                        if (dist < CONFIG.SLOWDOWN_DISTANCE) {
                            const slowdownFactor = dist / CONFIG.SLOWDOWN_DISTANCE;
                            speedMultiplier *= (0.3 + slowdownFactor * 0.7);
                        }
                        
                        const moveSpeed = p.speed * speedMultiplier;
                        p.x += dx * moveSpeed;
                        p.y += dy * moveSpeed;
                    }
                }
                
                if (p.arrived) arrivedCount++;
                
                let alpha;
                if (p.arrived) {
                    alpha = 1.0;
                } else {
                    const dx = p.targetX - p.x;
                    const dy = p.targetY - p.y;
                    const dist = Math.sqrt(dx * dx + dy * dy);
                    
                    if (dist < CONFIG.PARTICLE_FADE_DISTANCE) {
                        const fadeProgress = 1 - (dist / CONFIG.PARTICLE_FADE_DISTANCE);
                        alpha = 0.3 + fadeProgress * 0.7;
                    } else {
                        alpha = 0.3 + (easedProgress * 0.3);
                    }
                }
                
                pCtx.fillStyle = `rgba(0, 255, 0, ${alpha})`;
                pCtx.shadowBlur = p.arrived ? 6 : 2;
                pCtx.shadowColor = '#0f0';
                pCtx.fillRect(p.x - p.size/2, p.y - p.size/2, p.size, p.size);
            }
            
            if (arrivedCount >= particles.length * 0.95) {
                logoVisible = true;
                
                setTimeout(() => {
                    let fadeProgress = 0;
                    
                    logo = document.createElement('div');
                    logo.id = 'vektort13-logo';
                    logo.style.cssText = `
                        position: fixed;
                        top: ${finalY}px;
                        left: ${finalX}px;
                        transform: translate(-50%, -50%);
                        font-family: 'Courier New', monospace;
                        font-size: ${CONFIG.LOGO_SIZE}px;
                        font-weight: bold;
                        color: #0f0;
                        text-shadow: 0 0 20px #0f0, 0 0 40px #0f0;
                        z-index: 10002;
                        letter-spacing: 12px;
                        opacity: 0;
                        pointer-events: none;
                    `;
                    logo.textContent = CONFIG.LOGO_TEXT;
                    document.body.appendChild(logo);
                    
                    function fadeToLogo() {
                        fadeProgress += 0.02;
                        
                        pCtx.clearRect(0, 0, particleCanvas.width, particleCanvas.height);
                        
                        for (const p of particles) {
                            if (p.arrived) {
                                const alpha = 1 - fadeProgress;
                                if (alpha > 0) {
                                    pCtx.fillStyle = `rgba(0, 255, 0, ${alpha})`;
                                    pCtx.shadowBlur = 6;
                                    pCtx.shadowColor = '#0f0';
                                    pCtx.fillRect(p.x - p.size/2, p.y - p.size/2, p.size, p.size);
                                }
                            }
                        }
                        
                        logo.style.opacity = fadeProgress;
                        
                        if (fadeProgress < 1) {
                            requestAnimationFrame(fadeToLogo);
                        } else {
                            particleCanvas.remove();
                            startFlicker();
                        }
                    }
                    
                    fadeToLogo();
                }, 500);
            } else {
                requestAnimationFrame(animateParticles);
            }
        }
        
        animateParticles();
    }
    
    // ==================== FLICKER ====================
    function startFlicker() {
        // Remove skip hint (animation completed normally)
        const skipHint = document.querySelector('[data-matrix-skip-hint]');
        if (skipHint) {
            skipHint.remove();
        }
        
        let flickerCount = 0;
        const maxFlickers = 3;
        
        const flickerInterval = setInterval(() => {
            logo.style.opacity = logo.style.opacity === '1' ? '0.3' : '1';
            flickerCount++;
            
            if (flickerCount >= maxFlickers * 2) {
                clearInterval(flickerInterval);
                logo.style.opacity = '1';
                
                // NEW: Wait 5 seconds, then transition to login
                console.log('Matrix: Logo complete, waiting 5 seconds...');
                setTimeout(transitionToLogin, CONFIG.WAIT_BEFORE_LOGIN);
            }
        }, CONFIG.FLICKER_INTERVAL);
    }
    
    // ==================== TRANSITION TO LOGIN ====================
    function transitionToLogin() {
        // Prevent multiple calls
        if (animationSkipped && (canvas?.style.display === 'none' || !canvas)) {
            return;
        }
        
        console.log('Matrix: Starting transition to login form...');
        
        // Remove skip hint if exists
        const skipHint = document.querySelector('[data-matrix-skip-hint]');
        if (skipHint) {
            skipHint.remove();
        }
        
        let fadeProgress = 0;
        
        function fadeOut() {
            fadeProgress += 0.02;
            
            // Fade out logo
            if (logo) {
                logo.style.opacity = 1 - fadeProgress;
            }
            
            // Fade out matrix canvas
            if (canvas) {
                canvas.style.opacity = 1 - fadeProgress;
            }
            
            if (fadeProgress < 1) {
                requestAnimationFrame(fadeOut);
            } else {
                // Remove Matrix elements
                if (canvas) canvas.remove();
                if (logo) logo.remove();
                if (terminal) terminal.remove();
                
                // Stop matrix interval
                if (matrixInterval) {
                    clearInterval(matrixInterval);
                }
                
                // Restore login form
                console.log('Matrix: Showing login form...');
                hiddenElements.forEach(item => {
                    item.element.style.display = item.display || '';
                });
                
                // Restore overflow
                loginContainer.style.overflow = originalOverflow;
                
                // Smooth fade in login form
                hiddenElements.forEach(item => {
                    item.element.style.opacity = '0';
                    item.element.style.transition = 'opacity 1s ease-in';
                });
                
                setTimeout(() => {
                    hiddenElements.forEach(item => {
                        item.element.style.opacity = '1';
                    });
                    
                    // Show Matrix ON button after login form appears
                    createToggleButton();
                }, 50);
                
                console.log('Matrix: Animation complete, login form visible');
            }
        }
        
        fadeOut();
    }
    
    // ==================== TOGGLE BUTTON ====================
    function createToggleButton() {
        toggleBtn = document.createElement('button');
        toggleBtn.innerHTML = matrixEnabled ? 'MATRIX OFF' : 'MATRIX ON';
        toggleBtn.style.cssText = `
            position: fixed;
            bottom: 20px;
            right: 20px;
            padding: 12px 24px;
            background: rgba(0, 255, 0, 0.1);
            border: 2px solid #0f0;
            border-radius: 8px;
            color: #0f0;
            font-size: 14px;
            font-weight: bold;
            font-family: 'Courier New', monospace;
            cursor: pointer;
            z-index: 10003;
            transition: all 0.3s;
            box-shadow: 0 0 15px rgba(0, 255, 0, 0.3);
            text-shadow: 0 0 5px #0f0;
        `;
        
        toggleBtn.addEventListener('mouseenter', () => {
            toggleBtn.style.background = 'rgba(0, 255, 0, 0.2)';
            toggleBtn.style.boxShadow = '0 0 25px rgba(0, 255, 0, 0.6)';
            toggleBtn.style.transform = 'scale(1.05)';
        });
        
        toggleBtn.addEventListener('mouseleave', () => {
            toggleBtn.style.background = 'rgba(0, 255, 0, 0.1)';
            toggleBtn.style.boxShadow = '0 0 15px rgba(0, 255, 0, 0.3)';
            toggleBtn.style.transform = 'scale(1)';
        });
        
        toggleBtn.addEventListener('click', () => {
            matrixEnabled = !matrixEnabled;
            localStorage.setItem(STORAGE_KEY, matrixEnabled);
            toggleBtn.innerHTML = matrixEnabled ? 'MATRIX OFF' : 'MATRIX ON';
            
            // Show notification
            const notification = document.createElement('div');
            notification.style.cssText = `
                position: fixed;
                top: 20px;
                right: 20px;
                padding: 15px 25px;
                background: rgba(0, 0, 0, 0.9);
                border: 2px solid #0f0;
                border-radius: 8px;
                color: #0f0;
                font-family: 'Courier New', monospace;
                font-size: 14px;
                z-index: 10004;
                box-shadow: 0 0 20px rgba(0, 255, 0, 0.5);
                text-shadow: 0 0 5px #0f0;
            `;
            notification.textContent = matrixEnabled ? 
                'Matrix animation ENABLED on next login' : 
                'Matrix animation DISABLED on next login';
            
            document.body.appendChild(notification);
            
            setTimeout(() => {
                notification.style.transition = 'opacity 0.5s';
                notification.style.opacity = '0';
                setTimeout(() => notification.remove(), 500);
            }, 3000);
        });
        
        document.body.appendChild(toggleBtn);
        console.log('Matrix: Toggle button created');
    }
    
    // ==================== INIT ====================
    if (matrixEnabled) {
        console.log('Matrix: Starting animation sequence...');
        
        // Add "Press any key to skip" hint
        const skipHint = document.createElement('div');
        skipHint.setAttribute('data-matrix-skip-hint', 'true');
        skipHint.style.cssText = `
            position: fixed;
            bottom: 30px;
            left: 50%;
            transform: translateX(-50%);
            color: rgba(0, 255, 0, 0.6);
            font-family: 'Courier New', monospace;
            font-size: 14px;
            z-index: 10005;
            text-shadow: 0 0 10px rgba(0, 255, 0, 0.8);
            animation: pulse 2s ease-in-out infinite;
            pointer-events: none;
        `;
        skipHint.textContent = 'Press any key to skip...';
        
        // Add CSS animation
        const style = document.createElement('style');
        style.textContent = `
            @keyframes pulse {
                0%, 100% { opacity: 0.4; }
                50% { opacity: 1; }
            }
        `;
        document.head.appendChild(style);
        document.body.appendChild(skipHint);
        
        // Remove hint when animation is skipped OR completed
        const removeHint = function() {
            const hint = document.querySelector('[data-matrix-skip-hint]');
            if (hint && hint.parentNode) {
                hint.remove();
            }
        };
        
        document.addEventListener('keydown', removeHint, { once: true });
        
        initMatrixRain();
        initTerminal();
    } else {
        // If disabled, show login immediately with toggle button
        console.log('Matrix: Disabled, showing login form');
        hiddenElements.forEach(item => {
            item.element.style.display = item.display || '';
        });
        loginContainer.style.overflow = originalOverflow;
        
        // Show toggle button to enable Matrix
        createToggleButton();
    }
})();
