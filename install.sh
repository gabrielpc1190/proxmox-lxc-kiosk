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

# 1. Inputs HARDCODED for Automation
CTID=202
PASSWORD="cd970fc1c5"
KIOSK_URL="http://172.16.10.12:8123"
MOBILE_USER_AGENT="Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36"
MOBILE_SCALE_FACTOR="1.3"

# Check if CTID exists (and destroy if it does, since we are recreating)
if pct status $CTID &>/dev/null; then
  echo -e "${CYAN}Container $CTID exists. Destroying it to recreate...${NC}"
  pct stop $CTID || true
  pct destroy $CTID
fi

# Hardcoded template path based on 'pveam list local'
TEMPLATE_PATH="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"

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
pct create $CTID $TEMPLATE_PATH \
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
pct exec $CTID -- bash -c "DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends xorg openbox chromium chromium-l10n xserver-xorg-input-libinput xserver-xorg-input-evdev dbus-x11 xserver-xorg-video-intel xinput"

# 7. Push Config Files (from local files in same dir as script)
echo -e "\n${GREEN}--> Configuring Xorg & Systemd...${NC}"
DIR="$(dirname "$0")"

# Push using 'cat' to avoid depending on local file existence if user runs script standalone
# We recreate the known clean configs here safely

# 10-input.conf (AUTO_DETECTION IMPROVED V4 - Grab + By-ID + Core)
cat <<'EOF' | pct exec $CTID -- tee /usr/local/bin/detect_inputs.sh >/dev/null
#!/bin/bash
OUTPUT="/etc/X11/xorg.conf.d/10-input.conf"
echo 'Section "ServerFlags"' > $OUTPUT
echo '    Option "AutoAddDevices" "False"' >> $OUTPUT
echo 'EndSection' >> $OUTPUT

CORE_KBD_SET=0
CORE_PTR_SET=0
INPUT_DEVS=""

# Helper function to add to list
add_dev() {
    INPUT_DEVS="$INPUT_DEVS $1"
}

CURRENT_NAME=""
while read -r line; do
    if [[ "$line" =~ ^N:\ Name=\"(.*)\" ]]; then
        CURRENT_NAME="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ ^H:\ Handlers=(.*) ]]; then
        HANDLERS="${BASH_REMATCH[1]}"
        if [[ "$CURRENT_NAME" =~ "Button" ]] || [[ "$CURRENT_NAME" =~ "Speaker" ]] || [[ "$CURRENT_NAME" =~ "Bus" ]] || [[ "$CURRENT_NAME" =~ "Intel HID" ]]; then
           continue
        fi
        
        # Regex to capture ONLY number
        if [[ "$HANDLERS" =~ event([0-9]+) ]]; then
            EVENT_NUM="${BASH_REMATCH[1]}"
            EVENT_ID="event${EVENT_NUM}"
            
            # Resolve to by-id alias
            BY_ID_PATH=$(find /dev/input/by-id -lname "*${EVENT_ID}" 2>/dev/null | head -n 1)
            DEVICE_PATH="${BY_ID_PATH:-/dev/input/${EVENT_ID}}"
            IS_TOUCH=0

            # 1. Touchscreen
            if [[ "$CURRENT_NAME" =~ "Touch" ]] || [[ "$CURRENT_NAME" =~ "touch" ]]; then
               ID="Touch_${EVENT_ID}"
               echo "" >> $OUTPUT
               echo "Section \"InputDevice\"" >> $OUTPUT
               echo "    Identifier \"$ID\"" >> $OUTPUT
               echo "    Driver \"evdev\"" >> $OUTPUT
               echo "    Option \"Device\" \"$DEVICE_PATH\"" >> $OUTPUT
               echo "    Option \"GrabDevice\" \"True\"" >> $OUTPUT
               echo "    Option \"SendCoreEvents\" \"True\"" >> $OUTPUT
               echo "EndSection" >> $OUTPUT
               add_dev "$ID"
               IS_TOUCH=1
            fi

            # 2. Keyboard
            if [[ "$HANDLERS" =~ "kbd" ]] && [ $IS_TOUCH -eq 0 ]; then
               ID="Keyboard_${EVENT_ID}"
               echo "" >> $OUTPUT
               echo "Section \"InputDevice\"" >> $OUTPUT
               echo "    Identifier \"$ID\"" >> $OUTPUT
               echo "    Driver \"evdev\"" >> $OUTPUT
               echo "    Option \"Device\" \"$DEVICE_PATH\"" >> $OUTPUT
               echo "    Option \"XkbLayout\" \"us\"" >> $OUTPUT
               echo "    Option \"GrabDevice\" \"True\"" >> $OUTPUT
               if [ $CORE_KBD_SET -eq 0 ]; then
                   echo "    Option \"CoreKeyboard\"" >> $OUTPUT
                   CORE_KBD_SET=1
               else
                   echo "    Option \"SendCoreEvents\" \"True\"" >> $OUTPUT
               fi
               echo "EndSection" >> $OUTPUT
               add_dev "$ID"
            fi

            # 3. Mouse
            if [[ "$HANDLERS" =~ "mouse" ]] && [ $IS_TOUCH -eq 0 ]; then
               ID="Mouse_${EVENT_ID}"
               echo "" >> $OUTPUT
               echo "Section \"InputDevice\"" >> $OUTPUT
               echo "    Identifier \"$ID\"" >> $OUTPUT
               echo "    Driver \"evdev\"" >> $OUTPUT
               echo "    Option \"Device\" \"$DEVICE_PATH\"" >> $OUTPUT
               echo "    Option \"GrabDevice\" \"True\"" >> $OUTPUT
               if [ $CORE_PTR_SET -eq 0 ]; then
                   echo "    Option \"CorePointer\"" >> $OUTPUT
                   CORE_PTR_SET=1
               else
                   echo "    Option \"SendCoreEvents\" \"True\"" >> $OUTPUT
               fi
               echo "EndSection" >> $OUTPUT
               add_dev "$ID"
            fi
        fi
    fi
done < /proc/bus/input/devices

# Generate ServerLayout
echo "" >> $OUTPUT
echo 'Section "Screen"' >> $OUTPUT
echo '    Identifier "Screen0"' >> $OUTPUT
echo '    Device "Intel Graphics"' >> $OUTPUT
echo 'EndSection' >> $OUTPUT
echo "" >> $OUTPUT
echo 'Section "ServerLayout"' >> $OUTPUT
echo '    Identifier "Default Layout"' >> $OUTPUT
echo '    Screen "Screen0"' >> $OUTPUT
for dev in $INPUT_DEVS; do
    echo "    InputDevice \"$dev\"" >> $OUTPUT
done
echo 'EndSection' >> $OUTPUT
EOF
pct exec $CTID -- chmod +x /usr/local/bin/detect_inputs.sh
pct exec $CTID -- /usr/local/bin/detect_inputs.sh

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

# Auto-configure generic dual EXTENDED if HDMI+DSI present
xrandr --output HDMI1 --auto --primary --output DSI1 --auto --right-of HDMI1 2>/dev/null || true

# Fix Touchscreen mapping to DSI1 (Integrated screen)
# Retry up to 10 times because Xinput devices might take a moment to appear
for i in {1..10}; do
    TOUCH_DEV=\$(xinput list --name-only 2>/dev/null | grep "Touch_" | head -n 1)
    if [ ! -z "\$TOUCH_DEV" ]; then
        if xinput map-to-output "\$TOUCH_DEV" DSI1 2>/dev/null; then
            echo "Mapped \$TOUCH_DEV to DSI1" >> /tmp/xinitrc_log
            break
        fi
    fi
    sleep 1
done

# Start DBus session
if [ -z "\$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval \$(dbus-launch --sh-syntax --exit-with-session)
fi

openbox-session &

# Clean legacy locks
rm -rf /root/.config/chromium/Singleton*
rm -rf /root/.config/chromium-dsi/Singleton*

while true; do
  # Instance 1: HDMI (Primary 1920x1080)
  chromium --kiosk --no-sandbox --test-type --ignore-gpu-blocklist \
    --enable-gpu-rasterization --enable-zero-copy --disable-infobars \
    --window-position=0,0 --window-size=1920,1080 \
    --check-for-update-interval=31536000 \
    --user-data-dir=/root/.config/chromium \
    $KIOSK_URL &
  
  # Instance 2: DSI (Secondary 800x1280, Offset +1920)
  # Uses separate user data dir to allow simultaneous run
  sleep 1
  chromium --kiosk --no-sandbox --test-type --ignore-gpu-blocklist \
    --enable-gpu-rasterization --enable-zero-copy --disable-infobars \
    --window-position=1920,0 --window-size=800,1280 \
    --check-for-update-interval=31536000 \
    --user-data-dir=/root/.config/chromium-dsi \
    --user-agent="$MOBILE_USER_AGENT" \
    --force-device-scale-factor="$MOBILE_SCALE_FACTOR" \
    $KIOSK_URL &
    
  wait
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
