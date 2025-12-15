# Proxmox LXC Intel GPU Passthrough Kiosk Guide

This guide documents the successful configuration of an unprivileged LXC container acting as a Kiosk (Chromium) displaying on an external monitor via an Intel iGPU.

## 🚀 Quick Automated Installation

## Características Destacadas
*   **Auto-Detección de Hardware de Entrada:** El script de instalación (`detect_inputs.sh`) escanea `/proc/bus/input/devices` y configura automáticamente:
    *   Teclados y Ratones USB (usando identificadores persistentes `by-id` y modo exclusivo `GrabDevice`).
    *   Pantallas Táctiles (con mapeo automático a la pantalla integrada).
    *   Genera un `ServerLayout` explícito para garantizar que Xorg cargue todos los dispositivos.
*   **Video Dual Extendido:** Detecta automáticamente si hay HDMI y DSI conectados, configurando:
    *   HDMI como pantalla Principal (1920x1080).
    *   DSI como pantalla Secundaria Extendida (a la derecha).
*   **Doble Instancia de Kiosko:** Lanza dos ventanas independientes de Chromium, una para cada monitor, con sus propios perfiles de datos para evitar bloqueos.
*   **Aceleración:** Configurado para Intel Graphics (aunque en contenedores sin privilegios puede requerir ajustes finos, funciona por software fallback robusto).

## Instalación Rápida
```bash
./install.sh
```
El script pedirá el ID del contenedor (ej. 202) y la URL del Kiosko.
Todo lo demás (drivers, inputs, display) es automático. **Proxmox Host**:
   ```bash
   git clone https://github.com/gabrielpc1190/proxmox-lxc-kiosk.git
   cd proxmox-lxc-kiosk
   ```
2. Make the script executable and run it:
   ```bash
   chmod +x install.sh
   ./install.sh
   ```
3. Follow the prompts (Container ID, Password, URL). The script will:
   - Create a Debian 12 container.
   - Configure GPU/Input passthrough automatically.
   - Install all dependencies.
   - Setup Host persistence.

---

## Manual Installation Guide
If you prefer to do it step-by-step or debug an existing install, follow below.

## 1. Host Preparation (Proxmox)

### GRUB Configuration
Modify `/etc/default/grub` to release the framebuffer so the host doesn't hog the screen.
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on video=efifb:off"
```
Run `update-grub` and reboot.

### Permissions & Groups
Identify the GIDs for `render`, `video`, `tty`, and `input` on the host.
- `render`: 993
- `video`: 44
- `tty`: 5
- `input`: 997

Ensure `/etc/subgid` allows mapping these groups:
```text
root:44:1
root:5:1
root:993:1
root:997:1
```

## 2. LXC Configuration (`/etc/pve/lxc/CTID.conf`)

This configuration uses ID mapping to pass the specific Host GIDs to the container.

```ini
unprivileged: 1
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.cgroup2.devices.allow: c 4:* rwm

# ID Mappings
lxc.idmap: u 0 100000 65536
lxc.idmap: g 0 100000 5
lxc.idmap: g 5 5 1
lxc.idmap: g 6 100006 38
lxc.idmap: g 44 44 1
lxc.idmap: g 45 100045 56
lxc.idmap: g 101 997 1
lxc.idmap: g 102 100102 2
lxc.idmap: g 104 993 1
lxc.idmap: g 105 100105 65430

# Mounts
lxc.mount.entry: /dev/dri/card1 dev/dri/card1 none bind,optional,create=file
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
lxc.mount.entry: /dev/tty7 dev/tty7 none bind,optional,create=file
lxc.mount.entry: /dev/tty0 dev/tty0 none bind,optional,create=file
```

## 3. Container Setup (Debian/Ubuntu)

### Install Packages
```bash
apt update
apt install -y --no-install-recommends xorg openbox chromium chromium-l10n xserver-xorg-input-libinput xserver-xorg-input-evdev xserver-xorg-video-intel
```

### Persistent Host Permissions (Critical)
To ensure permissions survive a HOST reboot, use a cron job or startup script on the **Proxmox Host**.
1. Edit root cron: `crontab -e`
2. Add:
```bash
@reboot chmod -R 777 /dev/input/ && chmod 666 /dev/dri/card* /dev/dri/render* && chmod 666 /dev/tty7 /dev/tty0
```

### Enable Udev (Critical for Input)
Udev fails by default in LXC because `/sys` is read-only. We must override this check.
```bash
mkdir -p /etc/systemd/system/systemd-udevd.service.d/
echo -e "[Unit]\nConditionPathIsReadWrite=\n" > /etc/systemd/system/systemd-udevd.service.d/override.conf
systemctl daemon-reload
systemctl restart systemd-udevd
```

### Xorg Configuration (`/etc/X11/xorg.conf.d/20-intel.conf`)
Use the legacy `intel` driver for better stability on some iGPUs if `modesetting` fails (grey screen/cursor hang).
```ini
Section "Device"
  Identifier "Intel Graphics"
  Driver "intel"
  Option "TearFree" "true"
EndSection
```

### Static Input Configuration (Crucial for LXC)
Since `udev` is unreliable in containers for input discovery, we must manually configure Xorg to look for the specific event files using the `evdev` driver.
**File: `/etc/X11/xorg.conf.d/10-input.conf`**
```text
Section "ServerFlags"
    Option "AutoAddDevices" "False"
EndSection

Section "InputDevice"
    Identifier "Keyboard0"
    Driver "evdev"
    Option "Device" "/dev/input/event3"  # Identified via ls -l /dev/input/by-id/
    Option "XkbLayout" "us"
EndSection

Section "InputDevice"
    Identifier "Mouse0"
    Driver "evdev"
    Option "Device" "/dev/input/event3" # Logitech K400 uses same event for both
EndSection
```

### Kiosk Script (`/root/.xinitrc`)
Loop to keep Chromium alive and disable screen blanking.
**Important:** Use `dbus-launch` to prevent Chromium crashes.
```bash
#!/bin/bash
xset s off
xset -dpms
xset s noblank

# Start DBus session for Chromium
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval $(dbus-launch --sh-syntax --exit-with-session)
fi

openbox-session &
while true; do
  chromium --kiosk --no-sandbox --test-type --ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy --disable-infobars --window-position=0,0 --window-size=1920,1080 --check-for-update-interval=31536000 https://ha.soporte101.com
  sleep 5
done
```
*Make executable:* `chmod +x /root/.xinitrc`

### Systemd Service (`/etc/systemd/system/kiosk.service`)
Auto-start Xorg on boot on TTY7.
```ini
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
```
*Enable:* `systemctl enable kiosk.service`

## Troubleshooting & Common Errors
### 1. "Fatal server error: no screens found"
- **Cause:** Xorg cannot access the GPU device nodes.
- **Fix:** Run the `chmod 666` command on the **Proxmox Host** (see Persistent Permissions section). Check via `ls -l /dev/dri/card*` inside container.

### 2. "Cannot open /dev/tty0 (Permission denied)"
- **Cause:** Xorg needs TTY access to switch VTs.
- **Fix:** Ensure `/dev/tty0` is included in the Host `chmod` command and `lxc.mount.entry` is present.

### 3. Grey Screen with Mouse Cursor (No Browser)
- **Cause 1:** Chromium crashed immediately. Check logs. Often missing D-Bus.
- **Fix:** Ensure `dbus-launch` is in `.xinitrc`.
- **Cause 2:** TTY permission lost (see error 2).

### 4. Browser Works, but No Keyboard/Mouse
- **Cause:** Xorg defaults to asking `udev` for devices, but `udev` is broken in LXC.
- **Fix:** Create `10-input.conf` with `AutoAddDevices` "False" and manually define inputs using `evdev` driver (see Static Input Configuration).

## 🔄 Migration & Hardware Changes

If you move this container to a new Proxmox host or change hardware, you **must** check two things:

### 1. Input Device IDs (`eventX`)
Linux assigns `/dev/input/eventX` numbers dynamically based on what is plugged in.
- **Symptom:** Keyboard/Mouse stops working after reboot or migration.
- **Fix:**
  1. Check new IDs: `ls -l /dev/input/by-id/`
  2. Update `/etc/X11/xorg.conf.d/10-input.conf` with the new event number (e.g., change `event3` to `event4`).

### 2. Network Interface (`eth0`)
Proxmox might rename the container's network interface config if the host bridge changes.
- **Fix:** Check `/etc/pve/lxc/CTID.conf` and ensure `net0` is using the correct bridge (usually `vmbr0`) and interface type.

### 3. Multiple Monitors / Touchscreens
- **Grey Screen on 2nd Monitor:** Openbox defaults to the primary screen. Use `xrandr` in `.xinitrc` to mirror or extend displays.
- **Touch Not Working:** You must add a new `InputDevice` section in `10-input.conf` for the touchscreen's event ID (find it via `by-id` or `grep` in `/sys/class/input/`).
