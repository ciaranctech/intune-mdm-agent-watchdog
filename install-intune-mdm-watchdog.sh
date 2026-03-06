#!/bin/bash
# shellcheck disable=SC2016

###############################################################################
# Script: install-intune-mdm-watchdog.sh
# Purpose:
#   Deploy an Intune-focused LaunchAgent + helper watchdog script that forces
#   Intune MDM agent restart/check-in behavior on:
#     - user login (RunAtLoad)
#     - reboot/login session start (LaunchAgent load)
#     - network state change (KeepAlive -> NetworkState)
#     - every 5 minutes (StartInterval)
#
# MDM Context:
#   Designed for Microsoft Intune shell script deployment (runs as root).
#
# Notes:
#   - This script installs files under /Library so the LaunchAgent is available
#     to all users.
#   - The helper script logs to terminal + local file.
###############################################################################

set -euo pipefail

SCRIPT_NAME="install-intune-mdm-watchdog"
LOG_ROOT="/Library/Application Support/Script Logs/intune-mdm-agent-watchdog"
LOG_FILE="$LOG_ROOT/${SCRIPT_NAME}.log"

AGENT_PLIST_PATH="/Library/LaunchAgents/com.company.intune-mdm-watchdog.plist"
HELPER_SCRIPT_PATH="/Library/Application Support/IntuneMdmWatchdog/restart-intune-mdm-agent.sh"
HELPER_DIR="$(dirname "$HELPER_SCRIPT_PATH")"

LAUNCH_AGENT_LABEL="com.company.intune-mdm-watchdog"
RUN_INTERVAL_SECONDS=300

# Candidate launchd labels for Intune-related agents on macOS.
# We try these in order and restart whichever exists.
INTUNE_LABEL_CANDIDATES=(
  "com.microsoft.intune.mdmagent"
  "com.microsoft.intuneMDMAgent"
  "com.microsoft.CompanyPortalMac.agent"
)

log() {
  local level="$1"
  shift
  local message="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S %z')"

  mkdir -p "$LOG_ROOT"
  printf '%s [%s] %s\n' "$ts" "$level" "$message" | tee -a "$LOG_FILE"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must run as root."
    exit 1
  fi
}

write_helper_script() {
  mkdir -p "$HELPER_DIR"

  cat > "$HELPER_SCRIPT_PATH" <<'EOF'
#!/bin/bash
set -euo pipefail

SCRIPT_NAME="restart-intune-mdm-agent"
LOG_ROOT="/Library/Application Support/Script Logs/intune-mdm-agent-watchdog"
LOG_FILE="$LOG_ROOT/${SCRIPT_NAME}.log"

INTUNE_LABEL_CANDIDATES=(
  "com.microsoft.intune.mdmagent"
  "com.microsoft.intuneMDMAgent"
  "com.microsoft.CompanyPortalMac.agent"
)

log() {
  local level="$1"
  shift
  local message="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S %z')"

  mkdir -p "$LOG_ROOT"
  printf '%s [%s] %s\n' "$ts" "$level" "$message" | tee -a "$LOG_FILE"
}

restart_label() {
  local domain_label="$1"

  if /bin/launchctl print "$domain_label" >/dev/null 2>&1; then
    # kickstart -k = kill running instance + start again.
    if /bin/launchctl kickstart -k "$domain_label" >/dev/null 2>&1; then
      log "INFO" "Restarted launchd service: $domain_label"
      return 0
    else
      log "WARN" "Found but failed to restart service via kickstart: $domain_label"
    fi
  fi

  return 1
}

restart_intune_agent() {
  local restarted=1

  for base_label in "${INTUNE_LABEL_CANDIDATES[@]}"; do
    if restart_label "system/${base_label}"; then
      restarted=0
      break
    fi

    # Some agents can run in GUI user domains. Attempt for current console user.
    local console_user
    console_user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"

    if [[ -n "$console_user" && "$console_user" != "root" ]]; then
      local uid
      uid="$(/usr/bin/id -u "$console_user" 2>/dev/null || true)"
      if [[ -n "$uid" ]] && restart_label "gui/${uid}/${base_label}"; then
        restarted=0
        break
      fi
    fi
  done

  if [[ "$restarted" -ne 0 ]]; then
    # Fallback: process-level bounce for known binary/process names.
    if /usr/bin/pkill -f "IntuneMdmAgent|IntuneMDMAgent|Company Portal" >/dev/null 2>&1; then
      log "WARN" "Used fallback process kill for Intune-related processes."
      restarted=0
    fi
  fi

  if [[ "$restarted" -eq 0 ]]; then
    log "INFO" "Intune restart/check-in trigger executed successfully."
  else
    log "ERROR" "No known Intune launchd label/process found to restart."
    exit 1
  fi
}

log "INFO" "Trigger received (network/load/interval). Running Intune restart workflow."
restart_intune_agent
EOF

  /bin/chmod 755 "$HELPER_SCRIPT_PATH"
  /usr/sbin/chown root:wheel "$HELPER_SCRIPT_PATH"

  log "INFO" "Installed helper script: $HELPER_SCRIPT_PATH"
}

write_launch_agent() {
  cat > "$AGENT_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>${HELPER_SCRIPT_PATH}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>StartInterval</key>
    <integer>${RUN_INTERVAL_SECONDS}</integer>

    <key>KeepAlive</key>
    <dict>
      <key>NetworkState</key>
      <true/>
    </dict>

    <key>StandardOutPath</key>
    <string>${LOG_ROOT}/launchagent.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_ROOT}/launchagent.err.log</string>
  </dict>
</plist>
EOF

  /bin/chmod 644 "$AGENT_PLIST_PATH"
  /usr/sbin/chown root:wheel "$AGENT_PLIST_PATH"

  log "INFO" "Installed LaunchAgent plist: $AGENT_PLIST_PATH"
}

reload_for_logged_in_users() {
  # Try to unload/load for currently logged-in Aqua users so policy applies now,
  # while still naturally applying on next login/reboot.
  while IFS= read -r user; do
    [[ -z "$user" || "$user" == "root" ]] && continue

    local uid
    uid="$(/usr/bin/id -u "$user" 2>/dev/null || true)"
    [[ -z "$uid" ]] && continue

    /bin/launchctl bootout "gui/${uid}" "$AGENT_PLIST_PATH" >/dev/null 2>&1 || true
    if /bin/launchctl bootstrap "gui/${uid}" "$AGENT_PLIST_PATH" >/dev/null 2>&1; then
      /bin/launchctl kickstart -k "gui/${uid}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1 || true
      log "INFO" "Loaded LaunchAgent for user '${user}' (uid ${uid})."
    else
      log "WARN" "Could not load LaunchAgent for user '${user}' (uid ${uid})."
    fi
  done < <(/usr/bin/who | /usr/bin/awk '$2 == "console" {print $1}' | /usr/bin/sort -u)
}

main() {
  require_root
  log "INFO" "Starting Intune MDM watchdog install."

  /bin/mkdir -p "$LOG_ROOT"
  /usr/sbin/chown -R root:wheel "$LOG_ROOT"
  /bin/chmod 755 "$LOG_ROOT"

  write_helper_script
  write_launch_agent
  reload_for_logged_in_users

  log "INFO" "Install complete. Triggers active: RunAtLoad, NetworkState, StartInterval=${RUN_INTERVAL_SECONDS}s."
}

main "$@"
