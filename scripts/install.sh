#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# omarchy-gaming install script
# -----------------------------
# Targets: Arch-based (Omarchy), Pure Wayland/Hyprland, NVIDIA RTX 30xx+
# Safe to re-run (idempotent-ish). Creates backups before changes.
#
# What it does:
# - Installs Steam + Gamescope + MangoHud + GameMode + Vulkan (+32-bit) + PipeWire/WirePlumber + steam-devices
# - Installs NVIDIA DKMS driver stack (+32-bit userspace)
# - Ensures nvidia DRM modeset via bootloader param AND modprobe fallback
# - Writes Hyprland drop-in: ~/.config/hypr/conf.d/99-gaming.conf
# - Installs ProtonUp-Qt via yay if available
# - Runs best-effort post-install checks and prints next steps

log()  { printf "\n\033[1;32m[omarchy-gaming]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[warn]\033[0m %s\n" "$*"; }
die()  { printf "\n\033[1;31m[error]\033[0m %s\n" "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

if [[ ${EUID:-999} -eq 0 ]]; then
  die "Do not run as root. Run as your user; the script will sudo as needed."
fi

if ! need_cmd pacman; then
  die "pacman not found. This script targets Arch/Arch-based systems (Omarchy)."
fi

# -----------------------------
# User-configurable toggles
# -----------------------------
INSTALL_LTS_KERNEL="${INSTALL_LTS_KERNEL:-0}"      # 1 = install linux-lts + headers
ENABLE_HYPR_VRR="${ENABLE_HYPR_VRR:-1}"            # 0 = skip VRR snippet
SET_NVIDIA_ENV="${SET_NVIDIA_ENV:-1}"              # 0 = skip NVIDIA env vars snippet
APPLY_MODESET_PARAM="${APPLY_MODESET_PARAM:-1}"    # 0 = don't touch bootloader cmdline
INSTALL_PORTALS="${INSTALL_PORTALS:-1}"            # 0 = skip xdg-desktop-portal stack
INSTALL_AUR="${INSTALL_AUR:-1}"                    # 0 = skip AUR installs (protonup-qt)
HYPR_DROPIN_OVERWRITE="${HYPR_DROPIN_OVERWRITE:-1}" # 0 = do not overwrite existing 99-gaming.conf
BACKUP_CONFIG="${BACKUP_CONFIG:-1}"                # 0 = skip backup tarball creation

# -----------------------------
# Preflight: multilib check (Steam/Proton)
# -----------------------------
check_multilib() {
  # True if [multilib] exists and is NOT commented out.
  if grep -Eq '^\s*\[multilib\]\s*$' /etc/pacman.conf && ! grep -Eq '^\s*#\s*\[multilib\]\s*$' /etc/pacman.conf; then
    log "multilib appears enabled in /etc/pacman.conf"
    return 0
  fi

  warn "multilib may be disabled in /etc/pacman.conf."
  warn "Steam/Proton typically requires multilib. If Steam install/runtime fails, enable it:"
  warn "  1) sudo nano /etc/pacman.conf"
  warn "  2) uncomment:"
  warn "     [multilib]"
  warn "     Include = /etc/pacman.d/mirrorlist"
  warn "  3) sudo pacman -Syu"
}
check_multilib

# -----------------------------
# Backup Hyprland config
# -----------------------------
backup_hypr() {
  [[ "$BACKUP_CONFIG" == "1" ]] || { warn "Skipping backup (BACKUP_CONFIG=0)."; return 0; }

  local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
  if [[ ! -d "$cfg_dir" ]]; then
    warn "Hyprland config not found at $cfg_dir — skipping Hypr backup."
    return 0
  fi

  local backup_dir="$HOME/omarchy-backups"
  mkdir -p "$backup_dir"
  local out="$backup_dir/hypr-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$out" -C "${XDG_CONFIG_HOME:-$HOME/.config}" hypr
  log "Backed up Hyprland config to: $out"
}
backup_hypr

# -----------------------------
# Steam: desktop entry to launch in Big Picture (Gamepad UI)
# -----------------------------
write_steam_big_picture_entry() {
  local app_dir="$HOME/.local/share/applications"
  local desktop_file="$app_dir/steam-bp.desktop"

  mkdir -p "$app_dir"

  cat > "$desktop_file" <<'EOF'
[Desktop Entry]
Name=Steam (Big Picture)
Comment=Steam Client in Big Picture / Gamepad UI
Type=Application
Categories=Game;
Terminal=false
Icon=steam
Exec=steam -gamepadui %U
MimeType=x-scheme-handler/steam;
EOF

  log "Wrote Steam launcher: $desktop_file"
}
write_steam_big_picture_entry

# -----------------------------
# Packages
# -----------------------------
BASE_PKGS=(
  linux-headers
  steam
  gamescope
  mangohud
  lib32-mangohud
  gamemode
  vulkan-tools
  vulkan-icd-loader
  lib32-vulkan-icd-loader
  pipewire pipewire-alsa pipewire-pulse wireplumber
)

NVIDIA_PKGS=(
  nvidia-dkms
  nvidia-utils
  lib32-nvidia-utils
)

LTS_PKGS=(linux-lts linux-lts-headers)

AUR_PKGS=(
  protonup-qt
  proton-ge-custom
  protontricks
)

# -----------------------------
# Install packages
# -----------------------------
log "Updating system + installing core gaming packages..."
sudo pacman -Syu --needed --noconfirm "${BASE_PKGS[@]}"
log "Installing Steam controller udev rules (optional)..."
if pacman -Si steam-devices >/dev/null 2>&1; then
  sudo pacman -S --needed --noconfirm steam-devices
else
  warn "Package 'steam-devices' not found in enabled repos. Skipping."
  warn "If you have controller issues, install equivalent udev rules package for your distro or add Steam udev rules manually."
fi

if [[ "$INSTALL_PORTALS" == "1" ]]; then
  log "Installing xdg-desktop-portal stack (Wayland integration)..."
  # Prefer Hyprland portal if available, otherwise fall back to wlr.
  if pacman -Si xdg-desktop-portal-hyprland >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm xdg-desktop-portal xdg-desktop-portal-hyprland
  else
    sudo pacman -S --needed --noconfirm xdg-desktop-portal xdg-desktop-portal-wlr
  fi
else
  warn "Skipping xdg-desktop-portal install (INSTALL_PORTALS=0)."
fi

log "Installing NVIDIA driver stack (DKMS)..."

# Respect existing NVIDIA kernel module choice to avoid conflicts:
# - If nvidia-open-dkms is installed, do NOT install nvidia-dkms.
# - If neither is installed, default to nvidia-dkms.
if pacman -Qq nvidia-open-dkms >/dev/null 2>&1; then
  warn "Detected nvidia-open-dkms already installed. Skipping nvidia-dkms to avoid conflicts."
  sudo pacman -S --needed --noconfirm nvidia-utils lib32-nvidia-utils
else
  sudo pacman -S --needed --noconfirm "${NVIDIA_PKGS[@]}"
fi

log "Ensuring NVIDIA DRM modeset via modprobe.d as a fallback..."
sudo mkdir -p /etc/modprobe.d
if [[ ! -f /etc/modprobe.d/nvidia.conf ]]; then
  echo "options nvidia-drm modeset=1" | sudo tee /etc/modprobe.d/nvidia.conf >/dev/null
  log "Wrote /etc/modprobe.d/nvidia.conf"
else
  log "/etc/modprobe.d/nvidia.conf already exists (not overwriting)."
fi

if [[ "$INSTALL_LTS_KERNEL" == "1" ]]; then
  log "Installing LTS kernel..."
  sudo pacman -S --needed --noconfirm "${LTS_PKGS[@]}"
else
  warn "Skipping linux-lts. (Set INSTALL_LTS_KERNEL=1 to install it.)"
fi

# -----------------------------
# Enable services
# -----------------------------
log "Enabling WirePlumber (user audio session manager)..."
systemctl --user enable --now wireplumber.service >/dev/null 2>&1 || true

log "Enabling GameMode daemon (user)..."
systemctl --user enable --now gamemoded.service >/dev/null 2>&1 || true

# -----------------------------
# Hyprland drop-in config
# -----------------------------
write_hypr_dropin() {
  local hypr_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
  mkdir -p "$hypr_dir/conf.d"
  local conf_file="$hypr_dir/conf.d/99-gaming.conf"

  if [[ -f "$conf_file" && "$HYPR_DROPIN_OVERWRITE" != "1" ]]; then
    warn "Hyprland drop-in exists and overwrite disabled (HYPR_DROPIN_OVERWRITE=0)."
    warn "Skipping: $conf_file"
    return 0
  fi

  log "Writing Hyprland gaming drop-in: $conf_file"
  {
    echo "# Generated by omarchy-gaming scripts/install.sh"
    echo "# Safe to edit. Re-running install.sh may overwrite this file unless HYPR_DROPIN_OVERWRITE=0."
    echo

    if [[ "$SET_NVIDIA_ENV" == "1" ]]; then
      echo "# NVIDIA + Wayland (GBM)"
      echo "env = GBM_BACKEND,nvidia-drm"
      echo "env = __GLX_VENDOR_LIBRARY_NAME,nvidia"
      echo "env = LIBVA_DRIVER_NAME,nvidia"
      echo
      echo "# If you see cursor corruption, uncomment:"
      echo "# env = WLR_NO_HARDWARE_CURSORS,1"
      echo
      echo "# If Firefox is unstable on NVIDIA, Hyprland suggests removing GBM_BACKEND."
      echo "# (Keep __GLX_VENDOR_LIBRARY_NAME.)"
      echo
    else
      echo "# NVIDIA env vars skipped (SET_NVIDIA_ENV=0)"
      echo
    fi

    if [[ "$ENABLE_HYPR_VRR" == "1" ]]; then
      echo "# VRR (Adaptive Sync)"
      echo "# vrr = 1 enables VRR always; some displays may flicker."
      echo "misc {"
      echo "  vrr = 1"
      echo "}"
      echo
    else
      echo "# VRR skipped (ENABLE_HYPR_VRR=0)"
      echo
    fi

    echo "# Notes:"
    echo "# - Prefer running games with gamescope (Steam launch options)."
    echo "# - Example: gamescope -f -r 144 --adaptive-sync -- %command%"
  } | tee "$conf_file" >/dev/null
}
write_hypr_dropin

# -----------------------------
# Bootloader: ensure nvidia-drm.modeset=1
# -----------------------------
ensure_nvidia_modeset() {
  local param="nvidia-drm.modeset=1"

  if [[ "$APPLY_MODESET_PARAM" != "1" ]]; then
    warn "Skipping bootloader cmdline update (APPLY_MODESET_PARAM=0)."
    warn "You should still ensure kernel cmdline includes: $param"
    return 0
  fi

  log "Ensuring kernel cmdline contains: $param"

  # systemd-boot entries
  if [[ -d /boot/loader/entries ]]; then
    log "Detected systemd-boot entries in /boot/loader/entries"
    local changed=0

    for f in /boot/loader/entries/*.conf; do
      [[ -f "$f" ]] || continue
      if grep -q "$param" "$f"; then
        continue
      fi

      if grep -qE '^\s*options\s+' "$f"; then
        sudo sed -i "s/^\(\s*options\s\+\)/\1$param /" "$f"
        changed=1
        log "Updated: $f"
      else
        echo "options $param" | sudo tee -a "$f" >/dev/null
        changed=1
        log "Appended options to: $f"
      fi
    done

    if [[ "$changed" -eq 1 ]]; then
      log "systemd-boot entries updated."
    else
      log "systemd-boot already configured."
    fi
    return 0
  fi

  # GRUB
  if [[ -f /etc/default/grub ]]; then
    log "Detected GRUB config at /etc/default/grub"

    if grep -q "$param" /etc/default/grub; then
      log "GRUB already contains $param"
      return 0
    fi

    if grep -q 'GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
      sudo sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 $param\"/" /etc/default/grub
      log "Added $param to GRUB_CMDLINE_LINUX_DEFAULT"
    else
      warn "GRUB_CMDLINE_LINUX_DEFAULT not found in /etc/default/grub. Add $param manually."
      return 0
    fi

    if command -v grub-mkconfig >/dev/null 2>&1; then
      if [[ -d /boot/grub ]]; then
        sudo grub-mkconfig -o /boot/grub/grub.cfg
        log "Regenerated GRUB config: /boot/grub/grub.cfg"
      elif [[ -d /boot/grub2 ]]; then
        sudo grub-mkconfig -o /boot/grub2/grub.cfg
        log "Regenerated GRUB config: /boot/grub2/grub.cfg"
      else
        warn "Could not find /boot/grub or /boot/grub2. Regenerate GRUB manually."
      fi
    else
      warn "grub-mkconfig not found. Regenerate GRUB config manually."
    fi

    return 0
  fi

  warn "Could not detect systemd-boot or GRUB."
  warn "Add '$param' manually to your bootloader kernel parameters."
}
ensure_nvidia_modeset

# -----------------------------
# AUR helper / ProtonUp-Qt
# -----------------------------
if [[ "$INSTALL_AUR" == "1" ]]; then
  if need_cmd yay; then
    log "Installing AUR packages with yay: ${AUR_PKGS[*]}"
    yay -S --needed --noconfirm --batchinstall --cleanafter "${AUR_PKGS[@]}"  
  else
    warn "yay not found. Install yay, then run:"
    warn "  yay -S --needed protonup-qt"
  fi
else
  warn "Skipping AUR installs (INSTALL_AUR=0)."
fi

# -----------------------------
# Post-install checks
# -----------------------------
log "Post-install checks (best-effort)..."

if command -v nvidia-smi >/dev/null 2>&1; then
  if nvidia-smi >/dev/null 2>&1; then
    log "PASS: nvidia-smi works"
  else
    warn "WARN: nvidia-smi exists but failed. Reboot required or driver issue."
  fi
else
  warn "WARN: nvidia-smi not found (nvidia-utils issue)."
fi

if command -v vulkaninfo >/dev/null 2>&1; then
  if vulkaninfo >/dev/null 2>&1; then
    log "PASS: vulkaninfo runs"
  else
    warn "WARN: vulkaninfo failed. Vulkan stack may be incomplete."
  fi
else
  warn "WARN: vulkaninfo not found (vulkan-tools missing)."
fi

if [[ -f /sys/module/nvidia_drm/parameters/modeset ]]; then
  ms="$(cat /sys/module/nvidia_drm/parameters/modeset || true)"
  if [[ "$ms" == "Y" ]]; then
    log "PASS: nvidia_drm modeset is enabled (Y)"
  else
    warn "WARN: nvidia_drm modeset is '$ms' (expected Y). Reboot + verify bootloader arg."
  fi
else
  warn "WARN: /sys/module/nvidia_drm/parameters/modeset not present (driver not loaded yet)."
fi

# -----------------------------
# Final notes
# -----------------------------
warn "REBOOT recommended to load NVIDIA modules + DRM modeset."
warn "After reboot, verify:"
warn "  nvidia-smi"
warn "  cat /sys/module/nvidia_drm/parameters/modeset   # expect: Y"
warn "  vulkaninfo | head -n 40"
warn
warn "Steam launch option examples:"
warn "  gamescope -W 2560 -H 1440 -r 144 -- %command%"
warn "  gamescope -f -r 144 --adaptive-sync -- %command%"
warn
log "All done."
