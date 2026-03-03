#!/bin/sh

# Default values
LOG_PREFIX=""
CUSTOM_EXT=""

# --- Fixed Argument Parsing ---
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix|-p)
            shift; LOG_PREFIX="$1"
            ;;
        -prefix=*)
            LOG_PREFIX="${1#*=}"
            ;;
        --ext|-e)
            shift; CUSTOM_EXT="$1"
            ;;
        -ext=*)
            CUSTOM_EXT="${1#*=}"
            ;;
    esac
    shift
done

# Prepare prefix for logger message
LOG_MSG_PREFIX=""
if [ -n "$LOG_PREFIX" ]; then
    LOG_MSG_PREFIX="${LOG_PREFIX} - "
fi

SCRIPT_NAME=$(basename "$0" .sh)
HOSTS_DIR="/tmp/hosts"
mkdir -p "$HOSTS_DIR"

HOSTS_FILE="${HOSTS_DIR}/${SCRIPT_NAME}.hosts"
TMP_FILE="/tmp/${SCRIPT_NAME}.tmp"
SORTED_TMP_FILE="/tmp/${SCRIPT_NAME}.sorted"

# Header
echo "# Auto-generated from umdns by $SCRIPT_NAME" > "$TMP_FILE"

# --- PART 1: Process mDNS devices ---
# Extracting data using a more robust awk state machine
ubus call umdns browse | awk -v ext="$CUSTOM_EXT" '
    /"host":/ { gsub(/[",]/, "", $2); sub(/\.local$/, "", $2); host=$2 }
    /"ipv4":/ { 
        gsub(/[",]/, "", $2); ip=$2;
        if (host != "" && host != "localhost" && ip != "" && length(host) < 30) {
            line = ip "\t" host ".local\t" host;
            if (ext != "") { line = line "\t" host "." ext; }
            print line;
            host=""; ip=""; # Reset to prevent accidental duplicates
        }
    }
' >> "$TMP_FILE"

# --- PART 2: Add AP's Own Name and Address ---
AP_NAME=$(uci -q get system.@system[0].hostname)
# Using jsonfilter is best on OpenWrt
AP_IP=$(ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address')

if [ -n "$AP_NAME" ] && [ -n "$AP_IP" ]; then
    local_line="$AP_IP\t$AP_NAME.local\t$AP_NAME"
    [ -n "$CUSTOM_EXT" ] && local_line="$local_line\t$AP_NAME.$CUSTOM_EXT"
    echo -e "$local_line" >> "$TMP_FILE"
fi

# --- PART 3: Finalize and Check for Changes ---
sort -u "$TMP_FILE" > "$SORTED_TMP_FILE"

if [ ! -f "$HOSTS_FILE" ] || ! cmp -s "$HOSTS_FILE" "$SORTED_TMP_FILE"; then
    logger -t "$SCRIPT_NAME" "${LOG_MSG_PREFIX}Changes detected. Updating $HOSTS_FILE and reloading dnsmasq."
    mv "$SORTED_TMP_FILE" "$HOSTS_FILE"
    /etc/init.d/dnsmasq reload
else
    logger -t "$SCRIPT_NAME" "${LOG_MSG_PREFIX}No changes detected."
    rm -f "$SORTED_TMP_FILE"
fi

rm -f "$TMP_FILE"
exit 0
