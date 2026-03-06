# Intune MDM Agent Watchdog (macOS)

Deploy a LaunchAgent-based watchdog via **Microsoft Intune** that forces Intune agent restart/check-in triggers on:

- user login (`RunAtLoad`)
- reboot/session load (`RunAtLoad` when agent loads)
- network state changes (`KeepAlive -> NetworkState`)
- every 5 minutes (`StartInterval = 300`)

---

## Files

- `install-intune-mdm-watchdog.sh`
  - Installs helper script + LaunchAgent
  - Loads LaunchAgent for currently logged-in users
- `uninstall-intune-mdm-watchdog.sh`
  - Unloads and removes installed components

Installed artifacts:

- `/Library/LaunchAgents/com.company.intune-mdm-watchdog.plist`
- `/Library/Application Support/IntuneMdmWatchdog/restart-intune-mdm-agent.sh`
- Logs: `/Library/Application Support/Script Logs/intune-mdm-agent-watchdog/`

---

## Intune Deployment

1. In Intune, create a **macOS Shell Script** policy.
2. Upload `install-intune-mdm-watchdog.sh`.
3. Run as signed-in user: **No** (run as root).
4. Assign to target macOS devices.

---

## How It Works

The helper script tries restart in this order:

1. `launchctl kickstart -k system/<label>` for known Intune labels
2. `launchctl kickstart -k gui/<uid>/<label>` for active console user
3. Fallback `pkill -f` for Intune-related process names

Current candidate labels:

- `com.microsoft.intune.mdmagent`
- `com.microsoft.intuneMDMAgent`
- `com.microsoft.CompanyPortalMac.agent`

If your environment uses a different label, update `INTUNE_LABEL_CANDIDATES` in both scripts.

---

## Logging

Both install/helper scripts implement a logging function that writes to:

- terminal output
- file under `/Library/Application Support/Script Logs/intune-mdm-agent-watchdog/`

---

## Validation Commands (on target Mac)

```bash
# Check LaunchAgent file
ls -l /Library/LaunchAgents/com.company.intune-mdm-watchdog.plist

# Check helper script
ls -l "/Library/Application Support/IntuneMdmWatchdog/restart-intune-mdm-agent.sh"

# Review logs
tail -n 100 "/Library/Application Support/Script Logs/intune-mdm-agent-watchdog/install-intune-mdm-watchdog.log"
tail -n 100 "/Library/Application Support/Script Logs/intune-mdm-agent-watchdog/restart-intune-mdm-agent.log"

# For a logged-in user session, check if loaded (replace UID)
launchctl print gui/$(id -u)/com.company.intune-mdm-watchdog
```

---

## Rollback

Deploy `uninstall-intune-mdm-watchdog.sh` via Intune to remove the LaunchAgent and helper script.

---

## Notes / Guardrails

- Use with caution in production: frequent forced restarts can increase logs/noise.
- Recommended to pilot with a small test group first.
- Confirm exact Intune launchd label(s) in your estate and trim candidates accordingly.
