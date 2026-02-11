#!/bin/bash
echo "=== S2 Code Shop - VPN API Setup ==="
echo ""

sudo apt update
sudo apt install -y wireguard nodejs npm nginx certbot python3-certbot-nginx

sudo mkdir -p /etc/wireguard
cd /etc/wireguard

SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

echo "$SERVER_PRIVATE_KEY" | sudo tee /etc/wireguard/server_privatekey > /dev/null
echo "$SERVER_PUBLIC_KEY" | sudo tee /etc/wireguard/server_publickey > /dev/null
sudo chmod 600 /etc/wireguard/server_privatekey

PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)

sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.0.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE; iptables -D FORWARD -o wg0 -j ACCEPT
EOF

echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

VPN_API_KEY=$(openssl rand -hex 32)

sudo mkdir -p /opt/vpn-api
sudo cp /home/ubuntu/aws-vpn-api/server.js /opt/vpn-api/
cd /opt/vpn-api
sudo npm init -y
sudo npm install express qrcode

sudo tee /etc/systemd/system/vpn-api.service > /dev/null << EOF
[Unit]
Description=VPN API Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vpn-api
Environment=VPN_API_KEY=$VPN_API_KEY
Environment=SERVER_ENDPOINT=$PUBLIC_IP:51820
Environment=PORT=3000
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable vpn-api
sudo systemctl start vpn-api

sudo tee /etc/nginx/sites-available/vpn-api > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_cache_bypass $http_upgrade;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/vpn-api /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl restart nginx

echo ""
echo "=========================================="
echo "  SETUP HOAN TAT!"
echo "=========================================="
echo ""
echo "Server Public IP: $PUBLIC_IP"
echo "WireGuard Public Key: $SERVER_PUBLIC_KEY"
echo ""
echo "=== DIEN VAO REPLIT ==="
echo "VPN_API_URL = http://$PUBLIC_IP/vpn/create"
echo "VPN_API_KEY = $VPN_API_KEY"
echo ""
echo "=== KHONG QUEN MO SECURITY GROUP ==="
echo "- UDP 51820 (WireGuard)"
echo "- TCP 80 (HTTP)"
echo "- TCP 443 (HTTPS - neu dung SSL)"
echo ""
echo "=== TEST ==="
echo "curl -X POST http://$PUBLIC_IP/vpn/create -H 'Content-Type: application/json' -H 'X-API-KEY: $VPN_API_KEY' -d '{\"clientIp\":\"test\",\"device\":\"test\"}'"
echo ""
echo "Luu lai VPN_API_KEY vi khong hien lai duoc!"
