#!/bin/sh

# Default values
LOG_PREFIX=""
CUSTOM_EXT=""

# --- Argument Parsing (Order Independent) ---
for arg in "$@"; do
  case $arg in
    -prefix=*)
      LOG_PREFIX="${arg#*=}"
      ;;
    -ext=*)
      CUSTOM_EXT="${arg#*=}"
      ;;
  esac
done

# Prepare prefix for logger message
LOG_MSG_PREFIX=""
if [ -n "$LOG_PREFIX" ]; then
    LOG_MSG_PREFIX="${LOG_PREFIX} - "
fi

# Dynamically set filenames based on the script name
SCRIPT_NAME=$(basename "$0" .sh)
HOSTS_DIR="/tmp/hosts"
# Ensure directory exists
mkdir -p "$HOSTS_DIR"

# Filename for the custom hosts file
HOSTS_FILE="${HOSTS_DIR}/${SCRIPT_NAME}.hosts"
# CHANGED: Temporary file now in /tmp/
TMP_FILE="/tmp/${SCRIPT_NAME}.tmp"
SORTED_TMP_FILE="/tmp/${SCRIPT_NAME}.sorted"

# Initialize temporary file
echo "# Auto-generated from umdns by $SCRIPT_NAME" > $TMP_FILE

# --- PART 1: Process mDNS devices ---
# Use ubus call and parse with awk to handle multi-line structure
ubus call umdns browse | awk -v ext="$CUSTOM_EXT" '
  /"host":/ {
    gsub(/"|,/, "", $2);
    # Strip ".local" from the end of the hostname if it exists
    sub(/\.local$/, "", $2);
    host=$2
  }
  /"ipv4":/ {
    gsub(/"|,/, "", $2);
    ip=$2;
    # FILTER: Exclude localhost, empty names, or overly long names
    if (host != "" && host != "localhost" && host != "localhost.local" && ip != "" && length(host) < 30) {

      # Build the line: IP Hostname.local Hostname Hostname.custom
      # 1. ALWAYS OUTPUT .local FORMAT
      line = ip "\t" host ".local";

      # 2. ALSO OUTPUT RAW HOSTNAME (No suffix)
      line = line "\t" host;

      # 3. OPTIONALLY OUTPUT CUSTOM EXTENSION FORMAT
      if (ext != "") {
        line = line "\t" host "." ext;
      }

      print line;

      host=""; ip=""
    }
  }
' >> $TMP_FILE

# --- PART 2: Add AP's Own Name and Address ---
# Get current hostname
AP_NAME=$(uci get system.@system[0].hostname 2>/dev/null)
# Get IP address directly from network subsystem
AP_IP=$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address')

if [ -n "$AP_NAME" ] && [ -n "$AP_IP" ]; then
    # Add local AP entry with similar formatting
    local_line="$AP_IP\t$AP_NAME.local\t$AP_NAME"
    if [ -n "$CUSTOM_EXT" ]; then
        local_line="$local_line\t$AP_NAME.$CUSTOM_EXT"
    fi
    echo -e "$local_line" >> $TMP_FILE
fi

# --- PART 3: Finalize and Check for Changes ---
# Sort and create the new candidate file
sort -u $TMP_FILE > "$SORTED_TMP_FILE"

# Check if file exists and compare with the new sorted output
if [ ! -f "$HOSTS_FILE" ] || ! cmp -s "$HOSTS_FILE" "$SORTED_TMP_FILE"; then
    logger -t "$0" "${LOG_MSG_PREFIX}mDNS Hosts: Changes detected. Updating $HOSTS_FILE and reloading dnsmasq."
    mv "$SORTED_TMP_FILE" "$HOSTS_FILE"
    # FORCE DNSMASQ TO RELOAD HOSTS FILES
    /etc/init.d/dnsmasq reload
else
    logger -t "$0" "${LOG_MSG_PREFIX}mDNS Hosts: No changes detected."
    rm "$SORTED_TMP_FILE"
fi

# Remove the temporary file
rm $TMP_FILE
