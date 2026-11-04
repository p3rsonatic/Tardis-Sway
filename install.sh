#!/usr/bin/env bash
# install.sh — one-shot installer for the TARDIS-blue Sway desktop.
# Generated from install.org by org-babel-tangle. Edit install.org, not this.
# Tested on Debian 12, LMDE 6, Ubuntu 24.04.
set -euo pipefail

DOTFILES="$HOME/dotfiles"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LOCALBIN="$HOME/.local/bin"
LOG="$HOME/.dotfiles-install.log"

log()  { printf '\033[1;38;5;33m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mXXX\033[0m %s\n' "$*" >&2; exit 1; }

[ "$EUID" -eq 0 ] && fail "Do not run as root."
sudo -v || fail "sudo required."
: > "$LOG"

# ── Keyboard detection ───────────────────────────────────────────────
# Order of preference: explicit override → /etc/default/keyboard
# (what Cinnamon's keyboard settings and localectl write to) → localectl
# → "us". Sanitized so a stray space can't break sway's parser.
XKB_LAYOUT="us"
XKB_VARIANT=""
KB_SRC="default"
if [ "${FORCE_LAYOUT:-0}" = "1" ] && [ -n "${XKB_LAYOUT_OVERRIDE:-}" ]; then
  XKB_LAYOUT="$XKB_LAYOUT_OVERRIDE"
  XKB_VARIANT="${XKB_VARIANT_OVERRIDE:-}"
  KB_SRC="env override"
elif [ -f /etc/default/keyboard ]; then
  # shellcheck disable=SC1091
  . /etc/default/keyboard 2>/dev/null || true
  XKB_LAYOUT="${XKBLAYOUT:-us}"
  XKB_VARIANT="${XKBVARIANT:-}"
  KB_SRC="/etc/default/keyboard"
elif command -v localectl >/dev/null 2>&1; then
  XKB_LAYOUT=$(localectl status 2>/dev/null | awk -F: '/X11 Layout/ {gsub(/ /,"",$2); print $2}' | cut -d, -f1)
  XKB_VARIANT=$(localectl status 2>/dev/null | awk -F: '/X11 Variant/ {gsub(/ /,"",$2); print $2}' | cut -d, -f1)
  KB_SRC="localectl"
fi
XKB_LAYOUT=$(printf '%s' "${XKB_LAYOUT:-us}" | tr -d '[:space:]')
XKB_VARIANT=$(printf '%s' "${XKB_VARIANT:-}" | tr -d '[:space:]')
[ -z "$XKB_LAYOUT" ] && XKB_LAYOUT="us"
log "Keyboard: layout='$XKB_LAYOUT' variant='${XKB_VARIANT:-<none>}' (source: $KB_SRC)"

log "Checking dpkg state…"
if [ -z "$(sudo dpkg --audit 2>/dev/null)" ]; then
  log "dpkg state OK."
else
  warn "dpkg has half-configured packages; attempting recovery…"
  sudo dpkg --configure -a >>"$LOG" 2>&1 \
    || warn "dpkg --configure -a failed (see $LOG). Continuing anyway."
fi

sudo apt-get update -qq >>"$LOG" 2>&1 || warn "apt update returned non-zero."

POLKIT_PKG=""
for p in lxpolkit mate-polkit; do
  if apt-cache show "$p" >/dev/null 2>&1; then
    POLKIT_PKG="$p"
    break
  fi
done
[ -z "$POLKIT_PKG" ] && fail "No polkit agent in apt (tried lxpolkit, mate-polkit)."
log "Polkit package: $POLKIT_PKG"

PKGS=(
  sway swaybg swayidle swaylock
  waybar mako-notifier wofi foot
  grim slurp wl-clipboard wf-recorder cliphist
  xdg-desktop-portal-wlr xdg-desktop-portal-gtk
  pipewire wireplumber pipewire-pulse pulsemixer playerctl
  network-manager bluez
  blueman
  power-profiles-daemon
  gammastep brightnessctl wlogout kanshi
  gnome-keyring udiskie
  "$POLKIT_PKG"
  micro fd-find qalc btop ncdu nnn
  fonts-font-awesome fonts-jetbrains-mono fonts-noto-color-emoji
  jq curl unzip python3
)

CRITICAL=(
  sway waybar foot wofi mako-notifier
  "$POLKIT_PKG"
  blueman power-profiles-daemon
  nnn jq pipewire wireplumber
  network-manager brightnessctl pulsemixer
  grim slurp wl-clipboard wf-recorder cliphist
  gammastep wlogout kanshi
  fonts-jetbrains-mono
)

OPTIONAL=( )

log "Installing required packages…"
if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
     -o Dpkg::Options::=--force-confdef \
     -o Dpkg::Options::=--force-confold \
     "${PKGS[@]}" 2>&1 | tee -a "$LOG"; then
  warn "apt-get install returned non-zero (may be unrelated to our packages)."
  warn "Attempting recovery…"
  sudo dpkg --configure -a >>"$LOG" 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -f -y >>"$LOG" 2>&1 || true
fi

log "Verifying critical packages…"
MISSING=()
for p in "${CRITICAL[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null \
       | grep -q '^install ok installed$'; then
    MISSING+=("$p")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  warn "Missing critical packages: ${MISSING[*]}"
  warn "Full log: $LOG"
  fail "Cannot proceed without: ${MISSING[*]}"
fi
log "All critical packages verified."

log "Installing optional packages (warnings only)…"
for p in "${OPTIONAL[@]}"; do
  if apt-cache show "$p" >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" >>"$LOG" 2>&1 \
      || warn "Could not install optional: $p"
  else
    warn "Not in this release: $p (skipped)"
  fi
done

# Bluetooth daemon must be live for blueman-manager to see adapters.
sudo systemctl enable --now bluetooth >/dev/null 2>&1 \
  || warn "Could not enable bluetooth service; blueman may show no adapters until reboot."

mkdir -p "$LOCALBIN"

if ! command -v bluetuith >/dev/null 2>&1; then
  case "$(dpkg --print-architecture)" in
    amd64) BIN=bluetuith-linux-amd64 ;;
    arm64) BIN=bluetuith-linux-arm64 ;;
    *)     BIN="" ;;
  esac
  if [ -n "$BIN" ]; then
    log "Fetching bluetuith…"
    if curl -fsSL "https://github.com/bluetuith-org/bluetuith/releases/latest/download/$BIN" \
         -o "$LOCALBIN/bluetuith"; then
      chmod +x "$LOCALBIN/bluetuith"
    else
      warn "bluetuith fetch failed; Bluetooth falls back to bluetoothctl."
    fi
  fi
fi

if ! command -v yazi >/dev/null 2>&1; then
  case "$(dpkg --print-architecture)" in
    amd64) YZ=yazi-x86_64-unknown-linux-gnu.zip ;;
    arm64) YZ=yazi-aarch64-unknown-linux-gnu.zip ;;
    *)     YZ="" ;;
  esac
  if [ -n "$YZ" ]; then
    log "Fetching yazi (optional upgrade over nnn)…"
    tmp=$(mktemp -d)
    if curl -fsSL "https://github.com/sxyazi/yazi/releases/latest/download/$YZ" \
         -o "$tmp/yazi.zip" 2>/dev/null; then
      unzip -qo "$tmp/yazi.zip" -d "$tmp" 2>/dev/null
      find "$tmp" -type f -name yazi -exec install -m755 {} "$LOCALBIN/yazi" \; 2>/dev/null
      find "$tmp" -type f -name ya   -exec install -m755 {} "$LOCALBIN/ya"   \; 2>/dev/null
    fi
    rm -rf "$tmp"
    command -v yazi >/dev/null 2>&1 || warn "yazi fetch failed; using nnn."
  fi
fi

for RC in "$HOME/.profile" "$HOME/.bashrc"; do
  [ -f "$RC" ] || continue
  grep -q 'HOME/.local/bin' "$RC" \
    || printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$RC"
done

log "Writing dotfiles to $DOTFILES…"
mkdir -p "$DOTFILES"/{sway,waybar,mako,foot,wofi,wlogout,gammastep,kanshi,wallpapers}

cat > "$DOTFILES/sway/config" <<'SWAY_EOF'
# Sway config — TARDIS blue
# Stock sway/i3 binds are preserved verbatim (from /etc/sway/config).
# TARDIS additions are on unused keys only, marked with a trailing comment.

set $mod Mod4
set $term foot
set $menu wofi --show drun

# ═════════════════════════════════════════════════════════════════════
# STOCK SWAY BINDS — copied verbatim from /etc/sway/config
# ═════════════════════════════════════════════════════════════════════

# Terminal
bindsym $mod+Return exec $term

# Launcher
bindsym $mod+d exec $menu

# Kill focused window
bindsym $mod+Shift+q kill

# Drag floating windows with Super+left-mouse; resize with Super+right-mouse
floating_modifier $mod normal

# Reload the configuration file
bindsym $mod+Shift+c reload

# Exit sway (confirmation prompt)
bindsym $mod+Shift+e exec swaynag -t warning -m 'You pressed the exit shortcut. Do you really want to exit sway? This will end your Wayland session.' -B 'Yes, exit sway' 'swaymsg exit'

# Focus
bindsym $mod+Left focus left
bindsym $mod+Down focus down
bindsym $mod+Up focus up
bindsym $mod+Right focus right

# Move window
bindsym $mod+Shift+Left move left
bindsym $mod+Shift+Down move down
bindsym $mod+Shift+Up move up
bindsym $mod+Shift+Right move right

# Workspaces 1-9 (stock sway only ships 1-5; extended)
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+5 workspace number 5
bindsym $mod+6 workspace number 6
bindsym $mod+7 workspace number 7
bindsym $mod+8 workspace number 8
bindsym $mod+9 workspace number 9

# Move window to workspace 1-9
bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4
bindsym $mod+Shift+5 move container to workspace number 5
bindsym $mod+Shift+6 move container to workspace number 6
bindsym $mod+Shift+7 move container to workspace number 7
bindsym $mod+Shift+8 move container to workspace number 8
bindsym $mod+Shift+9 move container to workspace number 9

# Layout
bindsym $mod+b splith
bindsym $mod+v splitv
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split
bindsym $mod+f fullscreen

# Float / focus mode
bindsym $mod+Shift+space floating toggle
bindsym $mod+space focus mode_toggle

# Resize mode — enter with Super+R, use arrows, Enter/Esc exits
mode "resize" {
    bindsym Left resize shrink width 10 px or 10 ppt
    bindsym Down resize grow height 10 px or 10 ppt
    bindsym Up resize shrink height 10 px or 10 ppt
    bindsym Right resize grow width 10 px or 10 ppt
    bindsym Return mode "default"
    bindsym Escape mode "default"
    bindsym $mod+r mode "default"
}
bindsym $mod+r mode "resize"

# ═════════════════════════════════════════════════════════════════════
# TARDIS ADDITIONS — new binds on unused keys + exec lines only
# ═════════════════════════════════════════════════════════════════════

# Startup
exec swaybg -i ~/wallpapers/current.ppm
exec_always sh -c 'pkill -x waybar 2>/dev/null; sleep 0.2; exec waybar'
exec mako
exec __POLKIT__
exec gnome-keyring-daemon --start --components=secrets
exec udiskie --no-notify --tray=false
exec swayidle -w \
  timeout 600 'swaylock -f -c 0a1428' \
  timeout 900 'swaymsg "output * dpms off"' \
  resume 'swaymsg "output * dpms on"' \
  before-sleep 'swaylock -f -c 0a1428'

# Input — touchpad with physical button areas
# click_method button_areas : bottom-right = right click, bottom-left = left
# middle_emulation enabled : bottom-middle press = middle click
input type:touchpad {
  tap enabled
  natural_scroll enabled
  dwt enabled
  click_method button_areas
  middle_emulation enabled
}

# Appearance
default_border pixel 2
default_floating_border normal
client.focused   #0F5CA8 #0F5CA8 #0a1428 #4A9FE0 #4A9FE0
client.unfocused #0d1e33 #0d1e33 #8899bb #0d1e33 #0d1e33
client.urgent    #f38ba8 #f38ba8 #0a1428 #f38ba8 #f38ba8

for_window [window_type="dialog"] floating enable
for_window [window_type="utility"] floating enable
for_window [app_id="foot-tui"] floating enable, resize set 100 ppt 100 ppt
for_window [app_id="foot-popup"] floating enable, resize set 500 450, move position center

# nmtui: NOT fullscreen (sway pins undersized fullscreen surfaces top-left).
# Float at workspace size; nmtui.sh sleeps 0.2s so foot processes the
# resize before ncurses queries terminal dimensions.
for_window [app_id="foot-nmtui"] floating enable, resize set 100 ppt 100 ppt, move position center

# blueman: centered float so it reads like a dialog, not a tiled app
for_window [app_id="blueman-manager"] floating enable, move position center

# TARDIS launchers (all on keys unused by stock sway)
bindsym $mod+a exec ~/.config/sway/launch.sh                # All tools
bindsym $mod+slash exec ~/.config/sway/help.sh              # Show all shortcuts
bindsym $mod+n exec ~/.config/sway/toggles.sh night         # Night light
bindsym $mod+c exec ~/.config/sway/calendar.sh              # Calendar
bindsym $mod+m exec foot --app-id=foot-tui -e pulsemixer    # Audio mixer
bindsym Print exec ~/.config/sway/shot.sh                   # Screenshot
bindsym $mod+Shift+r exec ~/.config/sway/rec.sh             # Record screen
bindsym $mod+Shift+v exec ~/.config/sway/clip.sh            # Clipboard history
bindsym $mod+Shift+w exec ~/.config/sway/nmtui.sh           # Network (nmtui)
bindsym $mod+Shift+b exec blueman-manager                   # Bluetooth (GUI)
bindsym $mod+Shift+f exec ~/.config/sway/files.sh           # Files

# ── Media keys (stock sway does not bind these) ──────────────────────
bindsym XF86AudioRaiseVolume  exec ~/.config/sway/vol.sh up
bindsym XF86AudioLowerVolume  exec ~/.config/sway/vol.sh down
bindsym XF86AudioMute         exec ~/.config/sway/vol.sh mute
bindsym XF86MonBrightnessUp   exec ~/.config/sway/bright.sh up
bindsym XF86MonBrightnessDown exec ~/.config/sway/bright.sh down
bindsym XF86AudioPlay  exec playerctl play-pause
bindsym XF86AudioNext  exec playerctl next
bindsym XF86AudioPrev  exec playerctl previous
SWAY_EOF

{
  echo ""
  echo "# Keyboard layout (auto-detected by install.sh)"
  echo "input type:keyboard {"
  echo "  xkb_layout $XKB_LAYOUT"
  [ -n "$XKB_VARIANT" ] && echo "  xkb_variant $XKB_VARIANT"
  echo "}"
} >> "$DOTFILES/sway/config"

log "Keyboard written to sway config: xkb_layout $XKB_LAYOUT${XKB_VARIANT:+ xkb_variant $XKB_VARIANT}"

cat > "$DOTFILES/sway/help.sh" <<'HELP_EOF'
#!/bin/sh
CONFIG="$HOME/.config/sway/config"

{
  printf '\n'
  printf '  TARDIS Sway — Keyboard Shortcuts\n'
  printf '  ═══════════════════════════════════════════════════════════\n'
  printf '\n'
  printf '  Resize is a MODE: press Super+R, use arrows, Enter/Esc exits.\n'
  printf '  Move/resize a floating window by mouse: Super + drag (or right-drag).\n'
  printf '  Type in the search box to filter this list.\n'
  printf '\n'
  printf '  %-44s %s\n' "Action" "Shortcut"
  printf '  %-44s %s\n' "────────────────────────────────────────────" "──────────────────"
  printf '\n'

  # All top-level bindsym lines, formatted and de-duplicated
  grep -E '^bindsym ' "$CONFIG" \
    | sed -E 's/^bindsym //' \
    | awk '{
        key = $1
        rest = $0
        sub(/^[^ ]+ /, "", rest)
        if (match(rest, /#[^#]*$/)) {
          desc = substr(rest, RSTART + 1)
          sub(/^[[:space:]]+/, "", desc)
        } else {
          desc = rest
        }
        gsub(/Mod4/, "Super", key)
        gsub(/\$mod/, "Super", key)
        printf "  %-44s %s\n", desc, key
      }' \
    | sort -u

  printf '\n'
  printf '  %-44s %s\n' "── Resize mode (press Super+R first) ──" "──────────"
  printf '  %-44s %s\n' "Shrink width"   "Left"
  printf '  %-44s %s\n' "Grow width"     "Right"
  printf '  %-44s %s\n' "Shrink height"  "Up"
  printf '  %-44s %s\n' "Grow height"    "Down"
  printf '  %-44s %s\n' "Exit resize mode" "Enter / Esc / Super+R"
  printf '\n'
} | wofi --dmenu --prompt "Shortcuts (type to filter)" --width 900 --height 600
HELP_EOF

cat > "$DOTFILES/sway/files.sh" <<'FILES_EOF'
#!/bin/sh
if command -v yazi >/dev/null 2>&1; then
  exec foot --app-id=foot-tui -e yazi
fi
exec foot --app-id=foot-tui -e nnn -d
FILES_EOF

cat > "$DOTFILES/sway/launch.sh" <<'LAUNCH_EOF'
#!/bin/sh
TUI="foot --app-id=foot-tui"
POPUP="foot --app-id=foot-popup"

choice=$(printf '%s\n' \
  "Apps            (wofi)" \
  "Terminal        (foot)" \
  "Files           (yazi / nnn)" \
  "Network         (nmtui)" \
  "Bluetooth       (blueman)" \
  "Audio           (pulsemixer)" \
  "Processes       (btop)" \
  "Disk usage      (ncdu)" \
  "Calendar        (ncal)" \
  "Calculator      (qalc)" \
  "Screenshot      (grim)" \
  "Record screen   (wf-recorder)" \
  "Clipboard       (cliphist)" \
  "Help / keybinds" \
  "Log out / power" \
  | wofi --dmenu --prompt "All tools" --insensitive)

case "$choice" in
  Apps*)      wofi --show drun --insensitive ;;
  Terminal*)  foot ;;
  Files*)     ~/.config/sway/files.sh ;;
  Network*)   ~/.config/sway/nmtui.sh ;;
  Bluetooth*) blueman-manager ;;
  Audio*)     $TUI -e pulsemixer ;;
  Processes*) $TUI -e btop ;;
  Disk*)      $TUI -e ncdu ~ ;;
  Calendar*)  ~/.config/sway/calendar.sh ;;
  Calc*)      $POPUP -e sh -c 'qalc; read _' ;;
  Screenshot*)~/.config/sway/shot.sh ;;
  Record*)    ~/.config/sway/rec.sh ;;
  Clipboard*) ~/.config/sway/clip.sh ;;
  Help*)      ~/.config/sway/help.sh ;;
  Logout*)    ~/.config/sway/menu.sh ;;
esac
LAUNCH_EOF

cat > "$DOTFILES/sway/vol.sh" <<'VOL_EOF'
#!/bin/sh
case "$1" in
  up)   wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ ;;
  down) wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- ;;
  mute) wpctl set-mute   @DEFAULT_AUDIO_SINK@ toggle ;;
esac
VOL=$(wpctl get-volume @DEFAULT_AUDIO_SINK@)
if printf '%s' "$VOL" | grep -q MUTED; then
  msg="Muted"
else
  msg="$(printf '%s' "$VOL" | awk '{printf "%d", $2*100}')%"
fi
notify-send -h string:x-canonical-private-synchronous:vol -t 1200 "Volume" "$msg"
VOL_EOF

cat > "$DOTFILES/sway/bright.sh" <<'BRIGHT_EOF'
#!/bin/sh
case "$1" in
  up)   brightnessctl set 5%+ >/dev/null ;;
  down) brightnessctl set 5%- >/dev/null ;;
esac
pct=$(brightnessctl -m | awk -F, '{gsub(/%/,"",$4); print $4}')
notify-send -h string:x-canonical-private-synchronous:bright -t 1200 "Brightness" "${pct}%"
BRIGHT_EOF

cat > "$DOTFILES/sway/shot.sh" <<'SHOT_EOF'
#!/bin/sh
mkdir -p "$HOME/Pictures"
choice=$(printf 'Region\nWindow\nFull screen' | wofi --dmenu --prompt 'Screenshot')
ts=$(date +%Y%m%d-%H%M%S)
out="$HOME/Pictures/shot-$ts.png"
case "$choice" in
  Region)
    geom=$(slurp) || exit 0
    grim -g "$geom" "$out" && wl-copy < "$out" ;;
  Window)
    geom=$(swaymsg -t get_tree | jq -r '.. | select(.focused?) | .rect | "\(.x),\(.y) \(.width)x\(.height)"')
    grim -g "$geom" "$out" && wl-copy < "$out" ;;
  Full*)
    grim "$out" && wl-copy < "$out" ;;
  *) exit 0 ;;
esac
notify-send -t 2000 "Screenshot" "Saved to $out"
SHOT_EOF

cat > "$DOTFILES/sway/rec.sh" <<'REC_EOF'
#!/bin/sh
if pgrep -x wf-recorder >/dev/null; then
  pkill -INT wf-recorder
  notify-send -t 2000 "Recording" "Stopped"
  exit 0
fi
choice=$(printf 'Region\nFull screen\nRegion + audio\nFull + audio' | wofi --dmenu --prompt 'Record')
[ -z "$choice" ] && exit 0
mkdir -p "$HOME/Videos"
out="$HOME/Videos/rec-$(date +%Y%m%d-%H%M%S).mp4"
audio=""
case "$choice" in *audio) audio="--audio=$(pactl get-default-sink).monitor" ;; esac
geom=""
case "$choice" in Region*) geom="-g $(slurp)" ;; esac
# shellcheck disable=SC2086
wf-recorder $geom $audio -f "$out" >/dev/null 2>&1 &
notify-send -t 2000 "Recording" "→ $out"
REC_EOF

cat > "$DOTFILES/sway/clip.sh" <<'CLIP_EOF'
#!/bin/sh
sel=$(cliphist list | wofi --dmenu --insensitive --prompt "Clipboard")
[ -z "$sel" ] && exit 0
printf '%s' "$sel" | cliphist decode | wl-copy
CLIP_EOF

cat > "$DOTFILES/sway/calendar.sh" <<'CAL_EOF'
#!/bin/sh
foot --app-id=foot-popup -T calendar -e sh -c 'ncal -3 -w; printf "\nPress Enter to close.\n"; read _'
CAL_EOF

cat > "$DOTFILES/sway/nmtui.sh" <<'NMTUI_EOF'
#!/bin/sh
# Float at workspace size (Module 8 rule), then wait for foot to process
# the resize before ncurses queries the terminal dimensions. Without the
# sleep, nmtui renders at foot's guessed initial size (top-left quadrant).
exec foot --app-id=foot-nmtui -e sh -c 'sleep 0.2; exec nmtui'
NMTUI_EOF

cat > "$DOTFILES/sway/menu.sh" <<'MENU_EOF'
#!/bin/sh
# Session menu. wofi-based: always renders, no GTK layer-shell dependency.
# wlogout is still available manually: `wlogout` in a terminal.
choice=$(printf '%s\n' \
  "Lock screen" \
  "Log out" \
  "Suspend" \
  "Reboot" \
  "Shut down" \
  | wofi --dmenu --insensitive --prompt "Session")

case "$choice" in
  "Lock screen") swaylock -f -c 0a1428 ;;
  "Log out")     swaymsg exit ;;
  "Suspend")     systemctl suspend ;;
  "Reboot")      systemctl reboot ;;
  "Shut down")   systemctl poweroff ;;
esac
MENU_EOF

cat > "$DOTFILES/sway/toggles.sh" <<'TOG_EOF'
#!/bin/sh
case "$1" in
  night)
    if pgrep -x gammastep >/dev/null; then
      pkill -x gammastep
      notify-send -t 1500 "Night light" "Off"
    else
      gammastep -O 3500 >/dev/null 2>&1 &
      notify-send -t 1500 "Night light" "On (3500K)"
    fi
    ;;
  night-state)
    pgrep -x gammastep >/dev/null && echo '{"class":"active"}' || echo '{"class":"inactive"}'
    ;;
  power)
    if ! command -v powerprofilesctl >/dev/null 2>&1; then
      notify-send -t 2500 "Power" "power-profiles-daemon not installed"
      exit 0
    fi
    cur=$(powerprofilesctl get 2>/dev/null)
    if [ "$cur" = "power-saver" ]; then
      powerprofilesctl set balanced >/dev/null 2>&1 \
        && notify-send -t 1500 "Power" "Balanced"
    else
      powerprofilesctl set power-saver >/dev/null 2>&1 \
        && notify-send -t 1500 "Power" "Power saver"
    fi
    ;;
  power-state)
    if ! command -v powerprofilesctl >/dev/null 2>&1; then
      echo '{"text":" ❓","class":"inactive","tooltip":"power-profiles-daemon not available"}'
      exit 0
    fi
    case "$(powerprofilesctl get 2>/dev/null)" in
      power-saver) echo '{"text":" 🔋 Saver","class":"active","tooltip":"Power saver — click to switch"}';;
      balanced)    echo '{"text":" ⚡ Bal","class":"inactive","tooltip":"Balanced — click to switch"}';;
      performance) echo '{"text":" 🚀 Perf","class":"perf","tooltip":"Performance — click to switch"}';;
      *)           echo '{"text":" ❓","class":"inactive","tooltip":"Unknown"}';;
    esac
    ;;
esac
TOG_EOF

cat > "$DOTFILES/mako/config" <<'MAKO_EOF'
font=JetBrains Mono 11
width=380
height=140
margin=12
padding=12
border-size=2
border-radius=10
border-color=#4A9FE0
background-color=#0a1428cc
text-color=#cdd6f4
progress-color=over #f38ba8cc
default-timeout=6000
anchor=top-right
icons=1
max-visible=4
layer=overlay
MAKO_EOF

cat > "$DOTFILES/foot/foot.ini" <<'FOOT_EOF'
[main]
font=JetBrains Mono:size=12
pad=10x10
dpi-aware=no
selection-clipboard=clipboard

[colors]
background=0a1428
foreground=cdd6f4
regular0=1a2740
regular1=f38ba8
regular2=a6e3a1
regular3=f9e2af
regular4=0F5CA8
regular5=c7a7ff
regular6=94e2d5
regular7=bac2de
bright0=2a3a5a
bright1=f38ba8
bright2=a6e3a1
bright3=f9e2af
bright4=4A9FE0
bright5=c7a7ff
bright6=94e2d5
bright7=a6adc8

[cursor]
color=0a1428 4A9FE0
FOOT_EOF

cat > "$DOTFILES/wofi/config" <<'WOFI_EOF'
show=drun
insensitive=true
allow_images=true
image_size=24
width=520
height=420
prompt=Search
hide_scroll=true
term=foot
WOFI_EOF

cat > "$DOTFILES/wofi/style.css" <<'WOFICSS_EOF'
window {
  background: #0d1e33;
  border: 2px solid #4A9FE0;
  border-radius: 12px;
  font-family: "JetBrains Mono", sans-serif;
  font-size: 14px;
}
#input {
  margin: 10px; padding: 8px; border-radius: 8px; border: none;
  background: #0a1428; color: #cdd6f4;
}
#entry { padding: 8px 12px; border-radius: 8px; color: #cdd6f4; }
#entry:selected { background: #0F5CA8; color: #ffffff; }
WOFICSS_EOF

cat > "$DOTFILES/gammastep/config.ini" <<'GAM_EOF'
[general]
location-provider=manual
adjustment-method=wayland

[manual]
lat=0.0
lon=0.0
GAM_EOF

cat > "$DOTFILES/kanshi/config" <<'KAN_EOF'
profile default {
  output * enable
  output * scale 1
}
KAN_EOF

if [ ! -f "$DOTFILES/wallpapers/current.ppm" ]; then
  log "Generating TARDIS-blue wallpaper…"
  python3 - "$DOTFILES/wallpapers/current.ppm" <<'PY_EOF'
import sys
w, h = 1920, 1080
top = (0x00, 0x14, 0x30)
bot = (0x00, 0x3B, 0x6F)
buf = bytearray(b'P6\n%d %d\n255\n' % (w, h))
for y in range(h):
    t = y / (h - 1)
    r = int(top[0] + (bot[0] - top[0]) * t)
    g = int(top[1] + (bot[1] - top[1]) * t)
    b = int(top[2] + (bot[2] - top[2]) * t)
    buf.extend(bytes((r, g, b)) * w)
open(sys.argv[1], 'wb').write(buf)
PY_EOF
fi

POLKIT=""
for p in \
  /usr/bin/lxpolkit \
  /usr/libexec/lxpolkit \
  /usr/libexec/polkit-gnome-authentication-agent-1 \
  /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 \
  /usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1 \
  /usr/lib/mate-polkit/polkit-mate-authentication-agent-1 \
  /usr/lib/x86_64-linux-gnu/libexec/polkit-mate-authentication-agent-1 ; do
  if [ -x "$p" ]; then POLKIT="$p"; break; fi
done

if [ -z "$POLKIT" ]; then
  warn "No polkit authentication agent found on disk."
  sed -i '/__POLKIT__/d' "$DOTFILES/sway/config"
else
  log "Polkit agent: $POLKIT"
  sed -i "s|__POLKIT__|$POLKIT|" "$DOTFILES/sway/config"
fi

chmod +x "$DOTFILES"/sway/*.sh
cp "$0" "$DOTFILES/install.sh" 2>/dev/null || true
chmod +x "$DOTFILES/install.sh" 2>/dev/null || true

backup_if_real() {
  local t="$1"
  if [ -e "$t" ] && [ ! -L "$t" ]; then
    local b="$t.bak-$(date +%s)"
    warn "Backing up $t → $b"
    mv "$t" "$b"
  fi
}

log "Linking configs into $CONFIG…"
for d in sway waybar mako foot wofi wlogout gammastep kanshi; do
  backup_if_real "$CONFIG/$d"
  ln -sfn "$DOTFILES/$d" "$CONFIG/$d"
done
backup_if_real "$HOME/wallpapers"
ln -sfn "$DOTFILES/wallpapers" "$HOME/wallpapers"

ERRS=""
[ -z "$POLKIT" ] || [ ! -x "$POLKIT" ] && ERRS="${ERRS}· no working polkit agent\n"
grep -qE '^exec /.*(polkit|lxpolkit)' "$DOTFILES/sway/config" 2>/dev/null \
  || ERRS="${ERRS}· sway config has no polkit exec line\n"
{ command -v nnn >/dev/null 2>&1 || command -v yazi >/dev/null 2>&1; } \
  || ERRS="${ERRS}· no file manager (nnn or yazi)\n"
[ -x "$DOTFILES/sway/files.sh" ] || ERRS="${ERRS}· files.sh not executable\n"
[ -x "$DOTFILES/sway/help.sh" ]  || ERRS="${ERRS}· help.sh not executable\n"

if [ -n "$ERRS" ]; then
  warn "Install verification FAILED:"
  printf "$ERRS" >&2
  warn "Do NOT log out into Sway until these are resolved."
  exit 1
fi

if [ ! -f /usr/share/wayland-sessions/sway.desktop ]; then
  warn "/usr/share/wayland-sessions/sway.desktop not found; your DM may not list Sway."
fi

if ! sudo dpkg --audit 2>/dev/null | grep -q .; then
  :
else
  warn "dpkg still has half-configured packages. The desktop will work,"
  warn "but 'sudo apt install …' will keep failing until you fix them, e.g.:"
  warn "  sudo apt remove --purge virtualbox-dkms   # if you don't need VBox"
  warn "  sudo apt install --reinstall virtualbox-dkms  # to rebuild it"
fi

log "Verified: polkit agent = $POLKIT"
if command -v yazi >/dev/null 2>&1; then
  log "Verified: file manager = yazi (nnn also present)"
else
  log "Verified: file manager = nnn"
fi

cat <<MSG_EOF

  ✓ Install complete and verified.

  Log out. At the login screen, pick "Sway".

  First-run orientation:
    • Bar is the menu: Apps · Help · Wi-Fi · Vol · BT · Night · Rec · Menu
    • Super+A   → every tool in one menu
    • Super+/   → every shortcut (generated live from sway/config)
    • Super+E   → files (yazi if installed, else nnn)
    • Super+Shift+Q → wlogout (lock / suspend / reboot / shutdown)
    • Volume / brightness keys → blue mako toast, never a window

  Install log: $LOG

MSG_EOF
