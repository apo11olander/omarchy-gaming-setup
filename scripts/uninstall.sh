#!/usr/bin/env bash
set -euo pipefail

log()  { printf "\n\033[1;32m[omarchy-gaming]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[warn]\033[0m %s\n" "$*"; }
die()  { printf "\n\033[1;31m[error]\033[0m %s\n" "$*"; exit 1; }

if [[ ${EUID:-999} -eq 0 ]]; then
  die "Do not run as root. Run as your user; the script will sudo as needed."
fi

REMOVE_PACKAGES="${REMOVE_PACKAGES:-0}" # 1 = remove installed packages (careful)
REMOVE_MODESET_MODPROBE="${REMOVE_MODESET_MODPROBE:-0}" # 1 = remove /etc/modprobe.d/nvidia.conf if created

HYPR_DROPIN="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/conf.d/99-gaming.conf"

log "Removing Hyprland gaming drop-in if present: $HYPR_DROPIN"
rm -f "$HYPR_DROPIN" || true

if [[ "$REMOVE_MODESET_MODPROBE" == "1" ]]; then
  log "Removing /etc/modprobe.d/nvidia.conf (if present)"
  sudo rm -f /etc/modprobe.d/nvidia.conf || true
else
  warn "Leaving /etc/modprobe.d/nvidia.conf in place (REMOVE_MODESET_MODPROBE=0)."
fi

warn "Bootloader note:"
warn "If you want to remove 'nvidia-drm.modeset=1' kernel parameter, do it manually:"
warn " - systemd-boot: edit /boot/loader/entries/*.conf (remove it from the options line)"
warn " - GRUB: edit /etc/default/grub then regenerate grub.cfg"

if [[ "$REMOVE_PACKAGES" == "1" ]]; then
  log "Removing packages (this may remove dependencies you still want)..."
  sudo pacman -Rns --noconfirm \
    steam gamescope mangohud lib32-mangohud gamemode \
    vulkan-tools vulkan-icd-loader lib32-vulkan-icd-loader \
    pipewire pipewire-alsa pipewire-pulse wireplumber steam-devices \
    nvidia-dkms nvidia-utils lib32-nvidia-utils \
    xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-wlr \
    || true
else
  warn "Skipping package removal (REMOVE_PACKAGES=0)."
fi

warn "Reboot recommended."
log "Done."
