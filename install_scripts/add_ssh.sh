#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

echo ""
echo "🔍 Checking SSH installation..."
echo ""

if ! dpkg -s openssh-server &> /dev/null; then
    echo "🛠️ Installing OpenSSH server..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq openssh-server
else
    echo "✅ OpenSSH server already installed."
fi

echo "🔧 Checking SSH service status..."

if ! systemctl is-active --quiet ssh; then
    echo "🚀 Starting and enabling SSH service..."
    sudo systemctl enable ssh
    sudo systemctl start ssh
else
    echo "✅ SSH service is already running."
fi

echo "🛡️ Checking UFW firewall..."

if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
    if sudo ufw status numbered | grep -qE "^.*ALLOW.*22"; then
        echo "✅ Port 22 is already allowed through UFW."
    else
        echo "Allowing SSH (port 22) through UFW..."
        echo "y" | sudo ufw allow 22/tcp > /dev/null
    fi
else
    echo "⚠️ UFW not active or not installed. Skipping firewall configuration."
fi

echo ""
echo "✅ SSH installation and configuration complete"
echo ""
