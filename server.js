const express = require('express');
const { execSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const QRCode = require('qrcode');

const app = express();
app.use(express.json());

const API_KEY = process.env.VPN_API_KEY || crypto.randomBytes(32).toString('hex');
const SERVER_PUBLIC_KEY = execSync('cat /etc/wireguard/server_publickey').toString().trim();
const SERVER_ENDPOINT = process.env.SERVER_ENDPOINT || 'YOUR_EC2_PUBLIC_IP:51820';
const WG_INTERFACE = 'wg0';
const SUBNET_PREFIX = '10.0.0';
const MAX_PEERS = 200;
const EXPIRE_MINUTES = 15;

const activePeers = new Map();
let nextIP = 2;

function getNextIP() {
  for (let i = 2; i <= 254; i++) {
    const ip = `${SUBNET_PREFIX}.${i}`;
    let inUse = false;
    for (const [, peer] of activePeers) {
      if (peer.ip === ip) { inUse = true; break; }
    }
    if (!inUse) return ip;
  }
  return null;
}

function authMiddleware(req, res, next) {
  const key = req.headers['x-api-key'];
  if (key !== API_KEY) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
}

app.post('/vpn/create', authMiddleware, async (req, res) => {
  try {
    if (activePeers.size >= MAX_PEERS) {
      return res.status(429).json({ error: 'Too many active peers' });
    }

    const clientIP = getNextIP();
    if (!clientIP) {
      return res.status(503).json({ error: 'No available IP addresses' });
    }

    const privateKey = execSync('wg genkey').toString().trim();
    const publicKey = execSync(`echo "${privateKey}" | wg pubkey`).toString().trim();

    execSync(`wg set ${WG_INTERFACE} peer ${publicKey} allowed-ips ${clientIP}/32`);

    const config = `[Interface]
PrivateKey = ${privateKey}
Address = ${clientIP}/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25`;

    const qrDataUrl = await QRCode.toDataURL(config, { width: 256, margin: 1 });

    const expiresAt = Date.now() + EXPIRE_MINUTES * 60 * 1000;
    activePeers.set(publicKey, {
      ip: clientIP,
      publicKey,
      expiresAt,
      createdAt: Date.now()
    });

    console.log(`[+] Peer created: ${clientIP} (${publicKey.substring(0, 8)}...) expires in ${EXPIRE_MINUTES}min`);

    res.json({
      config,
      qr: qrDataUrl,
      expiresAt
    });
  } catch (err) {
    console.error('Error creating peer:', err);
    res.status(500).json({ error: 'Failed to create VPN peer' });
  }
});

app.get('/vpn/status', authMiddleware, (req, res) => {
  res.json({
    activePeers: activePeers.size,
    maxPeers: MAX_PEERS,
    uptime: process.uptime()
  });
});

function cleanupExpiredPeers() {
  const now = Date.now();
  for (const [publicKey, peer] of activePeers) {
    if (now >= peer.expiresAt) {
      try {
        execSync(`wg set ${WG_INTERFACE} peer ${publicKey} remove`);
        activePeers.delete(publicKey);
        console.log(`[-] Peer removed: ${peer.ip} (${publicKey.substring(0, 8)}...) expired`);
      } catch (err) {
        console.error(`Error removing peer ${publicKey}:`, err);
      }
    }
  }
}

setInterval(cleanupExpiredPeers, 60 * 1000);

const PORT = process.env.PORT || 3000;
app.listen(PORT, '0.0.0.0', () => {
  console.log(`VPN API running on port ${PORT}`);
  console.log(`API Key: ${API_KEY}`);
  console.log(`Server endpoint: ${SERVER_ENDPOINT}`);
  console.log(`Max peers: ${MAX_PEERS}`);
});
