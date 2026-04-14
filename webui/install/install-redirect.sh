#!/bin/sh
# Install redirect index.html to /www root

echo "=== Installing redirect page ==="

# Backup existing index.html if present
if [ -f /www/index.html ]; then
    echo "Backing up existing /www/index.html..."
    cp /www/index.html /www/index.html.backup
fi

# Install redirect
echo "Installing redirect index.html..."
cat > /www/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta http-equiv="refresh" content="0; url=/vektort13-admin/">
    <title>Redirecting...</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            display: flex;
            align-items: center;
            justify-content: center;
            height: 100vh;
            margin: 0;
            background: #f5f5f5;
        }
        .loader {
            text-align: center;
        }
        .spinner {
            border: 4px solid #f3f3f3;
            border-top: 4px solid #4A90E2;
            border-radius: 50%;
            width: 50px;
            height: 50px;
            animation: spin 1s linear infinite;
            margin: 0 auto 20px;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        h2 {
            color: #333;
            margin: 0;
        }
        p {
            color: #666;
            margin: 10px 0 0;
        }
    </style>
    <script>
        // Relative redirect - works with any IP!
        window.location.href = '/vektort13-admin/';
    </script>
</head>
<body>
    <div class="loader">
        <div class="spinner"></div>
        <h2>VEKTORT13</h2>
        <p>Redirecting to admin panel...</p>
    </div>
</body>
</html>
EOF

echo "✓ Redirect installed"
echo ""
echo "Now when you visit http(s)://YOUR_ROUTER_IP/ you'll be redirected to vektort13-admin!"
echo "Works with ANY IP address!"
