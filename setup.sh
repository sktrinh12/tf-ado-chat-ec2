#!/bin/bash
set -e

HOME_PATH=/home/ec2-user
LOG_FILE=/var/log/setup.log

exec > >(tee -a $$LOG_FILE)
exec 2>&1

echo "=== Starting setup at $$(date) ==="

# Fetch metadata token
TOKEN=$$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \\
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Fetch public IP using token
PUBLIC_IP=$$(curl -s -H "X-aws-ec2-metadata-token: $$TOKEN" \\
  http://169.254.169.254/latest/meta-data/public-ipv4)

echo "PUBLIC IP: $${PUBLIC_IP}"

REGION=$$(curl -s -H "X-aws-ec2-metadata-token: $$TOKEN" \\
  http://169.254.169.254/latest/meta-data/placement/region)

echo "REGION: $${REGION}"

HF_TOKEN=$$(aws ssm get-parameter \\
  --name /app/hf-token \\
  --with-decryption \\
  --query Parameter.Value \\
  --output text \\
  --region $$REGION)

# Domain setup - Terraform injects these
DUCKDNS_DOMAIN="${duckdns_domain}"
LETSENCRYPT_EMAIL="${letsencrypt_email}"
DUCKDNS_TOKEN=""

if [ -n "$$DUCKDNS_DOMAIN" ]; then
  echo "DuckDNS domain configured: $$DUCKDNS_DOMAIN"
  
  # Fetch DuckDNS token from SSM
  DUCKDNS_TOKEN=$$(aws ssm get-parameter \\
    --name /app/duckdns-token \\
    --with-decryption \\
    --query Parameter.Value \\
    --output text \\
    --region $$REGION 2>/dev/null || echo "")
  
  if [ -n "$$DUCKDNS_TOKEN" ]; then
    echo "Updating DuckDNS IP..."
    curl "https://www.duckdns.org/update?domains=$${DUCKDNS_DOMAIN//.duckdns.org/}&token=$${DUCKDNS_TOKEN}&ip=$${PUBLIC_IP}"
    
    # Wait for DNS propagation
    echo "Waiting 30s for DNS propagation..."
    sleep 30
  fi
fi

# Pull ChromaDB data from S3
echo "Pulling ChromaDB data from S3..."
mkdir -p $$HOME_PATH/app/chroma
aws s3 cp s3://preludetx-strinh/chroma $$HOME_PATH/app/chroma --recursive

# Clone frontend repo and build (React + Vite)
echo "Cloning and building frontend..."
git clone https://github.com/sktrinh12/ado-chat-agent.git $$HOME_PATH/frontend

# inject public ip for backend call
cd $$HOME_PATH/frontend

if [ -n "$$DUCKDNS_DOMAIN" ]; then
  BACKEND_URL="https://$$DUCKDNS_DOMAIN"
  sed -i "s|localhost|$$DUCKDNS_DOMAIN|g" ./src/App.tsx
  sed -i "s|http://|https://|g" ./src/App.tsx
else
  BACKEND_URL="http://$$PUBLIC_IP"
  sed -i "s|localhost|$$PUBLIC_IP|g" ./src/App.tsx
fi

echo "Backend URL configured as: $$BACKEND_URL"

grep -n "PUBLIC_IP\\|$$DUCKDNS_DOMAIN" ./src/App.tsx || true

npm install
npm run build

# Ensure nginx can read the built frontend files
echo "Setting permissions..."
sudo chmod 755 $$HOME_PATH
sudo chmod -R 755 $$HOME_PATH/frontend
sudo chown -R ec2-user:nginx $$HOME_PATH/frontend

# Ensure ec2-user can read the chroma directory
sudo chown -R ec2-user:ec2-user $$HOME_PATH/app/chroma*
sudo chmod -R 755 $$HOME_PATH/app/chroma*

# Download FastAPI backend script
echo "Setting up FastAPI backend..."
cd $$HOME_PATH/app
curl -O https://raw.githubusercontent.com/sktrinh12/misc-scripts/main/azure_workitem_llm/llm_svc.py

# Inject public IP into llm_svc.py CORS origins
if [ -n "$$DUCKDNS_DOMAIN" ]; then
  sed -i "/origins = \\[/,/]/c\\origins = [\\\"https://$$DUCKDNS_DOMAIN\\\", \\\"http://localhost:5173\\\"]" $$HOME_PATH/app/llm_svc.py
else
  sed -i "/origins = \\[/,/]/c\\origins = [\\\"http://$$PUBLIC_IP\\\", \\\"http://localhost:5173\\\"]" $$HOME_PATH/app/llm_svc.py
fi

# check output of origins
grep "origins" -A 3 $$HOME_PATH/app/llm_svc.py

# fastapi backend service
echo "Creating FastAPI systemd service..."
sudo tee /etc/systemd/system/fastapi.service > /dev/null <<EOF
[Unit]
Description=FastAPI app with Uvicorn
After=network.target

[Service]
User=ec2-user
WorkingDirectory=$$HOME_PATH/app
Environment="HF_TOKEN=$$HF_TOKEN"
ExecStart=/usr/local/bin/python3 -m uvicorn llm_svc:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable fastapi
sudo systemctl start fastapi

# Setup Nginx reverse proxy
if [ -n "$$DUCKDNS_DOMAIN" ] && [ -n "$$DUCKDNS_TOKEN" ] && [ -n "$$LETSENCRYPT_EMAIL" ]; then
  echo "Setting up nginx with SSL via Let's Encrypt..."

  sudo tee /etc/nginx/conf.d/ado_app.conf > /dev/null <<EOF
server {
    listen 80;
    server_name $$DUCKDNS_DOMAIN;
    
    root $$HOME_PATH/frontend/dist;
    index index.html;
    
    location / {
        try_files \$$uri \$$uri/ /index.html;
    }
    
    location /api {
        proxy_pass http://localhost:8000;
        proxy_set_header Host \$$host;
        proxy_set_header X-Real-IP \$$remote_addr;
        proxy_set_header X-Forwarded-For \$$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$$scheme;
    }
}
EOF

  sudo systemctl restart nginx
  
  # Install certbot
  echo "Installing certbot..."
  sudo yum install -y certbot python3-certbot-nginx
  
  # Get Let's Encrypt certificate
  echo "Obtaining Let's Encrypt certificate..."
  sudo certbot --nginx \\
    -d $$DUCKDNS_DOMAIN \\
    --non-interactive \\
    --agree-tos \\
    -m $$LETSENCRYPT_EMAIL \\
    --redirect
  
  # Setup auto-renewal
  echo "Setting up certificate auto-renewal..."
  (sudo crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | sudo crontab -
  
else
  echo "Setting up nginx without SSL (using IP)..."
  
  sudo tee /etc/nginx/conf.d/ado_app.conf > /dev/null <<EOF
server {
    listen 80;
    
    location / {
        root $$HOME_PATH/frontend/dist;
        index index.html;
        try_files \$$uri /index.html;
    }
    
    location /api {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host \$$host;
        proxy_set_header X-Real-IP \$$remote_addr;
        proxy_set_header X-Forwarded-For \$$proxy_add_x_forwarded_for;
    }
}
EOF

  sudo systemctl restart nginx
fi

# Create DuckDNS update cron job (if configured)
if [ -n "$$DUCKDNS_DOMAIN" ] && [ -n "$$DUCKDNS_TOKEN" ]; then
  echo "Setting up DuckDNS auto-update cron job..."
  CRON_CMD="*/5 * * * * curl -s 'https://www.duckdns.org/update?domains=$${DUCKDNS_DOMAIN//.duckdns.org/}&token=$${DUCKDNS_TOKEN}&ip=' >/dev/null 2>&1"
  (crontab -l 2>/dev/null | grep -v duckdns.org; echo "$$CRON_CMD") | crontab -
fi

echo "=== Setup completed successfully at $$(date) ==="
echo "=== Access your app at: $$BACKEND_URL ==="
