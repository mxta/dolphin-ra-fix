# RetroAchievements Token Keeper for Dolphin (Steam Deck)

Fixes a Dolphin bug where your RetroAchievements login disappears every time
you switch between Desktop Mode and Game Mode.

---

## The bug

Dolphin stores your RA login token in a file called `RetroAchievements.ini`.
When Dolphin starts and can't immediately reach the RA servers — which happens
routinely during a Game Mode boot, before the network is fully up — it deletes
the token from that file. Your username stays, but the token is gone. Result:
Dolphin asks you to log in again, or silently stops tracking achievements.

## The fix

A small background job (a "systemd timer") runs on your Deck every few minutes
and writes a fresh token into the ini file, independently of how or when
Dolphin launches. If you use EmuDeck, a one-line hook is also added to the
Dolphin launcher so a token is guaranteed the moment a game starts.

Your credentials are stored in a private file that only your account can read.
Nothing phones home, nothing is uploaded anywhere.

---

## Requirements

- Steam Deck (SteamOS) — or any Linux system with `systemctl`, `curl`, and
  either Flatpak Dolphin or native Dolphin
- Dolphin must have been opened and logged into RetroAchievements at least once
  (so the ini file exists)
- Internet connection during install (for the test run)

---

## Install

Open **Konsole** (search for it in the app drawer in Desktop Mode) and run:

```bash
cd ~/ra-fix
bash install.sh
```

The script will:

1. Ask for your RetroAchievements username and password (password is hidden as
   you type)
2. Find Dolphin's config file automatically
3. Detect whether you use EmuDeck / Steam ROM Manager or launch Dolphin directly
4. Install a background refresh job that runs every few minutes
5. If EmuDeck is detected: add a hook to the Dolphin launcher so a fresh token
    is in place before any game starts
6. If you launch Dolphin directly: offer to install a thin wrapper that refreshes
    the token at launch time
7. Run a live test and tell you whether it worked

It is safe to run more than once — it will not duplicate anything.

---

## Uninstall

```bash
cd ~/ra-fix
bash uninstall.sh
```

This removes all scripts, systemd units, and the EmuDeck launcher hook. It will
ask before deleting your stored credentials.

---

## How often does it refresh?

| Setup | Startup delay | Refresh interval |
|---|---|---|
| EmuDeck or Steam ROM Manager | 15 seconds after login | Every 5 minutes |
| Direct Dolphin launch | 30 seconds after login | Every 15 minutes |

The shorter interval for EmuDeck/SRM users means a fresh token is already in
the ini file by the time Game Mode finishes booting and you pick a game.

---

## Check that it's running

```bash
systemctl --user status ra-token-refresh.timer
```

To see recent refresh log entries:

```bash
journalctl --user -u ra-token-refresh.service --no-pager -n 20
```

---

## Troubleshooting

**"RetroAchievements.ini not found"**
Open Dolphin → Settings → RetroAchievements, enable it, and log in once.
Then re-run `install.sh`.

**"Both login attempts failed"**
Double-check your username and password on the
[RetroAchievements website](https://retroachievements.org). Then re-run
`install.sh` to update the stored credentials.

**Token refreshes but achievements still don't unlock**
Make sure Hardcore Mode / the achievement set you want is enabled inside
Dolphin's RetroAchievements settings. This tool only keeps your login alive —
the game and achievement settings are separate.

**EmuDeck updated and the hook disappeared**
The `ra-dolphin-guard.service` handles this automatically. It runs at every
login and re-adds the hook if EmuDeck removed it. You can trigger it manually:

```bash
systemctl --user start ra-dolphin-guard.service
```

---

## Files installed

| Path | Purpose |
|---|---|
| `~/.config/ra-creds` | Your RA credentials (private, readable only by you) |
| `~/.local/bin/ra-token-refresh` | The refresh script |
| `~/.local/bin/ra-token-guard` | Launch-time guard (EmuDeck only) |
| `~/.local/bin/ra-dolphin-reinject` | Re-adds the hook after EmuDeck updates (EmuDeck only) |
| `~/.local/bin/dolphin-ra` | Launch wrapper (direct-launch users only, if requested) |
| `~/.config/systemd/user/ra-token-refresh.service` | Systemd service |
| `~/.config/systemd/user/ra-token-refresh.timer` | Systemd timer |
| `~/.config/systemd/user/ra-dolphin-guard.service` | Hook re-injection service (EmuDeck only) |
