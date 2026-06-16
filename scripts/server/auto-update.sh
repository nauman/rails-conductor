#!/usr/bin/env bash
# Automatic security updates with a safe nightly auto-reboot — idempotent.
# Ubuntu 22.04+. Run as a sudo user.
set -euo pipefail

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades update-notifier-common >/dev/null

# Enable the daily update + unattended-upgrade timers.
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Apply security updates, clean up, and auto-reboot at 04:00 if a kernel update needs it.
sudo tee /etc/apt/apt.conf.d/52-conductor-unattended >/dev/null <<'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}";
  "${distro_id}:${distro_codename}-security";
  "${distro_id}ESMApps:${distro_codename}-apps-security";
  "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

sudo systemctl enable --now unattended-upgrades >/dev/null 2>&1
echo "[auto-update] security auto-updates on; auto-reboot 04:00 (server local time)."
