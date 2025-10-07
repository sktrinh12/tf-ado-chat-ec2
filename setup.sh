#!/bin/bash
set -e

USER=ec2-user
HOME_PATH=/home/$USER

echo "=== Starting setup at $(date) ==="

# Fetch metadata token
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Fetch public IP using token
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

echo "PUBLIC IP: $PUBLIC_IP"

REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

echo "REGION: $REGION"

HF_TOKEN=$(aws ssm get-parameter --name /app/hf-token --with-decryption \
  --query Parameter.Value --output text --region "$REGION")

# Domain setup - Terraform injects these
DUCKDNS_DOMAIN="${duckdns_domain}"
LETSENCRYPT_EMAIL="${letsencrypt_email}"
DUCKDNS_TOKEN=""
DELAY=45

if [ -n "$DUCKDNS_DOMAIN" ]; then
  echo "DuckDNS domain configured: $DUCKDNS_DOMAIN"
  
  DUCKDNS_TOKEN=$(aws ssm get-parameter --name /app/duckdns-token --with-decryption \
    --query Parameter.Value --output text --region "$REGION" 2>/dev/null || echo "")
  
  if [ -n "$DUCKDNS_TOKEN" ]; then
    echo "Updating DuckDNS IP..."
    SUBDOMAIN=$(echo "$DUCKDNS_DOMAIN" | sed 's/.duckdns.org//')
    curl "https://www.duckdns.org/update?domains=$SUBDOMAIN&token=$DUCKDNS_TOKEN&ip=$PUBLIC_IP"
    
    echo "Waiting $DELAY for DNS propagation..."
    sleep $DELAY
  fi
fi

# Pull ChromaDB data from S3
echo "Pulling ChromaDB data from S3..."
mkdir -p "$HOME_PATH/app/chroma"
aws s3 cp s3://preludetx-strinh/chroma "$HOME_PATH/app/chroma" --recursive

# Clone frontend repo and build (React + Vite)
echo "Cloning and building frontend..."
git clone https://github.com/sktrinh12/ado-chat-agent.git "$HOME_PATH/frontend"

cd "$HOME_PATH/frontend"

if [ -n "$DUCKDNS_DOMAIN" ]; then
  BACKEND_URL="https://$DUCKDNS_DOMAIN"
  sed -i 's|http://localhost:8000|/api|g' ./src/App.tsx
else
  BACKEND_URL="http://$PUBLIC_IP"
  sed -i "s|localhost|$PUBLIC_IP|g" ./src/App.tsx
fi

echo "Backend URL configured as: $BACKEND_URL"
grep -nE "$PUBLIC_IP|$DUCKDNS_DOMAIN" ./src/App.tsx || true

npm install
npm run build

# Set permissions
echo "Setting permissions..."
sudo chmod 755 "$HOME_PATH"
sudo chmod -R 755 "$HOME_PATH/frontend"
sudo chown -R $USER:nginx "$HOME_PATH/frontend"
sudo chown -R $USER:$USER "$HOME_PATH/app/chroma"
sudo chmod -R 755 "$HOME_PATH/app/chroma"

# FastAPI backend setup
echo "Setting up FastAPI backend..."
cd "$HOME_PATH/app"
curl -O https://raw.githubusercontent.com/sktrinh12/misc-scripts/main/azure_workitem_llm/llm_svc.py

if [ -n "$DUCKDNS_DOMAIN" ]; then
  sed -i "/origins = \[/,/]/c\origins = [\"https://$DUCKDNS_DOMAIN\", \"http://localhost:5173\"]" llm_svc.py
else
  sed -i "/origins = \[/,/]/c\origins = [\"http://$PUBLIC_IP\", \"http://localhost:5173\"]" llm_svc.py
fi

grep "origins" -A 3 llm_svc.py

sudo tee /etc/systemd/system/fastapi.service > /dev/null <<EOF
[Unit]
Description=FastAPI app with Uvicorn
After=network.target

[Service]
User=$USER
WorkingDirectory=$HOME_PATH/app
Environment="HF_TOKEN=$HF_TOKEN"
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
if [ -n "$DUCKDNS_DOMAIN" ] && [ -n "$DUCKDNS_TOKEN" ] && [ -n "$LETSENCRYPT_EMAIL" ]; then
  echo "Setting up nginx with SSL via Let's Encrypt..."

  CERTS_DIR="$HOME_PATH/ssl-certs"
  mkdir -p $CERTS_DIR
  chown -R $USER:$USER $CERTS_DIR

  sudo tee /etc/nginx/conf.d/ado_app.conf > /dev/null <<EOF
server {
    listen 80;
    server_name $DUCKDNS_DOMAIN;
    return 301 https://$host$request_uri;  # redirect all HTTP to HTTPS
}

server {
    listen 443 ssl;
    server_name $DUCKDNS_DOMAIN;

    ssl_certificate $CERTS_DIR/fullchain.pem;
    ssl_certificate_key $CERTS_DIR/privkey.pem;
    
    root $HOME_PATH/frontend/dist;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    location /api/ {
        proxy_pass http://localhost:8000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  sudo yum install -y certbot python3-certbot-nginx

  echo "Checking S3 for existing certs..."
  aws s3 ls s3://preludetx-strinh/ado-chat-certs/ > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo "Downloading existing certs from S3..."
    aws s3 cp s3://preludetx-strinh/ado-chat-certs/fullchain.pem $CERTS_DIR/fullchain.pem
    aws s3 cp s3://preludetx-strinh/ado-chat-certs/privkey.pem   $CERTS_DIR/privkey.pem
    aws s3 cp s3://preludetx-strinh/ado-chat-certs/chain.pem     $CERTS_DIR/chain.pem
    aws s3 cp s3://preludetx-strinh/ado-chat-certs/cert.pem      $CERTS_DIR/cert.pem
  else
    echo "No certs found in S3, running Certbot..."
    sudo yum install -y certbot python3-certbot-nginx
    sudo certbot --nginx -d $DUCKDNS_DOMAIN --non-interactive --agree-tos -m $LETSENCRYPT_EMAIL --redirect
  fi

  sudo dnf install -y cronie
  sudo systemctl enable crond
  sudo systemctl start crond
  (sudo crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | sudo crontab -

else
  echo "Setting up nginx without SSL (using IP)..."
  sudo tee /etc/nginx/conf.d/ado_app.conf > /dev/null <<EOF
server {
    listen 80;
    root $HOME_PATH/frontend/dist;
    index index.html;
    location / {
        try_files \$uri /index.html;
    }
    location /api {
        proxy_pass http://127.0.0.1:8000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
fi

sudo systemctl restart nginx

if [ -n "$DUCKDNS_DOMAIN" ] && [ -n "$DUCKDNS_TOKEN" ]; then
  echo "Setting up DuckDNS auto-update cron job..."
  SUBDOMAIN=$(echo "$DUCKDNS_DOMAIN" | sed 's/.duckdns.org//')
  CRON_CMD="*/5 * * * * curl -s 'https://www.duckdns.org/update?domains=$SUBDOMAIN&token=$DUCKDNS_TOKEN&ip=' >/dev/null 2>&1"
  (crontab -l 2>/dev/null | grep -v duckdns.org; echo "$CRON_CMD") | crontab -
fi

echo "=== Setup completed successfully at $(date) ==="
echo "=== Access your app at: $BACKEND_URL ==="
