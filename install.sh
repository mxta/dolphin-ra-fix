#!/usr/bin/env bash
# install.sh — RetroAchievements token keeper for Dolphin on Steam Deck
# Run once in Konsole:  bash install.sh
set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
die()  { echo -e "${RED}✗ ERROR:${NC} $*" >&2; exit 1; }
hdr()  { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── paths ────────────────────────────────────────────────────────────────────
CREDS="$HOME/.config/ra-creds"
BIN="$HOME/.local/bin"
REFRESH_SCRIPT="$BIN/ra-token-refresh"
GUARD_SCRIPT="$BIN/ra-token-guard"
REINJECT_SCRIPT="$BIN/ra-dolphin-reinject"
WRAPPER_SCRIPT="$BIN/dolphin-ra"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_DIR/ra-token-refresh.service"
TIMER_FILE="$SYSTEMD_DIR/ra-token-refresh.timer"
GUARD_SERVICE_FILE="$SYSTEMD_DIR/ra-dolphin-guard.service"
RA_HOST="retroachievements.org"
INJECT_MARKER="# ra-dolphin-fix"

echo ""
echo -e "${BOLD}RetroAchievements Token Keeper — installer${NC}"
echo "Keeps Dolphin's RA login alive across Desktop↔Game Mode switches."
echo ""

# ── 1. dependency check ──────────────────────────────────────────────────────
hdr "Checking dependencies"
for cmd in curl systemctl loginctl; do
    command -v "$cmd" &>/dev/null || die "$cmd not found — is this a Steam Deck?"
done
ok "curl, systemctl, loginctl found"

mkdir -p "$BIN" "$SYSTEMD_DIR"

# ── 2. credentials ───────────────────────────────────────────────────────────
hdr "RetroAchievements credentials"

if [[ -f "$CREDS" ]]; then
    # shellcheck source=/dev/null
    source "$CREDS"
    echo "Existing credentials found for user: ${RA_USER:-<empty>}"
    read -rp "Keep them? [Y/n] " keep
    if [[ "${keep,,}" == "n" ]]; then
        unset RA_USER RA_PASS
    fi
fi

if [[ -z "${RA_USER:-}" || -z "${RA_PASS:-}" ]]; then
    read -rp "RetroAchievements username: " RA_USER
    read -rsp "RetroAchievements password: " RA_PASS
    echo ""
    [[ -n "$RA_USER" && -n "$RA_PASS" ]] || die "Username and password cannot be empty."
fi

printf 'RA_USER=%s\nRA_PASS=%s\n' "$RA_USER" "${RA_PASS}" > "$CREDS"
chmod 600 "$CREDS"
ok "Credentials stored in $CREDS (mode 600)"

# ── 3. locate RetroAchievements.ini ──────────────────────────────────────────
hdr "Locating Dolphin's RetroAchievements.ini"

find_ini() {
    local candidates=(
        "$HOME/.var/app/org.DolphinEmu.dolphin-emu/config/dolphin-emu/RetroAchievements.ini"
        "$HOME/.var/app/net.retrodeck.retrodeck/config/dolphin-emu/RetroAchievements.ini"
        "$HOME/.config/dolphin-emu/RetroAchievements.ini"
    )
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    # Wider search fallback
    find "$HOME/.var/app" "$HOME/.config" \
        -name "RetroAchievements.ini" 2>/dev/null | head -1
}

INI=$(find_ini) || true

if [[ -z "$INI" || ! -f "$INI" ]]; then
    echo ""
    warn "RetroAchievements.ini not found."
    echo "  • Open Dolphin → Settings → RetroAchievements"
    echo "  • Enable it and log in with your RA credentials"
    echo "  • Then re-run this installer"
    echo ""
    exit 1
fi

ok "Found ini: $INI"

# ── 4. detect EmuDeck / SRM ──────────────────────────────────────────────────
hdr "Detecting launcher setup"

HAVE_EMUDECK=false
HAVE_SRM=false
DOLPHIN_LAUNCHER=""

if [[ -d "$HOME/.config/EmuDeck" || -d "$HOME/EmuDeck" ]]; then
    HAVE_EMUDECK=true
    ok "EmuDeck detected"
    # Find the active dolphin launcher (prefer tools/launchers over roms/emulators)
    for p in \
        "$HOME/Emulation/tools/launchers/dolphin-emu.sh" \
        "$HOME/Emulation/roms/emulators/dolphin-emu.sh" \
        "$HOME/.config/EmuDeck/backend/tools/launchers/dolphin-emu.sh"
    do
        if [[ -f "$p" ]]; then
            DOLPHIN_LAUNCHER="$p"
            ok "Dolphin launcher: $DOLPHIN_LAUNCHER"
            break
        fi
    done
    [[ -n "$DOLPHIN_LAUNCHER" ]] || warn "EmuDeck found but dolphin-emu.sh not located — launcher injection skipped."
fi

if [[ -d "$HOME/.config/steam-rom-manager" ]]; then
    HAVE_SRM=true
    ok "Steam ROM Manager detected"
fi

if [[ "$HAVE_EMUDECK" == false && "$HAVE_SRM" == false ]]; then
    warn "No EmuDeck or SRM detected — timer-only + optional launch wrapper mode."
fi

# ── 5. install the refresh script ────────────────────────────────────────────
hdr "Installing refresh script → $REFRESH_SCRIPT"

cat > "$REFRESH_SCRIPT" <<'REFRESH_SCRIPT_EOF'
#!/usr/bin/env bash
# Refreshes the RetroAchievements ApiToken in Dolphin's ini.
# Credentials read from ~/.config/ra-creds (chmod 600).
set -euo pipefail

CREDS="$HOME/.config/ra-creds"
RA_HOST="retroachievements.org"
UA="ra-token-refresh/1.0 (Steam Deck; Dolphin)"

[[ -f "$CREDS" ]] || { echo "ERROR: $CREDS not found. Re-run install.sh." >&2; exit 1; }
# shellcheck source=/dev/null
source "$CREDS"
[[ -n "${RA_USER:-}" && -n "${RA_PASS:-}" ]] \
    || { echo "ERROR: RA_USER or RA_PASS missing in $CREDS." >&2; exit 1; }

# Locate ini — checked at runtime so it works after Dolphin layout changes
find_ini() {
    local candidates=(
        "$HOME/.var/app/org.DolphinEmu.dolphin-emu/config/dolphin-emu/RetroAchievements.ini"
        "$HOME/.var/app/net.retrodeck.retrodeck/config/dolphin-emu/RetroAchievements.ini"
        "$HOME/.config/dolphin-emu/RetroAchievements.ini"
    )
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    find "$HOME/.var/app" "$HOME/.config" -name "RetroAchievements.ini" 2>/dev/null | head -1
}

INI=$(find_ini) || true
if [[ -z "$INI" || ! -f "$INI" ]]; then
    echo "ERROR: RetroAchievements.ini not found." >&2
    echo "Open Dolphin → Settings → RetroAchievements, enable it, log in once, then retry." >&2
    exit 1
fi

# Wait up to 30 s for the RA server to be reachable
echo "Waiting for $RA_HOST..."
for i in $(seq 1 6); do
    if curl -sf --max-time 5 -o /dev/null "https://$RA_HOST/"; then
        break
    fi
    if [[ $i -eq 6 ]]; then
        echo "ERROR: $RA_HOST unreachable after 30 s." >&2
        exit 1
    fi
    sleep 5
done

# POST credentials; first try r=login, fall back to r=login2
fetch_token() {
    curl -fsS --max-time 15 \
        -A "$UA" \
        --data-urlencode "u=$RA_USER" \
        --data-urlencode "p=$RA_PASS" \
        -G "https://$RA_HOST/dorequest.php?r=$1"
}

RESPONSE=$(fetch_token "login" 2>/dev/null) || RESPONSE=""

if ! echo "$RESPONSE" | grep -q '"Success":true'; then
    echo "r=login did not succeed, trying r=login2..." >&2
    RESPONSE=$(fetch_token "login2" 2>/dev/null) || RESPONSE=""
fi

if ! echo "$RESPONSE" | grep -q '"Success":true'; then
    echo "ERROR: Both login attempts failed. Response: $RESPONSE" >&2
    exit 1
fi

# Parse Token value — safe for tokens containing +, /, = (no sed replacement issues)
TOKEN=$(echo "$RESPONSE" | awk -F'"Token":"' 'NF>1 { split($2, a, "\""); print a[1]; exit }')

if [[ -z "$TOKEN" ]]; then
    echo "ERROR: Could not extract Token from RA response: $RESPONSE" >&2
    exit 1
fi

# Write into ini using awk so +/= in the token value can't break anything
TMP=$(mktemp "${INI}.XXXXXX")
if grep -q '^ApiToken' "$INI"; then
    awk -v tok="$TOKEN" \
        '/^ApiToken[[:space:]]*=/ { print "ApiToken = " tok; next } { print }' \
        "$INI" > "$TMP"
else
    # Key not yet present — insert right after [Achievements]
    awk -v tok="$TOKEN" \
        '/^\[Achievements\]/ { print; print "ApiToken = " tok; next } { print }' \
        "$INI" > "$TMP"
fi
mv "$TMP" "$INI"

echo "Token refreshed for $RA_USER."
REFRESH_SCRIPT_EOF

chmod 755 "$REFRESH_SCRIPT"
ok "Refresh script installed"

# ── 6a. EmuDeck: guard script + launcher injection ───────────────────────────
if [[ "$HAVE_EMUDECK" == true ]]; then
    hdr "Installing EmuDeck launch-time guard"

    cat > "$GUARD_SCRIPT" <<'GUARD_SCRIPT_EOF'
#!/usr/bin/env bash
# Called by EmuDeck's dolphin-emu.sh right before Dolphin launches.
# If the ApiToken is missing, we try to refresh it now.
# We never block Dolphin — worst case is RA won't work that session.

find_ini() {
    local candidates=(
        "$HOME/.var/app/org.DolphinEmu.dolphin-emu/config/dolphin-emu/RetroAchievements.ini"
        "$HOME/.var/app/net.retrodeck.retrodeck/config/dolphin-emu/RetroAchievements.ini"
        "$HOME/.config/dolphin-emu/RetroAchievements.ini"
    )
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    find "$HOME/.var/app" "$HOME/.config" -name "RetroAchievements.ini" 2>/dev/null | head -1
}

INI=$(find_ini 2>/dev/null) || true
if [[ -z "$INI" || ! -f "$INI" ]]; then
    echo "[ra-fix] RetroAchievements.ini not found — skipping guard." >&2
    exit 0
fi

token_present() {
    local t
    t=$(awk -F'= ' '/^ApiToken[[:space:]]*=/ { print $2; exit }' "$INI" 2>/dev/null || true)
    [[ -n "$t" ]]
}

if ! token_present; then
    echo "[ra-fix] ApiToken missing — refreshing before launch..." >&2
    "$HOME/.local/bin/ra-token-refresh" >&2 || true
fi

if ! token_present; then
    echo "[ra-fix] Warning: still no ApiToken — RA achievements may not work this session." >&2
fi

exit 0
GUARD_SCRIPT_EOF

    chmod 755 "$GUARD_SCRIPT"
    ok "Guard script installed: $GUARD_SCRIPT"

    # Inject into the launcher (idempotent)
    if [[ -n "$DOLPHIN_LAUNCHER" ]]; then
        if grep -qF "$INJECT_MARKER" "$DOLPHIN_LAUNCHER"; then
            ok "Guard already injected into launcher (skipping)"
        else
            # Insert one line before the first 'flatpak run org.DolphinEmu' line
            TMP=$(mktemp)
            awk -v marker="$INJECT_MARKER" -v guard="$GUARD_SCRIPT" '
                !done && /flatpak run org\.DolphinEmu/ {
                    print "\"" guard "\" || true  " marker
                    done=1
                }
                { print }
            ' "$DOLPHIN_LAUNCHER" > "$TMP" && mv "$TMP" "$DOLPHIN_LAUNCHER"
            ok "Guard injected into $DOLPHIN_LAUNCHER"
        fi

        # Install re-injection service (fires at login to survive EmuDeck updates)
        cat > "$REINJECT_SCRIPT" <<REINJECT_EOF
#!/usr/bin/env bash
# Re-injects the ra-token-guard call into EmuDeck's dolphin-emu.sh
# if a EmuDeck update wiped it out. Run by ra-dolphin-guard.service at login.
set -euo pipefail

LAUNCHERS=(
    "$HOME/Emulation/tools/launchers/dolphin-emu.sh"
    "$HOME/Emulation/roms/emulators/dolphin-emu.sh"
)
INJECT_MARKER="$INJECT_MARKER"
GUARD="$GUARD_SCRIPT"

for LAUNCHER in "\${LAUNCHERS[@]}"; do
    [[ -f "\$LAUNCHER" ]] || continue
    if ! grep -qF "\$INJECT_MARKER" "\$LAUNCHER"; then
        TMP=\$(mktemp)
        awk -v marker="\$INJECT_MARKER" -v guard="\$GUARD" '
            !done && /flatpak run org\\.DolphinEmu/ {
                print "\\"" guard "\\" || true  " marker
                done=1
            }
            { print }
        ' "\$LAUNCHER" > "\$TMP" && mv "\$TMP" "\$LAUNCHER"
        echo "Re-injected guard into \$LAUNCHER"
    fi
done
REINJECT_EOF
        chmod 755 "$REINJECT_SCRIPT"

        cat > "$GUARD_SERVICE_FILE" <<GUARD_SVC_EOF
[Unit]
Description=Re-inject RA token guard into EmuDeck's dolphin-emu.sh if missing
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=$REINJECT_SCRIPT
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical-session.target
GUARD_SVC_EOF
        ok "Guard re-injection service installed"
    fi
fi

# ── 6b. No SRM and no EmuDeck: offer a launch wrapper ───────────────────────
WRAPPER_INSTALLED=false
if [[ "$HAVE_SRM" == false && "$HAVE_EMUDECK" == false ]]; then
    hdr "Launch wrapper (direct Dolphin users)"
    echo "Since you don't use Steam ROM Manager or EmuDeck, a thin wrapper"
    echo "can mint a fresh token at the exact moment you launch Dolphin."
    read -rp "Install launch wrapper at $WRAPPER_SCRIPT? [Y/n] " ans
    if [[ "${ans,,}" != "n" ]]; then
        # Detect how Dolphin is installed
        if flatpak list --app 2>/dev/null | grep -q "org.DolphinEmu.dolphin-emu"; then
            DOLPHIN_CMD="flatpak run org.DolphinEmu.dolphin-emu"
        elif command -v dolphin-emu &>/dev/null; then
            DOLPHIN_CMD="dolphin-emu"
        else
            DOLPHIN_CMD="flatpak run org.DolphinEmu.dolphin-emu"
            warn "Dolphin binary not detected; defaulting to Flatpak command."
        fi

        cat > "$WRAPPER_SCRIPT" <<WRAPPER_EOF
#!/usr/bin/env bash
# Refresh the RA token, then launch Dolphin with any arguments passed in.
"$REFRESH_SCRIPT" || true
exec $DOLPHIN_CMD "\$@"
WRAPPER_EOF
        chmod 755 "$WRAPPER_SCRIPT"
        WRAPPER_INSTALLED=true
        ok "Wrapper installed: $WRAPPER_SCRIPT"
        echo "  → Use '$WRAPPER_SCRIPT' (or 'dolphin-ra') instead of launching Dolphin directly."
    fi
fi

# ── 7. systemd service + timer ───────────────────────────────────────────────
hdr "Installing systemd timer"

# Tighter cadence when SRM/EmuDeck is managing launches (Game Mode boots cold)
if [[ "$HAVE_EMUDECK" == true || "$HAVE_SRM" == true ]]; then
    STARTUP_SEC=15
    ACTIVE_SEC=5min
    CADENCE_NOTE="every 5 min (tight cadence for Game Mode cold boots)"
else
    STARTUP_SEC=30
    ACTIVE_SEC=15min
    CADENCE_NOTE="every 15 min"
fi

cat > "$SERVICE_FILE" <<SERVICE_EOF
[Unit]
Description=Refresh RetroAchievements ApiToken for Dolphin
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$REFRESH_SCRIPT
StandardOutput=journal
StandardError=journal
SERVICE_EOF

cat > "$TIMER_FILE" <<TIMER_EOF
[Unit]
Description=Refresh RetroAchievements token ($CADENCE_NOTE)

[Timer]
OnStartupSec=${STARTUP_SEC}s
OnUnitActiveSec=${ACTIVE_SEC}
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

ok "Service: $SERVICE_FILE"
ok "Timer:   $TIMER_FILE (${CADENCE_NOTE})"

# ── 8. enable everything ─────────────────────────────────────────────────────
hdr "Enabling services"

systemctl --user daemon-reload

systemctl --user enable --now ra-token-refresh.timer
ok "Timer enabled and started"

if [[ "$HAVE_EMUDECK" == true && -n "$DOLPHIN_LAUNCHER" ]]; then
    systemctl --user enable ra-dolphin-guard.service
    ok "Guard re-injection service enabled"
fi

loginctl enable-linger "$(whoami)"
ok "loginctl enable-linger set — timer survives Desktop↔Game Mode switch"

# ── 9. live test ─────────────────────────────────────────────────────────────
hdr "Running live test"

echo "Attempting token refresh now..."
if "$REFRESH_SCRIPT"; then
    NEW_TOKEN=$(awk -F'= ' '/^ApiToken[[:space:]]*=/ { print $2; exit }' "$INI" 2>/dev/null || true)
    echo ""
    ok "SUCCESS — token is now in place."
    echo "  ApiToken = ${NEW_TOKEN:0:4}…${NEW_TOKEN: -4} (${#NEW_TOKEN} chars)"
else
    echo ""
    warn "The test run failed. Common reasons:"
    echo "  • Wrong username or password → re-run install.sh"
    echo "  • No internet at this moment → the timer will retry automatically"
    echo "  • retroachievements.org is down → try again later"
fi

# ── done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}─────────────────────────────────────────────${NC}"
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo ""
echo "What was installed:"
echo "  $REFRESH_SCRIPT   — token refresh script"
if [[ "$HAVE_EMUDECK" == true && -n "$DOLPHIN_LAUNCHER" ]]; then
    echo "  $GUARD_SCRIPT       — launch-time guard"
    echo "  $REINJECT_SCRIPT   — re-inject guard after EmuDeck updates"
fi
if [[ "$WRAPPER_INSTALLED" == true ]]; then
    echo "  $WRAPPER_SCRIPT      — Dolphin launch wrapper"
fi
echo "  ra-token-refresh.timer  — refreshes token $CADENCE_NOTE"
echo "  $CREDS              — credentials (chmod 600)"
echo ""
echo "To check timer status:  systemctl --user status ra-token-refresh.timer"
echo "To view logs:           journalctl --user -u ra-token-refresh.service"
echo "To uninstall:           bash uninstall.sh"
echo ""
