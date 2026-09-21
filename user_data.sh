#!/bin/bash
set -euxo pipefail

# Log everything from this script to a file for debugging (tail -f /var/log/user-data.log)
exec > >(tee -a /var/log/user-data.log) 2>&1
echo "=== user-data started $(date -u) ==="

# --- Install Node.js + stress-ng (Amazon Linux 2023) ---
# stress-ng is used later to manually generate CPU load and prove the ASG
# scales out to 3 instances, then back down to 1 once the load stops.
for i in 1 2 3 4 5; do
  dnf install -y nodejs stress-ng && break
  echo "dnf install failed (attempt $i), retrying in 10s..."
  sleep 10
done
node --version
stress-ng --version

# --- Application ---
mkdir -p /opt/webapp

cat > /opt/webapp/app.js <<'EOF'
const http = require('http');
const os = require('os');

const port = process.env.PORT || 80;
const METADATA_BASE = 'http://169.254.169.254/latest';

let hitCount = 0;

function request(method, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(METADATA_BASE + path, { method, headers, timeout: 2000 }, (res) => {
      let body = '';
      res.on('data', (chunk) => (body += chunk));
      res.on('end', () => resolve(body));
    });
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.end();
  });
}

// Fetch instance identity via IMDSv2 (token required, matches metadata_options in Terraform)
async function getMetadata() {
  try {
    const token = await request('PUT', '/api/token', {
      'X-aws-ec2-metadata-token-ttl-seconds': '21600',
    });
    const headers = { 'X-aws-ec2-metadata-token': token };
    const [instanceId, localIpv4, az] = await Promise.all([
      request('GET', '/meta-data/instance-id', headers),
      request('GET', '/meta-data/local-ipv4', headers),
      request('GET', '/meta-data/placement/availability-zone', headers),
    ]);
    return { instanceId, localIpv4, az };
  } catch (err) {
    console.error('metadata fetch failed:', err.message);
    return { instanceId: 'unknown', localIpv4: 'unknown', az: 'unknown' };
  }
}

async function main() {
  const meta = await getMetadata();
  const hostname = os.hostname();
  console.log('resolved metadata:', { hostname, ...meta });

  const server = http.createServer((req, res) => {
    if (req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('ok');
      return;
    }

    if (req.url === '/api/whoami') {
      hitCount += 1;
      res.writeHead(200, { 'Content-Type': 'application/json', Connection: 'close' });
      res.end(JSON.stringify({ hostname, hits: hitCount, ...meta }));
      return;
    }

    hitCount += 1;
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SD lab03 &middot; High Availability</title>
  <style>
    :root { color-scheme: light; }
    * { box-sizing: border-box; }
    body {
      font-family: system-ui, -apple-system, sans-serif;
      max-width: 42rem;
      margin: 0 auto;
      padding: 2.5rem 1.25rem 4rem;
      color: #10241f;
      background: #f1f7f5;
    }
    h1 { font-size: 1.5rem; margin-bottom: 0.25rem; color: #0b3b2e; }
    .sub { color: #4d7a6c; margin-top: 0; margin-bottom: 1.75rem; }
    .badge { display: inline-block; background: linear-gradient(135deg, #0b3b2e, #1f7a5c); color: #eafff4; border-radius: 999px; padding: 0.15rem 0.75rem; font-size: 0.75rem; vertical-align: middle; }
    .card { border: 1px solid #d9ece4; border-radius: 16px; padding: 1.5rem 1.75rem; background: #ffffff; box-shadow: 0 1px 3px rgba(11, 59, 46, 0.08); margin-bottom: 1.25rem; }
    dl { display: grid; grid-template-columns: auto 1fr; gap: 0.4rem 1rem; margin: 0; }
    dt { font-weight: 600; color: #4d7a6c; font-size: 0.85rem; }
    dd { margin: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9rem; }
    .foot { color: #4d7a6c; font-size: 0.8rem; margin-top: 1.5rem; line-height: 1.5; }
    .foot code { background: #dff2ea; color: #0b3b2e; padding: 0.1rem 0.35rem; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>High availability app <span class="badge">lab03</span></h1>
  <p class="sub">ALB + Auto Scaling Group (1&ndash;3 EC2) &middot; HTTPS</p>
  <div class="card">
    <dl>
      <dt>Instance ID</dt><dd>${meta.instanceId}</dd>
      <dt>Private IPv4</dt><dd>${meta.localIpv4}</dd>
      <dt>Availability zone</dt><dd>${meta.az}</dd>
      <dt>Hostname</dt><dd>${hostname}</dd>
      <dt>Hits served</dt><dd>${hitCount}</dd>
    </dl>
  </div>
  <p class="foot">
    Reload to see the ALB route you to a different instance once the group scales out.
    Certificate is self-signed (no public domain in this AWS Academy account) &mdash; browsers warn once; use <code>curl -k</code>.
  </p>
</body>
</html>`);
  });

  server.listen(port, () => console.log(`listening on ${port}`));
}

main();
EOF

# --- Run as a systemd service ---
cat > /etc/systemd/system/webapp.service <<'EOF'
[Unit]
Description=Node.js web app
After=network.target

[Service]
ExecStart=/usr/bin/node /opt/webapp/app.js
Restart=always
User=root
Environment=PORT=80
WorkingDirectory=/opt/webapp

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now webapp.service
systemctl --no-pager status webapp.service || true

echo "=== user-data finished $(date -u) ==="
