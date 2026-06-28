#!/usr/bin/env bash
# uninstall.sh — removes the RA token keeper installed by install.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
hdr()  { echo -e "\n${BOLD}── $* ──${NC}"; }

BIN="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"
INJECT_MARKER="# ra-dolphin-fix"

echo ""
echo -e "${BOLD}RetroAchievements Token Keeper — uninstaller${NC}"
echo ""

# ── 1. stop and disable systemd units ────────────────────────────────────────
hdr "Stopping and disabling systemd units"

for unit in ra-token-refresh.timer ra-token-refresh.service ra-dolphin-guard.service; do
    if systemctl --user is-enabled "$unit" &>/dev/null; then
        systemctl --user disable --now "$unit" 2>/dev/null || true
        ok "Disabled: $unit"
    else
        warn "Not enabled (skipping): $unit"
    fi
done

for f in \
    "$SYSTEMD_DIR/ra-token-refresh.timer" \
    "$SYSTEMD_DIR/ra-token-refresh.service" \
    "$SYSTEMD_DIR/ra-dolphin-guard.service"
do
    if [[ -f "$f" ]]; then
        rm -f "$f"
        ok "Removed: $f"
    fi
done

systemctl --user daemon-reload
ok "systemd user daemon reloaded"

# ── 2. remove installed scripts ───────────────────────────────────────────────
hdr "Removing scripts"

for script in \
    "$BIN/ra-token-refresh" \
    "$BIN/ra-token-guard" \
    "$BIN/ra-dolphin-reinject" \
    "$BIN/dolphin-ra"
do
    if [[ -f "$script" ]]; then
        rm -f "$script"
        ok "Removed: $script"
    fi
done

# ── 3. remove injection from EmuDeck launcher ────────────────────────────────
hdr "Cleaning EmuDeck launcher injection (if present)"

LAUNCHERS=(
    "$HOME/Emulation/tools/launchers/dolphin-emu.sh"
    "$HOME/Emulation/roms/emulators/dolphin-emu.sh"
)

for LAUNCHER in "${LAUNCHERS[@]}"; do
    if [[ -f "$LAUNCHER" ]] && grep -qF "$INJECT_MARKER" "$LAUNCHER"; then
        TMP=$(mktemp)
        grep -vF "$INJECT_MARKER" "$LAUNCHER" > "$TMP" && mv "$TMP" "$LAUNCHER"
        ok "Removed guard injection from $LAUNCHER"
    fi
done

# ── 4. credentials ────────────────────────────────────────────────────────────
hdr "Credentials"
CREDS="$HOME/.config/ra-creds"
if [[ -f "$CREDS" ]]; then
    read -rp "Remove saved credentials ($CREDS)? [y/N] " ans
    if [[ "${ans,,}" == "y" ]]; then
        rm -f "$CREDS"
        ok "Credentials removed"
    else
        warn "Credentials kept at $CREDS"
    fi
fi

# ── 5. linger note ────────────────────────────────────────────────────────────
hdr "Note on loginctl linger"
echo "The installer ran 'loginctl enable-linger' so your user session"
echo "persists across Desktop↔Game Mode switches."
echo ""
echo "This is shared with other services (Decky, Syncthing, etc.)."
echo "If you want to disable it and you're sure nothing else needs it:"
echo "    loginctl disable-linger $(whoami)"
echo ""

echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
echo ""
