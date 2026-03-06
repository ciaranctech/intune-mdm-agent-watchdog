#!/bin/bash
set -euo pipefail

SCRIPT_NAME="uninstall-intune-mdm-watchdog"
LOG_ROOT="/Library/Application Support/Script Logs/intune-mdm-agent-watchdog"
LOG_FILE="$LOG_ROOT/${SCRIPT_NAME}.log"

AGENT_PLIST_PATH="/Library/LaunchAgents/com.company.intune-mdm-watchdog.plist"
HELPER_SCRIPT_PATH="/Library/Application Support/IntuneMdmWatchdog/restart-intune-mdm-agent.sh"
HELPER_DIR="$(dirname "$HELPER_SCRIPT_PATH")"
LAUNCH_AGENT_LABEL="com.company.intune-mdm-watchdog"

log() {
  local level="$1"
  shift
  local message="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S %z')"
  mkdir -p "$LOG_ROOT"
  printf '%s [%s] %s\n' "$ts" "$level" "$message" | tee -a "$LOG_FILE"
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must run as root."
  exit 1
fi

while IFS= read -r user; do
  [[ -z "$user" || "$user" == "root" ]] && continue
  uid="$(/usr/bin/id -u "$user" 2>/dev/null || true)"
  [[ -z "$uid" ]] && continue
  /bin/launchctl bootout "gui/${uid}" "$AGENT_PLIST_PATH" >/dev/null 2>&1 || true
  /bin/launchctl disable "gui/${uid}/${LAUNCH_AGENT_LABEL}" >/dev/null 2>&1 || true
  log "INFO" "Unloaded LaunchAgent for user '${user}' (uid ${uid})."
done < <(/usr/bin/who | /usr/bin/awk '$2 == "console" {print $1}' | /usr/bin/sort -u)

/bin/rm -f "$AGENT_PLIST_PATH"
/bin/rm -f "$HELPER_SCRIPT_PATH"
/bin/rmdir "$HELPER_DIR" >/dev/null 2>&1 || true

log "INFO" "Removed files and unloaded Intune watchdog LaunchAgent."
