#!/usr/bin/env bash
# ============================================================================
#  TARDIS BOOTSTRAPPER — sway + waybar + foot + friends on Debian/Ubuntu
# ============================================================================
set -euo pipefail

# 1 — Paths
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
LOG="$HOME/.dotfiles-install.log"
exec > >(tee -a "$LOG") 2>&1

log()  { printf '  -> %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }

# 2 — Keyboard layout
XKB_LAYOUT="${XKBLAYOUT:-}"
XKB_VARIANT="${XKBVARIANT:-}"
if [ -z "$XKB_LAYOUT" ] && [ -r /etc/default/keyboard ]; then
  # shellcheck disable=SC1091
  . /etc/default/keyboard
  XKB_LAYOUT="${XKBLAYOUT:-us}"
  XKB_VARIANT="${XKBVARIANT:-}"
fi
XKB_LAYOUT="${XKB_LAYOUT:-us}"
XKB_VARIANT="${XKB_VARIANT:-}"
log "keyboard: layout=$XKB_LAYOUT variant=${XKB_VARIANT:-<none>}"

# 3 — Packages
PKGS=(
  # --- Wayland session support (XFCE Debian specifics) ---
  "xwayland"          # CRITICAL: without it, no X11 apps run in sway
  "qtwayland5"        # Qt apps native Wayland instead of slow XWayland
  "wayland-utils"     # wayland-info — tiny, useful debugging

  "sway" "swaybg" "swayidle" "swaylock" "kanshi"
  "xdg-desktop-portal-wlr" "xdg-desktop-portal-gtk"

  "waybar" "fuzzel" "mako-notifier" "foot"

  "grim" "slurp" "wl-clipboard" "wf-recorder" "cliphist"
  "gammastep"

  "bluez" "bluez-tools" "blueman"

   "wdisplays" "wlr-randr"

  "network-manager" "network-manager-gnome"

  "pipewire" "wireplumber" "pipewire-pulse|pulseaudio"
  "pavucontrol" "playerctl"

  "power-profiles-daemon" "brightnessctl" "wlogout"
  "lxpolkit|mate-polkit|policykit-1-gnome"

  "gnome-keyring" "udiskie" "nnn|yazi" "thunar"

  "fonts-font-awesome|fonts-font-awesome-4"
  "fonts-jetbrains-mono|fonts-jetbrains-mono-nerd"
  "fonts-noto-color-emoji"

  "libnotify-bin"
  "jq" "curl" "unzip" "python3" "micro|nano" "btop|htop" "qalc" "ncdu"
)

pkg_available() { apt-cache show --no-all-versions "$1" >/dev/null 2>&1; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

resolve_pkg() {
  local spec=$1 name alts alt
  name=${spec%%|*}
  alts=${spec#*|}
  if pkg_available "$name"; then printf '%s\n' "$name"; return 0; fi
  [ "$alts" = "$spec" ] && return 1
  [ -z "$alts" ] && return 1
  IFS=',' read -ra parts <<<"$alts"
  for alt in "${parts[@]}"; do
    if pkg_available "$alt"; then printf '%s\n' "$alt"; return 0; fi
  done
  return 1
}

RESOLVED=(); FAILED=()
for spec in "${PKGS[@]}"; do
  if chosen=$(resolve_pkg "$spec"); then
    RESOLVED+=("$chosen"); log "package: $spec -> $chosen"
  else
    FAILED+=("$spec"); warn "no candidate: $spec"
  fi
done
[ "${#FAILED[@]}" -gt 0 ] && { warn "unresolvable: ${FAILED[*]}"; exit 1; }

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${RESOLVED[@]}"

# Power profiles daemon
if command -v powerprofilesctl >/dev/null 2>&1; then
  sudo systemctl enable --now power-profiles-daemon >/dev/null 2>&1 || true
  sleep 0.5
  if systemctl is-active --quiet power-profiles-daemon; then
    log "power-profiles-daemon active ($(powerprofilesctl get 2>/dev/null || echo unknown))"
  else
    warn "power-profiles-daemon installed but not active; ppd button may do nothing"
  fi
fi

# --- backlight permissions ---------------------------------------------------
# brightnessctl needs write access to /sys/class/backlight/*. Two mechanisms:
#   (a) 'video' group membership (traditional)
#   (b) logind/polkit session (works on modern Debian/Ubuntu without group)
# We add the group anyway — it costs nothing and fixes older setups.
if [ -d /sys/class/backlight ] && [ -z "$(ls -A /sys/class/backlight 2>/dev/null)" ]; then
  warn "No /sys/class/backlight devices found — brightness keys won't do anything on this hardware."
fi
if ! id -nG "$USER" 2>/dev/null | grep -qw video; then
  sudo usermod -aG video "$USER" 2>/dev/null && \
    warn "Added $USER to 'video' group — brightness needs re-login (or reboot) to take effect."
fi

MISSING=()
for p in "${RESOLVED[@]}"; do pkg_installed "$p" || MISSING+=("$p"); done
[ "${#MISSING[@]}" -gt 0 ] && { warn "missing after install: ${MISSING[*]}"; exit 1; }
log "all ${#RESOLVED[@]} packages installed and verified."

# 4 — Config directories
log "creating config dirs under $CONFIG"
mkdir -p -- \
  "$CONFIG/sway" "$CONFIG/sway/scripts" "$CONFIG/sway/config.d" \
  "$CONFIG/waybar" "$CONFIG/mako" "$CONFIG/foot" "$CONFIG/fuzzel" \
  "$CONFIG/wlogout" "$CONFIG/gammastep" "$CONFIG/kanshi" "$CONFIG/swaylock"
mkdir -p -- "$HOME/Pictures" "$HOME/Videos" "$DATA/wallpapers"

# 5 — Wallpaper
WALLPAPER="$DATA/wallpapers/tardis.png"
generate_wallpaper() {
  python3 - "$WALLPAPER" <<'PY'
import sys, zlib, struct
W, H = 1920, 1080
out = sys.argv[1]
BG   = (0x00, 0x3b, 0x6f)
INK  = (0x0a, 0x16, 0x28)
RING = [(0x1a, 0x5f, 0xa8), (0x4a, 0x90, 0xc2), (0x7f, 0xb3, 0xd5)]
cx, cy = W // 2, H // 2
radii = [H * 0.28, H * 0.22, H * 0.16]
def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
rows = bytearray()
for y in range(H):
    rows.append(0)
    dy = y - cy
    for x in range(W):
        dx = x - cx
        d = (dx * dx + dy * dy) ** 0.5
        px = lerp(BG, INK, y / H)
        for i, r in enumerate(radii):
            if d < r: px = RING[i]; break
        rows.extend(px)
def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))
png  = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
png += chunk(b"IEND", b"")
open(out, "wb").write(png)
PY
}
log "generating wallpaper"
if ! generate_wallpaper; then
  warn "wallpaper generation failed; using solid background"
  WALLPAPER=""
elif [ -f "$WALLPAPER" ]; then
  log "wallpaper: $WALLPAPER"
fi

# 6 — Polkit agent detection
POLKIT_BIN=""
for p in \
  /usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1 \
  /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 \
  /usr/lib/lxpolkit/lxpolkit \
  /usr/bin/lxpolkit ; do
  [ -x "$p" ] && { POLKIT_BIN="$p"; break; }
done
if [ -n "$POLKIT_BIN" ]; then log "polkit: $POLKIT_BIN"
else warn "no polkit agent found; GUI password prompts may fail"; fi

# 7 — Sway config
log "writing sway config"
install -Dm644 -- /dev/stdin "$CONFIG/sway/config" <<'SWAYCONF'
# sway config — Tardis blue theme; installer-generated

set $mod Mod4
set $term foot
set $menu fuzzel

set $blue_deep    #003b6f
set $blue_panel   #1a5fa8
set $blue_glass   #4a90c2
set $blue_light   #7fb3d5
set $silver       #c0c0c0
set $ink          #0a1628

# mouse on floating windows: Mod+left-drag = move, Mod+right-drag = resize.
# tiled windows must be floated first (Mod+Shift+Space).
floating_modifier $mod

client.focused          $blue_panel $blue_panel $silver $blue_glass $blue_panel
client.focused_inactive $blue_deep  $blue_deep  $blue_light $blue_glass $blue_deep
client.unfocused        $ink        $ink        $silver    $ink        $ink
client.urgent           $blue_glass $blue_glass $ink       $blue_light $blue_glass

default_border pixel 2
default_floating_border pixel 2
hide_edge_borders smart
gaps inner 6
gaps outer 10
smart_gaps on

font pango:JetBrains Mono 10

# wallpaper: solid underneath, image on top
output * bg $blue_deep solid_color
output * bg @WALLPAPER@ fill

input "type:keyboard" {
    xkb_layout @XKB_LAYOUT@
}

input "type:touchpad" {
    tap enabled
    tap_button_map lrm
    natural_scroll enabled
    dwt enabled
    middle_emulation enabled
    scroll_method two_finger
    click_method button_areas
}

input "type:pointer" {
    accel_profile flat
}

# --- floating rules ---------------------------------------------------------
for_window [app_id="foot-nmtui"] floating enable, resize set 900 600, move position center, border none
for_window [app_id="foot-popup"] floating enable, resize set 700 520, move position center
for_window [app_id="pavucontrol"]          floating enable, resize set 900 650, move position center
for_window [app_id="blueman-manager"]      floating enable, resize set 800 600, move position center
for_window [app_id="nm-connection-editor"] floating enable, resize set 900 650, move position center

# --- media keys -------------------------------------------------------------
bindsym XF86AudioRaiseVolume exec --no-startup-id \
    sh -c 'wpctl set-mute @DEFAULT_AUDIO_SINK@ 0; wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+'
bindsym XF86AudioLowerVolume exec --no-startup-id \
    wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindsym XF86AudioMute     exec --no-startup-id wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
bindsym XF86AudioMicMute  exec --no-startup-id wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle

# brightness — go through bright.sh so you get a toast confirmation
bindsym XF86MonBrightnessUp   exec --no-startup-id @CONFIG@/sway/scripts/bright.sh up
bindsym XF86MonBrightnessDown exec --no-startup-id @CONFIG@/sway/scripts/bright.sh down

bindsym XF86AudioPlay  exec --no-startup-id playerctl play-pause
bindsym XF86AudioPause exec --no-startup-id playerctl play-pause
bindsym XF86AudioNext  exec --no-startup-id playerctl next
bindsym XF86AudioPrev  exec --no-startup-id playerctl previous
bindsym XF86AudioStop  exec --no-startup-id playerctl stop

# --- core -------------------------------------------------------------------
bindsym $mod+Return  exec $term
bindsym $mod+d       exec $menu
bindsym $mod+Shift+q kill
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec @CONFIG@/sway/scripts/menu.sh
bindsym $mod+Shift+f exec --no-startup-id thunar

# focus
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Left  focus left
bindsym $mod+Down  focus down
bindsym $mod+Up    focus up
bindsym $mod+Right focus right

# move
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+Shift+Left  move left
bindsym $mod+Shift+Down  move down
bindsym $mod+Shift+Up    move up
bindsym $mod+Shift+Right move right

# layout
bindsym $mod+b splith
bindsym $mod+v splitv
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split
bindsym $mod+f fullscreen
bindsym $mod+Shift+space floating toggle
bindsym $mod+space focus mode_toggle

# resize mode
mode "resize" {
    bindsym h resize shrink width 10 px or 10 ppt
    bindsym j resize grow height 10 px or 10 ppt
    bindsym k resize shrink height 10 px or 10 ppt
    bindsym l resize grow width 10 px or 10 ppt
    bindsym Left  resize shrink width 10 px or 10 ppt
    bindsym Down  resize grow height 10 px or 10 ppt
    bindsym Up    resize shrink height 10 px or 10 ppt
    bindsym Right resize grow width 10 px or 10 ppt
    bindsym Return mode "default"
    bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

# workspaces 1–9
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+5 workspace number 5
bindsym $mod+6 workspace number 6
bindsym $mod+7 workspace number 7
bindsym $mod+8 workspace number 8
bindsym $mod+9 workspace number 9

bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4
bindsym $mod+Shift+5 move container to workspace number 5
bindsym $mod+Shift+6 move container to workspace number 6
bindsym $mod+Shift+7 move container to workspace number 7
bindsym $mod+Shift+8 move container to workspace number 8
bindsym $mod+Shift+9 move container to workspace number 9

# --- screenshots / recording / clipboard ------------------------------------
bindsym Print exec --no-startup-id grim -g "$(slurp)" - | wl-copy
bindsym $mod+Print exec --no-startup-id grim - | wl-copy
bindsym $mod+Shift+Print exec --no-startup-id \
    sh -c 'grim -g "$(slurp)" ~/Pictures/shot-$(date +%Y%m%d-%H%M%S).png'
bindsym $mod+Ctrl+Print exec --no-startup-id \
    sh -c 'pgrep -x wf-recorder >/dev/null && pkill -INT wf-recorder || wf-recorder -f ~/Videos/rec-$(date +%Y%m%d-%H%M%S).mp4'
bindsym $mod+Shift+v exec --no-startup-id \
    sh -c 'cliphist list | fuzzel --dmenu | cliphist decode | wl-copy'

# --- system toggles ---------------------------------------------------------
bindsym $mod+Shift+n exec --no-startup-id makoctl dismiss
bindsym $mod+n       exec --no-startup-id makoctl dismiss -a
bindsym $mod+Shift+g exec --no-startup-id \
    sh -c 'pgrep -x gammastep >/dev/null && pkill gammastep || gammastep -O 4000'

# nmtui
bindsym $mod+Shift+w exec --no-startup-id @CONFIG@/sway/scripts/nmtui.sh

# lock + help
bindsym $mod+Shift+x  exec --no-startup-id swaylock -f -c 003b6f
bindsym $mod+Shift+F1 exec --no-startup-id $term -e less @CONFIG@/sway/help.md

# --- autostart --------------------------------------------------------------
exec --no-startup-id dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec --no-startup-id systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec --no-startup-id waybar
exec --no-startup-id mako
exec --no-startup-id wl-paste --type text  --watch cliphist store
exec --no-startup-id wl-paste --type image --watch cliphist store
exec --no-startup-id gnome-keyring-daemon --start --components=secrets
exec --no-startup-id @POLKIT@
exec --no-startup-id udiskie --tray
exec --no-startup-id blueman-applet
exec --no-startup-id nm-applet --indicator
exec --no-startup-id swayidle -w \
    timeout 300 'swaylock -f -c 003b6f' \
    timeout 600 'swaymsg "output * dpms off"' \
    resume      'swaymsg "output * dpms on"' \
    before-sleep 'swaylock -f -c 003b6f'
exec --no-startup-id kanshi

include @CONFIG@/sway/config.d/*
SWAYCONF

# 8 — Substitute placeholders in sway config
log "substituting sway placeholders"
if [ -n "$WALLPAPER" ]; then
  sed -i "s|@WALLPAPER@|$WALLPAPER|g" "$CONFIG/sway/config"
else
  sed -i "/^output \* bg @WALLPAPER@ fill$/d" "$CONFIG/sway/config"
fi
sed -i "s|@XKB_LAYOUT@|$XKB_LAYOUT|g"      "$CONFIG/sway/config"
sed -i "s|@CONFIG@|$CONFIG|g"               "$CONFIG/sway/config"
if [ -n "$POLKIT_BIN" ]; then
  sed -i "s|@POLKIT@|$POLKIT_BIN|g" "$CONFIG/sway/config"
else
  sed -i "/^exec --no-startup-id @POLKIT@$/d" "$CONFIG/sway/config"
fi

# 9 — Helper scripts
SCRIPTS="$CONFIG/sway/scripts"

install -Dm755 -- /dev/stdin "$SCRIPTS/bluetooth-status" <<'BT'
#!/usr/bin/env bash
set -euo pipefail
if ! command -v bluetoothctl >/dev/null 2>&1; then
  echo '{"text":"bt","tooltip":"bluetoothctl missing","class":"off"}'; exit 0
fi
if ! bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'; then
  echo '{"text":"bt","tooltip":"Bluetooth off","class":"off"}'; exit 0
fi
n=$(bluetoothctl devices Connected 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" -gt 0 ]; then
  printf '{"text":"bt:%s","tooltip":"%s device(s) connected","class":"on"}\n' "$n" "$n"
else
  echo '{"text":"bt","tooltip":"Bluetooth on, nothing connected","class":"idle"}'
fi
BT

install -Dm755 -- /dev/stdin "$SCRIPTS/notif-toggle" <<'DND'
#!/usr/bin/env bash
set -euo pipefail
command -v makoctl >/dev/null 2>&1 || exit 0
if makoctl mode 2>/dev/null | grep -qx 'do-not-disturb'; then
  makoctl mode -s default
else
  makoctl mode -s do-not-disturb
fi
DND

install -Dm755 -- /dev/stdin "$SCRIPTS/notif-status" <<'DNDS'
#!/usr/bin/env bash
set -euo pipefail
if command -v makoctl >/dev/null 2>&1 \
   && makoctl mode 2>/dev/null | grep -qx 'do-not-disturb'; then
  echo '{"text":"dnd off","tooltip":"Notifications: OFF (DND)","class":"off"}'
else
  echo '{"text":"dnd on","tooltip":"Notifications: ON","class":"on"}'
fi
DNDS

install -Dm755 -- /dev/stdin "$SCRIPTS/ppd-cycle" <<'PPD'
#!/usr/bin/env bash
set -euo pipefail
command -v powerprofilesctl >/dev/null 2>&1 || exit 0
if ! powerprofilesctl get >/dev/null 2>&1; then
  notify-send -t 2500 "Power" "power-profiles-daemon not running (sudo systemctl start power-profiles-daemon)" 2>/dev/null || true
  exit 0
fi
cur=$(powerprofilesctl get 2>/dev/null || echo "")
case "$cur" in
  performance) next=balanced ;;
  balanced)    next=power-saver ;;
  power-saver) next=performance ;;
  *)           next=balanced ;;
esac
if powerprofilesctl set "$next" 2>/dev/null; then
  notify-send -h string:x-canonical-private-synchronous:ppd -t 1200 "Power" "$next" 2>/dev/null || true
fi
PPD

# brightness with toast feedback — used by BOTH the hardware keys and the bar
install -Dm755 -- /dev/stdin "$SCRIPTS/bright.sh" <<'BRIGHT'
#!/bin/sh
case "$1" in
  up)   brightnessctl set 5%+ >/dev/null 2>&1 ;;
  down) brightnessctl set 5%- >/dev/null 2>&1 ;;
  *)    exit 0 ;;
esac
pct=$(brightnessctl -m 2>/dev/null | awk -F, '{gsub(/%/,"",$4); print $4}')
if [ -z "$pct" ]; then
  notify-send -t 2000 "Brightness" "brightnessctl failed (are you in the 'video' group?)" 2>/dev/null || true
else
  notify-send -h string:x-canonical-private-synchronous:bright -t 1200 \
    "Brightness" "${pct}%" 2>/dev/null || true
fi
BRIGHT

install -Dm755 -- /dev/stdin "$SCRIPTS/nmtui.sh" <<'NMTUI'
#!/bin/sh
exec foot --app-id=foot-nmtui -e sh -c 'sleep 0.5; exec nmtui'
NMTUI

# 9d — foot.ini (Tardis theme, accessible defaults)
install -Dm644 -- /dev/stdin "$CONFIG/foot/foot.ini" <<'FOOTINI'
[main]
font=JetBrains Mono:size=9
font-bold=JetBrains Mono:style=Bold
font-bold-italic=JetBrains Mono:style=Bold Italic
font-italic=JetBrains Mono:style=Italic
pad=12x12
dpi-aware=yes
initial-window-size-pixels=1200x720
initial-window-size-chars=80x24

[scrollback]
lines=10000

[cursor]
color=0a1428 4a90c2
style=beam
blink=yes

[colors]
background=0a1428
foreground=cdd6f4
regular0=0a1428
regular1=f38ba8
regular2=a6e3a1
regular3=f9e2af
regular4=7fb3d5
regular5=c7a7ff
regular6=94e2d5
regular7=bac2de
bright0=2a3a5a
bright1=f38ba8
bright2=a6e3a1
bright3=f9e2af
bright4=4a90c2
bright5=c7a7ff
bright6=94e2d5
bright7=a6adc8
selection-foreground=0a1428
selection-background=4a90c2
urls=7fb3d5

[csd]
preferred=server
FOOTINI

# foot validates its own config — catch a typo now, not at first launch
if ! foot --check-config 2>&1 | grep -q .; then
  log "foot.ini written and valid"
else
  warn "foot --check-config reported problems:"
  foot --check-config 2>&1 | sed 's/^/    /' >&2 || true
fi

install -Dm755 -- /dev/stdin "$SCRIPTS/shot.sh" <<'SHOT'
#!/bin/sh
choice=$(printf 'Region to clipboard\nFull screen to clipboard\nRegion to file' \
  | fuzzel --dmenu --prompt 'Screenshot')
[ -z "$choice" ] && exit 0
mkdir -p "$HOME/Pictures"
out="$HOME/Pictures/shot-$(date +%Y%m%d-%H%M%S).png"
case "$choice" in
  "Region to clipboard")      grim -g "$(slurp)" - | wl-copy ;;
  "Full screen to clipboard") grim - | wl-copy ;;
  "Region to file")           grim -g "$(slurp)" "$out" \
                              && notify-send -t 2000 "Screenshot" "$out" ;;
esac
SHOT

install -Dm755 -- /dev/stdin "$SCRIPTS/rec.sh" <<'REC'
#!/bin/sh
if pgrep -x wf-recorder >/dev/null; then
  pkill -INT wf-recorder
  notify-send -t 1500 "Recording" "Stopped"
  exit 0
fi
choice=$(printf 'Full screen\nRegion' | fuzzel --dmenu --prompt 'Record')
[ -z "$choice" ] && exit 0
mkdir -p "$HOME/Videos"
out="$HOME/Videos/rec-$(date +%Y%m%d-%H%M%S).mp4"
case "$choice" in
  Region) wf-recorder -g "$(slurp)" -f "$out" >/dev/null 2>&1 & ;;
  *)      wf-recorder -f "$out" >/dev/null 2>&1 & ;;
esac
disown 2>/dev/null || true
notify-send -t 2000 "Recording" "$out"
REC

# session menu — fuzzel-based, always renders (unlike wlogout on some setups)
install -Dm755 -- /dev/stdin "$SCRIPTS/menu.sh" <<'MENU'
#!/bin/sh
choice=$(printf 'Lock screen\nLog out\nSuspend\nReboot\nShut down\n— wlogout (big buttons)' \
  | fuzzel --dmenu --prompt 'Session')
[ -z "$choice" ] && exit 0
case "$choice" in
  "Lock screen")  swaylock -f -c 003b6f ;;
  "Log out")      swaymsg exit ;;
  "Suspend")      systemctl suspend ;;
  "Reboot")       systemctl reboot ;;
  "Shut down")    systemctl poweroff ;;
  "— wlogout"*)   command -v wlogout >/dev/null 2>&1 && wlogout \
                    || notify-send -t 2500 "wlogout not installed" ;;
esac
MENU

# 10 — Waybar config + style
WAYBAR="$CONFIG/waybar"

install -Dm644 -- /dev/stdin "$WAYBAR/config" <<'WAYBARCONF'
{
  "layer": "top",
  "position": "top",
  "height": 34,
  "spacing": 6,
  "margin-top": 0,
  "margin-left": 8,
  "margin-right": 8,

  "modules-left":   ["sway/workspaces", "sway/mode"],
  "modules-center": ["clock"],
  "modules-right":  [
    "custom/apps",
    "custom/shot",
    "custom/displays",
    "custom/rec",
    "network",
    "pulseaudio",
    "custom/bluetooth",
    "power-profiles-daemon",
    "backlight",
    "battery",
    "custom/dnd",
    "custom/help",
    "custom/power",
    "tray"
  ],

  "sway/workspaces": {
    "disable-scroll": false,
    "all-outputs": true,
    "format": "{name}",
    "format-icons": {
      "1": "1", "2": "2", "3": "3", "4": "4", "5": "5",
      "6": "6", "7": "7", "8": "8", "9": "9",
      "urgent": "!", "default": ""
    }
  },

  "sway/mode": { "format": "  [{}]", "tooltip": false },

  "clock": {
    "format": "{:%H:%M}",
    "format-alt": "{:%a %d %b  %H:%M}",
    "tooltip-format": "<tt>{calendar}</tt>",
    "calendar": {
      "mode": "month",
      "mode-mon-col": 3,
      "weeks-pos": "right",
      "on-scroll": 1,
      "format": {
        "months":   "<span color='#7fb3d5'><b>{}</b></span>",
        "days":     "<span color='#c0c0c0'>{}</span>",
        "weekdays": "<span color='#4a90c2'><b>{}</b></span>",
        "today":    "<span color='#1a5fa8'><b><u>{}</u></b></span>"
      }
    },
    "actions": {
      "on-click-right": "mode",
      "on-scroll-up":   "shift_up",
      "on-scroll-down": "shift_down"
    }
  },

  "custom/apps": {
    "format": "apps",
    "tooltip": "Apps (fuzzel)",
    "on-click": "fuzzel"
  },

  "custom/shot": {
    "format": "shot",
    "tooltip": "Screenshot (region / full / file)",
    "on-click": "@CONFIG@/sway/scripts/shot.sh"
  },

  "custom/displays": {
    "format": "disp",
    "tooltip": "Manage displays (TV, projector, mirror)",
    "on-click": "wdisplays"
  },

  "custom/rec": {
    "format": "rec",
    "tooltip": "Screen recording (click to start / stop)",
    "exec": "pgrep -x wf-recorder >/dev/null && echo '{\"class\":\"active\"}' || echo '{\"class\":\"inactive\"}'",
    "interval": 2,
    "on-click": "@CONFIG@/sway/scripts/rec.sh"
  },

  "network": {
    "format-wifi":         "wifi {essid} ({signalStrength}%)",
    "format-ethernet":     "eth {ifname}",
    "format-linked":       "net {ifname} (no IP)",
    "format-disconnected": "net offline",
    "tooltip-format-wifi":         "{essid}\n{ipaddr}/{cidr}\n{signalStrength}%",
    "tooltip-format-ethernet":     "{ifname}\n{ipaddr}/{cidr}",
    "tooltip-format-disconnected": "Disconnected",
    "on-click":       "@CONFIG@/sway/scripts/nmtui.sh",
    "on-click-right": "nmcli radio wifi toggle"
  },

  "pulseaudio": {
    "format": "vol {volume}%",
    "format-muted": "vol muted",
    "scroll-step": 5,
    "on-click":       "pavucontrol",
    "on-click-right": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
    "tooltip-format": "{desc}\n{volume}%"
  },

  "custom/bluetooth": {
    "exec": "@CONFIG@/sway/scripts/bluetooth-status",
    "interval": 5,
    "return-type": "json",
    "format": "{text}",
    "tooltip": true,
    "on-click":       "blueman-manager",
    "on-click-right": "bluetoothctl power off"
  },

  "power-profiles-daemon": {
    "format": "ppd:{icon}",
    "tooltip-format": "Power profile: {profile}\nClick to cycle",
    "format-icons": {
      "performance": "perf",
      "balanced":    "bal",
      "power-saver": "save"
    },
    "on-click": "@CONFIG@/sway/scripts/ppd-cycle"
  },

  "backlight": {
    "format": "☀ {percent}%",
    "tooltip-format": "Brightness {percent}%\nScroll to adjust",
    "interval": 2,
    "on-scroll-up":   "@CONFIG@/sway/scripts/bright.sh up",
    "on-scroll-down": "@CONFIG@/sway/scripts/bright.sh down",
    "on-click":       "@CONFIG@/sway/scripts/bright.sh up"
  },

  "battery": {
    "states": { "warning": 30, "critical": 15 },
    "format": "bat {capacity}%",
    "format-charging": "bat+ {capacity}%",
    "format-plugged":  "bat+ {capacity}%",
    "format-full":     "bat= {capacity}%",
    "tooltip-format":  "{timeTo}\n{capacity}%"
  },

  "custom/dnd": {
    "exec": "@CONFIG@/sway/scripts/notif-status",
    "interval": 2,
    "return-type": "json",
    "format": "{text}",
    "tooltip": true,
    "on-click": "@CONFIG@/sway/scripts/notif-toggle"
  },

  "custom/help": {
    "format": "help",
    "tooltip": "Help: all keybindings & commands (Mod+Shift+F1)",
    "on-click": "foot -e less @CONFIG@/sway/help.md"
  },

  "custom/power": {
    "format": "pwr",
    "tooltip": "Session menu (lock / logout / suspend / reboot / shutdown)",
    "on-click": "@CONFIG@/sway/scripts/menu.sh"
  },

  "tray": { "icon-size": 16, "spacing": 6 }
}
WAYBARCONF

install -Dm644 -- /dev/stdin "$WAYBAR/style.css" <<'WAYBARCSS'
@define-color blue_deep   #003b6f;
@define-color blue_panel  #1a5fa8;
@define-color blue_glass  #4a90c2;
@define-color blue_light  #7fb3d5;
@define-color silver      #c0c0c0;
@define-color ink         #0a1628;

* {
  font-family: "JetBrains Mono", sans-serif;
  font-size: 13px;
  min-height: 0;
  border: none;
  border-radius: 0;
}

window#waybar { background: transparent; color: @silver; }

.modules-left, .modules-center, .modules-right {
  background: @blue_deep;
  border-radius: 10px;
  padding: 0 8px;
}

#workspaces, #clock, #custom-apps, #custom-shot, #custom-rec,
#network, #pulseaudio, #custom-bluetooth, #power-profiles-daemon,
#backlight, #battery, #custom-dnd, #custom-help, #custom-power, #tray {
  padding: 0 10px;
  margin: 4px 0;
  border-radius: 8px;
  background: transparent;
  color: @silver;
}

#workspaces button {
  padding: 0 8px; margin: 4px 1px; border-radius: 6px;
  color: @blue_light; background: transparent;
}
#workspaces button:hover          { background: @blue_panel; color: @silver; }
#workspaces button.focused,
#workspaces button.active,
#workspaces button.visible        { background: @blue_glass; color: @ink; }
#workspaces button.urgent         { background: #b00020; color: @silver; }

#clock { font-weight: bold; color: @blue_light; }

#custom-apps:hover, #custom-shot:hover, #custom-rec:hover,
#network:hover, #pulseaudio:hover, #custom-bluetooth:hover,
#power-profiles-daemon:hover, #backlight:hover, #battery:hover,
#custom-dnd:hover, #custom-help:hover, #custom-power:hover {
  background: @blue_panel; color: @silver;
}

#custom-bluetooth.off  { color: #6b7a8f; }
#custom-bluetooth.on   { color: @blue_light; }
#custom-bluetooth.idle { color: @blue_glass; }
#custom-dnd.off        { color: #6b7a8f; }
#custom-dnd.on         { color: @blue_light; }
#custom-rec.active     { background: #b00020; color: #ffffff; }

#battery.warning  { color: #e0a020; }
#battery.critical { color: #b00020; }
#battery.charging { color: @blue_light; }

#power-profiles-daemon.performance { color: #e0a020; }
#power-profiles-daemon.balanced    { color: @blue_light; }
#power-profiles-daemon.power-saver { color: #4caf50; }

#tray > .passive         { -gtk-icon-effect: dim; }
#tray > .needs-attention { -gtk-icon-effect: highlight; background: @blue_glass; }
WAYBARCSS

sed -i "s|@CONFIG@|$CONFIG|g" "$WAYBAR/config"

# 11 — wlogout layout + style (kept as a bonus; menu.sh is the default path)
install -Dm644 -- /dev/stdin "$CONFIG/wlogout/layout" <<'WLOGOUT'
[
  { "label": "lock",     "action": "swaylock -f -c 003b6f", "text": "Lock",     "keybind": "l" },
  { "label": "logout",   "action": "swaymsg exit",          "text": "Logout",   "keybind": "e" },
  { "label": "suspend",  "action": "systemctl suspend",     "text": "Suspend",  "keybind": "s" },
  { "label": "hibernate","action": "systemctl hibernate",   "text": "Hibernate","keybind": "h" },
  { "label": "reboot",   "action": "systemctl reboot",      "text": "Reboot",   "keybind": "r" },
  { "label": "shutdown", "action": "systemctl poweroff",    "text": "Shutdown", "keybind": "p" }
]
WLOGOUT

install -Dm644 -- /dev/stdin "$CONFIG/wlogout/style.css" <<'WLOGOUTCSS'
* { background-image: none; font-family: "JetBrains Mono", sans-serif; font-size: 18px; }
window { background-color: rgba(10, 22, 40, 0.85); }
button {
  background-color: #003b6f; color: #c0c0c0;
  border: 2px solid #1a5fa8; border-radius: 12px;
  margin: 12px; padding: 24px;
}
button:hover { background-color: #1a5fa8; color: #ffffff; border-color: #4a90c2; }
button:focus { background-color: #4a90c2; color: #0a1628; }
WLOGOUTCSS

# 12 — help.md
install -Dm644 -- /dev/stdin "$CONFIG/sway/help.md" <<'HELPMD'
# Sway Help

Cheat sheet. Open anytime with **Mod+Shift+F1** (or the "help" button on the bar).

Search inside with `/` then type, `n` for next hit, `q` to quit.

---

## The 3 things newcomers ask first

1. **How do I close a window?** `Mod+Shift+Q`
2. **How do I open a terminal?** `Mod+Return`
3. **How do I log out / reboot?** `Mod+Shift+E` (opens the session menu)

`Mod` = Super/Windows key.

---

## Moving windows with the mouse

- **Tiled** windows cannot be dragged. First make one **floating**:
  `Mod+Shift+Space`.
- Then **Mod + left-drag** to move, **Mod + right-drag** to resize.
- Or resize with the keyboard: `Mod+R` enters *resize mode*, use arrows,
  `Enter` or `Esc` exits.

---

## Resize is a mode, not a combo

1. `Mod+R` — bar shows `[resize]`
2. Use `h/j/k/l` or arrows to resize
3. `Enter`, `Esc`, or `Mod+R` again — back to normal

`Mod+Shift+arrows` also resizes in some sway builds; the mode is the
reliable way.

---

## Essential keybinds

| Keys | Action |
|---|---|
| Mod+Return | Terminal (foot) |
| Mod+D | App launcher (fuzzel) |
| Mod+Shift+Q | Close focused window |
| Mod+Shift+C | Reload sway config |
| Mod+Shift+R | Restart sway (same session) |
| Mod+Shift+E | Session menu (lock/logout/suspend/reboot/shutdown) |
| Mod+Shift+F1 | This help page |
| Mod+Shift+X | Lock screen (swaylock) |

## Focus / move / workspaces

| Keys | Action |
|---|---|
| Mod+H/J/K/L or arrows | Focus window |
| Mod+Shift+H/J/K/L or arrows | Move window |
| Mod+1 .. Mod+9 | Switch workspace |
| Mod+Shift+1 .. Mod+Shift+9 | Move window to workspace |
| Mod+B / Mod+V | Split horizontal / vertical |
| Mod+E | Toggle split layout |
| Mod+S | Stacking layout |
| Mod+W | Tabbed layout |
| Mod+F | Fullscreen |
| Mod+Space | Toggle floating |
| Mod+Shift+Space | Toggle tiling/floating |
| Mod+R | Enter resize mode |

## Screenshots & recording

| Keys | Action |
|---|---|
| Print | Region → clipboard |
| Mod+Print | Full screen → clipboard |
| Mod+Shift+Print | Region → ~/Pictures/shot-<ts>.png |
| Mod+Ctrl+Print | Start/stop recording → ~/Videos/rec-<ts>.mp4 |
| Mod+Shift+V | Clipboard history picker |
| shot button | Menu: region/full/file |
| rec button | Menu: full/region, then toggle |

## Media & system

| Keys | Action |
|---|---|
| XF86AudioRaiseVolume / LowerVolume | Volume ±5% |
| XF86AudioMute / XF86AudioMicMute | Mute sink / source |
| XF86MonBrightnessUp / Down | Brightness ±5% (shows toast) |
| XF86AudioPlay / Pause / Next / Prev / Stop | Media transport |
| Mod+Shift+N / Mod+N | Dismiss one / all notifications |
| Mod+Shift+G | Toggle night light (gammastep, 4000K) |
| Mod+Shift+W | Open nmtui (network config) |

## The bar

| Button | Left click | Right click | Scroll |
|---|---|---|---|
| apps | fuzzel | - | - |
| shot | screenshot menu | - | - |
| rec | recording menu (or stop if running) | - | - |
| wifi | nmtui (floating) | wifi radio toggle | - |
| vol | pavucontrol | mute | volume ±5% |
| bt | blueman | power off BT | - |
| ppd | cycle perf → balanced → saver | - | - |
| ☀ | brightness +5% | - | brightness ±5% |
| bat | - | - | - |
| dnd | toggle do-not-disturb | - | - |
| help | open this page | - | - |
| pwr | session menu (fuzzel) | - | - |
| clock | - | full date | month |

Hover anything for a tooltip.

## Programs

### foot — terminal
Mod+Return. Ctrl+Shift+C/V copy/paste, Ctrl+Shift+N new window.
Config: `~/.config/foot/foot.ini`.

### fuzzel — launcher
Mod+D. Type to filter, Enter to launch, Esc to cancel.
Config: `~/.config/fuzzel/fuzzel.ini`.

### mako — notifications
Mod+Shift+N dismiss one, Mod+N all. Toggle DND from dnd button.
Config: `~/.config/mako/config`.

### Session menu — the "pwr" button or Mod+Shift+E
Fuzzel-based menu — always renders. Choices: lock / logout / suspend /
reboot / shutdown, plus an optional entry that launches the big-button
wlogout UI if you want it.

### waybar — the top bar
Restart: `pkill waybar; waybar &` — Reload: `pkill -SIGUSR2 waybar`
Config: `~/.config/waybar/config` + `style.css`.

### blueman — Bluetooth
Click bt or tray icon. Devices → right-click → Connect.
CLI: `bluetoothctl` (power on, scan on, pair MAC).

### nmtui — network
Click wifi, or Mod+Shift+W. Opens in a sized, floating foot window.
CLI: `nmcli device wifi list` — `nmcli device wifi connect "SSID" password "pw"`.

### pavucontrol — audio
Click vol. Output Devices / Input Devices / Configuration.

### brightnessctl — brightness
Keyboard Fn keys, the ☀ bar button, or:
`brightnessctl set 5%+` / `brightnessctl set 50%`.
Needs membership in the `video` group **or** an active logind session.
If it fails with permission denied, `sudo usermod -aG video $USER`, then
log out/in (or reboot).

### grim + slurp — screenshots
`grim -g "$(slurp)" - | wl-copy` — region to clipboard.
`grim - | wl-copy` — full screen to clipboard.

### wf-recorder — screen recording
`wf-recorder -f out.mp4` (Ctrl+C to stop, always SIGINT not SIGTERM).
The rec button / Mod+Ctrl+Print toggle cleanly.

### cliphist — clipboard history
Mod+Shift+V picker. `cliphist list`, `cliphist wipe`.

### gammastep — night light
Mod+Shift+G toggle 4000K. `gammastep -O 4000` on, `pkill gammastep` off.

### power-profiles-daemon — power mode
Click the ppd button to cycle:
- **performance** (orange) — full speed, more battery
- **balanced** (blue) — the default
- **power-saver** (green) — longer battery, lower clocks

If the button does nothing, the daemon isn't running:
`sudo systemctl start power-profiles-daemon`.

### nnn — file manager
Run `nnn`. hjkl/arrows move, Enter open, q quit, `?` help.

## When something is broken

| Problem | Fix |
|---|---|
| Bar gone | `pkill waybar; waybar &` |
| Bar config wrong | `pkill -SIGUSR2 waybar` |
| Sway config wrong | `Mod+Shift+C` — check terminal output |
| Sway frozen | `Ctrl+Alt+F2` → login → `pkill sway` |
| No sound | `wpctl status` — check default sink. `pavucontrol` → Configuration |
| No wifi | `nmcli device status` |
| BT won't pair | `bluetoothctl` → `power on`, `agent on`, `scan on`, `pair MAC` |
| Screenshare fails | `systemctl --user status xdg-desktop-portal-wlr` |
| No notifications | `pgrep mako` — if empty, `mako &`. Check dnd button |
| Stuck after lock | `Ctrl+Alt+F2`, `pkill swaylock` |
| ppd button dead | `systemctl status power-profiles-daemon` — must be **active** |
| Brightness keys do nothing | `brightnessctl info` in a terminal. If "Permission denied" → `sudo usermod -aG video $USER`, re-login |
| Brightness keys do nothing (permission OK) | Fn key may send a different keysym. Run `wev` and press it; look for `XF86MonBrightness*` |
| Menu button does nothing | `~/.config/sway/scripts/menu.sh` in a terminal — should list options |
| nmtui looks tiny | You're running plain `foot -e nmtui`; use `nmtui.sh` |

## Logs

| What | Where |
|---|---|
| Sway | `journalctl --user -u sway -b` |
| Waybar | `journalctl --user -xe \| grep waybar` |
| Portal | `journalctl --user -u xdg-desktop-portal-wlr -b` |
| Config syntax | `sway -c ~/.config/sway/config -C` |

## Config files

All under `~/.config/<program>/`. Written by the installer.
Edit in the repo and re-run; do NOT edit in `~/.config` directly.

## Useful commands

    # sway
    swaymsg reload
    swaymsg exit
    swaymsg -t get_tree
    sway -c ~/.config/sway/config -C

    # waybar
    pkill -SIGUSR2 waybar

    # audio
    wpctl status
    wpctl set-volume @DEFAULT_AUDIO_SINK@ 50%
    wpctl set-mute   @DEFAULT_AUDIO_SINK@ toggle

    # brightness
    brightnessctl info
    brightnessctl set 50%

    # network
    nmcli device status
    nmcli device wifi list
    nmcli device wifi connect "SSID" password "pw"

    # bluetooth
    bluetoothctl show
    bluetoothctl devices
    bluetoothctl connect MAC

    # power profile
    powerprofilesctl get
    powerprofilesctl set balanced

    # screenshots
    grim -g "$(slurp)" - | wl-copy
    grim - | wl-copy

## Displays, TVs, projectors

**Screen sharing in a browser** — just click "Share Screen" in the app.
The picker is sway's (region or window). If nothing appears:
`systemctl --user restart xdg-desktop-portal-wlr`.

**Plug in a TV or projector** — click "disp" on the bar (`wdisplays`),
drag the second screen where you want it, pick resolution, Apply.
Or CLI: `swaymsg -t get_outputs` then `swaymsg output HDMI-A-1 mode 1920x1080 position 1920,0`.

**Mirror instead of extend** — in `wdisplays`, tick "Mirror". CLI:
`swaymsg output HDMI-A-1 mode 1024x768 mirror eDP-1`.

**Auto-apply on hotplug** — kanshi (installed). Config: `~/.config/kanshi/config`.

HELPMD

# 13 — Sanity check
if grep -Rq '@[A-Z_]*@' "$CONFIG/sway/config" "$CONFIG/waybar/config" 2>/dev/null; then
  warn "unsubstituted placeholders remain:"
  grep -Rn '@[A-Z_]*@' "$CONFIG/sway/config" "$CONFIG/waybar/config" || true
fi

# 14 — Done
log "done. validate first:  sway -c $CONFIG/sway/config -C"
log "then log out and pick 'sway' (or run 'sway' from a tty)"
log "log: $LOG"
