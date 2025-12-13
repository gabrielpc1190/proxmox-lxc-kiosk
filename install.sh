#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}=== Proxmox LXC Kiosk Installer ===${NC}"
echo "This script will create a new unprivileged LXC container configured for Intel GPU Passthrough and Kiosk mode."
echo ""

# 1. Inputs
read -p "Enter Container ID (e.g., 203): " CTID
read -s -p "Enter Root Password: " PASSWORD
echo ""
read -p "Enter Kiosk URL (default: https://ha.soporte101.com): " KIOSK_URL
KIOSK_URL=${KIOSK_URL:-"https://ha.soporte101.com"}

# Check if CTID exists
if pct status $CTID &>/dev/null; then
  echo -e "${RED}Error: Container $CTID already exists.${NC}"
  exit 1
fi

# 2. Detect Host GIDs
echo -e "\n${GREEN}--> Detecting Host GIDs...${NC}"
GID_RENDER=$(getent group render | cut -d: -f3)
GID_VIDEO=$(getent group video | cut -d: -f3)
GID_TTY=$(getent group tty | cut -d: -f3)
GID_INPUT=$(getent group input | cut -d: -f3)

echo "Render: $GID_RENDER | Video: $GID_VIDEO | Tty: $GID_TTY | Input: $GID_INPUT"

if [ -z "$GID_RENDER" ] || [ -z "$GID_INPUT" ]; then
    echo -e "${RED}Error: Could not detect critical GIDs (render/input). Check /etc/group.${NC}"
    exit 1
fi

# 3. Create Container
echo -e "\n${GREEN}--> Creating Container $CTID (Debian 12)...${NC}"
# Note: Assuming debian-12-standard template is available. Adjust storage 'local-lvm' if needed.
pct create $CTID local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
    --rootfs local-lvm:8 \
    --hostname kiosk-$CTID \
    --cores 2 --memory 2048 --swap 512 \
    --net0 name=eth0,bridge=vmbr0,ip=dhcp,firewall=1 \
    --unprivileged 1 \
    --features nesting=1 \
    --password "$PASSWORD"

# 4. Configure LXC Passthrough (The Magic)
echo -e "\n${GREEN}--> Applying Host Configuration (ID Maps & Mounts)...${NC}"

CONF_FILE="/etc/pve/lxc/${CTID}.conf"
cp $CONF_FILE "${CONF_FILE}.bak"

# Append config
cat <<EOF >> $CONF_FILE

# --- KIOSK PASSTHROUGH CONFIG ---
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.cgroup2.devices.allow: c 4:* rwm

# ID Mappings
lxc.idmap: u 0 100000 65536
lxc.idmap: g 0 100000 $GID_TTY
lxc.idmap: g $GID_TTY $GID_TTY 1
lxc.idmap: g $((GID_TTY+1)) $((100000+GID_TTY+1)) $((GID_VIDEO-GID_TTY-1))
lxc.idmap: g $GID_VIDEO $GID_VIDEO 1
lxc.idmap: g $((GID_VIDEO+1)) $((100000+GID_VIDEO+1)) $((GID_RENDER-GID_VIDEO-1))
lxc.idmap: g $GID_RENDER $GID_RENDER 1
lxc.idmap: g $((GID_RENDER+1)) $((100000+GID_RENDER+1)) $((GID_INPUT-GID_RENDER-1))
lxc.idmap: g $GID_INPUT $GID_INPUT 1
lxc.idmap: g $((GID_INPUT+1)) $((100000+GID_INPUT+1)) $((65536-GID_INPUT-1))

# Mounts
lxc.mount.entry: /dev/dri/card1 dev/dri/card1 none bind,optional,create=file
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
lxc.mount.entry: /dev/tty7 dev/tty7 none bind,optional,create=file
lxc.mount.entry: /dev/tty0 dev/tty0 none bind,optional,create=file
EOF

# Ensure subgid allows these mappings
if ! grep -q "root:$GID_RENDER:1" /etc/subgid; then
    echo "root:$GID_RENDER:1" >> /etc/subgid
    echo "root:$GID_VIDEO:1" >> /etc/subgid
    echo "root:$GID_TTY:1" >> /etc/subgid
    echo "root:$GID_INPUT:1" >> /etc/subgid
fi

# 5. Start Container
echo -e "\n${GREEN}--> Starting Container...${NC}"
pct start $CTID
echo "Waiting for boot..."
sleep 10

# 6. Install Dependencies
echo -e "\n${GREEN}--> Installing Kiosk Packages (this may take a while)...${NC}"
pct exec $CTID -- apt update
pct exec $CTID -- apt install -y --no-install-recommends xorg openbox chromium chromium-l10n xserver-xorg-input-libinput xserver-xorg-input-evdev dbus-x11

# 7. Push Config Files (from local files in same dir as script)
echo -e "\n${GREEN}--> Configuring Xorg & Systemd...${NC}"
DIR="$(dirname "$0")"

# Push using 'cat' to avoid depending on local file existence if user runs script standalone
# We recreate the known clean configs here safely

# 10-input.conf
cat <<EOF | pct exec $CTID -- tee /etc/X11/xorg.conf.d/10-input.conf >/dev/null
Section "ServerFlags"
    Option "AutoAddDevices" "False"
EndSection

Section "InputDevice"
    Identifier "Keyboard0"
    Driver "evdev"
    Option "Device" "/dev/input/event3"
    Option "XkbLayout" "us"
EndSection

Section "InputDevice"
    Identifier "Mouse0"
    Driver "evdev"
    Option "Device" "/dev/input/event3"
EndSection
EOF

# 20-intel.conf
cat <<EOF | pct exec $CTID -- tee /etc/X11/xorg.conf.d/20-intel.conf >/dev/null
Section "Device"
  Identifier "Intel Graphics"
  Driver "intel"
  Option "TearFree" "true"
EndSection
EOF

# .xinitrc (Injecting URL)
cat <<EOF | pct exec $CTID -- tee /root/.xinitrc >/dev/null
#!/bin/bash
xset s off
xset -dpms
xset s noblank

if [ -z "\$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval \$(dbus-launch --sh-syntax --exit-with-session)
fi

openbox-session &
while true; do
  chromium --kiosk --no-sandbox --test-type --ignore-gpu-blocklist \
    --enable-gpu-rasterization --enable-zero-copy --disable-infobars \
    --window-position=0,0 --window-size=1920,1080 \
    --check-for-update-interval=31536000 \
    $KIOSK_URL
  sleep 5
done
EOF
pct exec $CTID -- chmod +x /root/.xinitrc

# kiosk.service
cat <<EOF | pct exec $CTID -- tee /etc/systemd/system/kiosk.service >/dev/null
[Unit]
Description=Kiosk Xorg Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/startx /root/.xinitrc -- -sharevts vt7
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 8. Enable Services
pct exec $CTID -- systemctl enable kiosk.service

# 9. Host Persistence
echo -e "\n${GREEN}--> Setting up Host Persistence (Cron)...${NC}"
CRON_JOB="@reboot chmod -R 777 /dev/input/ && chmod 666 /dev/dri/card* /dev/dri/render* && chmod 666 /dev/tty7 /dev/tty0"
(crontab -l 2>/dev/null | grep -F "$CRON_JOB") || (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo -e "\n${GREEN}=== Installation Complete! ===${NC}"
echo "Container $CTID is ready. Rebooting container to finalize..."
pct stop $CTID && pct start $CTID
echo "Done. Kiosk should appear on the external monitor."
