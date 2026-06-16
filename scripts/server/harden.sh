#!/usr/bin/env bash
# Server security hardening — idempotent.
#
# Locks SSH to key-only (no root, no password, no X11), enables the firewall
# (SSH/HTTP/HTTPS only), and fail2ban for sshd.
#
# PREREQUISITE: key-based SSH for a sudo user must already work, or you will
# lock yourself out. Run as that user (uses sudo). Ubuntu 22.04+.
set -euo pipefail

echo "[harden] SSH: key-only, no root login, no X11"
sudo install -d -m 755 /etc/ssh/sshd_config.d
# 10- sorts before cloud-init's 50-*, and sshd uses the first match, so this wins.
sudo tee /etc/ssh/sshd_config.d/10-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF
sudo sshd -t
sudo systemctl reload ssh

echo "[harden] Firewall (ufw): SSH/HTTP/HTTPS only"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null
sudo ufw allow OpenSSH >/dev/null
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443/tcp >/dev/null
sudo ufw --force enable >/dev/null

echo "[harden] fail2ban (sshd)"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null
sudo systemctl enable --now fail2ban >/dev/null 2>&1

echo "[harden] done — verify a NEW key-based SSH session before closing this one."
