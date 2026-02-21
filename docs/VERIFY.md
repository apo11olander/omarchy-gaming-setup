# Verify Omarchy Gaming Setup

Reboot after install.

1) NVIDIA driver works:
   nvidia-smi

2) DRM modeset enabled (Wayland stability):
   cat /sys/module/nvidia_drm/parameters/modeset
   Expected output: Y

3) Vulkan works:
   vulkaninfo | head -n 40

4) Steam Play / Proton:
   - Open Steam
   - Settings → Compatibility
   - Enable Steam Play for all titles
   - Install Proton-GE via ProtonUp-Qt (optional but recommended)

5) Gamescope smoke test (Steam launch options examples):
   gamescope -f -- %command%
   gamescope -f --adaptive-sync -- %command%
