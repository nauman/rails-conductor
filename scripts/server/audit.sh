#!/usr/bin/env bash
# Read-only security & maintenance audit. Run as a sudo user.
set -uo pipefail

pass() { echo "  PASS  $1"; }
warn() { echo "  WARN  $1"; }

echo "== SSH =="
cfg=$(sudo sshd -T 2>/dev/null)
echo "$cfg" | grep -q "^permitrootlogin no" && pass "root login disabled" || warn "root login ENABLED"
echo "$cfg" | grep -q "^passwordauthentication no" && pass "password auth disabled" || warn "password auth ENABLED"
echo "$cfg" | grep -q "^x11forwarding no" && pass "X11 forwarding disabled" || warn "X11 forwarding enabled"

echo "== Firewall =="
sudo ufw status 2>/dev/null | grep -q "Status: active" && pass "ufw active" || warn "ufw inactive"

echo "== fail2ban =="
sudo fail2ban-client status sshd >/dev/null 2>&1 && pass "sshd jail active" || warn "no sshd jail"

echo "== Auto-updates =="
grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null && pass "unattended-upgrades on" || warn "unattended-upgrades off"
grep -rq 'Automatic-Reboot "true"' /etc/apt/apt.conf.d/ 2>/dev/null && pass "auto-reboot on" || warn "auto-reboot off"
n=$(sudo apt-get -s upgrade 2>/dev/null | grep -c "^Inst.*security"); [ "$n" -eq 0 ] && pass "no pending security updates" || warn "$n security updates pending"

echo "== Reboot =="
[ -f /var/run/reboot-required ] && warn "reboot required" || pass "no reboot pending"
