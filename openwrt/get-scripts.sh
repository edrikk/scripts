#!/bin/sh

# --- Default Configuration ---
GITHUB_USER=""
GITHUB_REPO=""
GITHUB_BRANCH="main"
DEST_DIR="/etc/openwrt-scripts"
LOG_PREFIX=""
FILE_PREFIX="" 
SCRIPTS=""

# --- Parameter Parsing ---
while [ "$#" -gt 0 ]; do
    case "$1" in
        --scripts|-s)
            shift
            SCRIPTS="$1"
            ;;
        --dest|-d)
            shift
            DEST_DIR="$1"
            ;;
        --prefix|-lp)
            shift
            LOG_PREFIX="$1"
            ;;
        --file-prefix|-fp) 
            shift
            FILE_PREFIX="$1"
            ;;
        --gh-user|-ghu) 
            shift
            GITHUB_USER="$1"
            ;;
        --gh-repo|-ghr) 
            shift
            GITHUB_REPO="$1"
            ;;
        --gh-branch|-ghb) 
            shift
            GITHUB_BRANCH="$1"
            ;;
        *)
            logger -t "$0" "Unknown parameter: $1"                
            exit 1
            ;;
    esac
    shift
done

# Prepare prefix for logger message
LOG_MSG_PREFIX=""
if [ -n "$LOG_PREFIX" ]; then
    LOG_MSG_PREFIX="${LOG_PREFIX} - "
fi

# --- Validation ---
if [ -z "$SCRIPTS" ]; then
    logger -t "$0" "${LOG_MSG_PREFIX}No scripts specified."
    exit 1
fi

GITHUB_RAW="https://raw.githubusercontent.com/$GITHUB_USER/$GITHUB_REPO/refs/heads/$GITHUB_BRANCH"

# --- Main Logic ---
if ! mkdir -p "$DEST_DIR"; then
    logger -t "$0" "${LOG_MSG_PREFIX}Error: Cannot create directory $DEST_DIR"
    exit 1
fi

# --- FIX: Create a dedicated temp directory in RAM ---
TMP_DIR="/tmp/em-download"
mkdir -p "$TMP_DIR"
# ----------------------------------------------------

for SCRIPT in $SCRIPTS; do
    # Extract just the filename from the path (e.g., "mdns-to-dns.sh" from "openwrt/mdns-to-dns.sh")
    FILE_NAME="${SCRIPT##*/}"
    
    # Apply FILE_PREFIX to the local filename
    LOCAL_FILE="$DEST_DIR/${FILE_PREFIX}$FILE_NAME"
    ETAG_FILE="$DEST_DIR/${FILE_PREFIX}$FILE_NAME.etag"
    REMOTE_URL="$GITHUB_RAW/$SCRIPT"

    # 1. Get the Remote ETag using a HEAD request
    REMOTE_ETAG=$(wget -q --spider --server-response "$REMOTE_URL" 2>&1 | grep -i "etag:" | head -n1 | awk '{print $2}' | tr -d '"\r')

    # 2. Read the local ETag (if it exists)
    LOCAL_ETAG=""
    [ -f "$ETAG_FILE" ] && LOCAL_ETAG=$(cat "$ETAG_FILE")

    # 3. Compare and Act
    if [ -n "$REMOTE_ETAG" ] && [ "$REMOTE_ETAG" = "$LOCAL_ETAG" ] && [ -f "$LOCAL_FILE" ]; then
        logger -t "$0" "${LOG_MSG_PREFIX}${FILE_PREFIX}$FILE_NAME: Local and remote match. No action required."
    else
        # --- FIX: Use dedicated TMP_DIR and file name only ---
        TMP_FILE="$TMP_DIR/${FILE_PREFIX}$FILE_NAME.tmp"
        
        # Download actual file to RAM
        if wget -q -O "$TMP_FILE" "$REMOTE_URL"; then
            # Atomic move to flash
            if mv "$TMP_FILE" "$LOCAL_FILE"; then
                echo "$REMOTE_ETAG" > "$ETAG_FILE"
                chmod +x "$LOCAL_FILE"
                logger -t "$0" "${LOG_MSG_PREFIX}${FILE_PREFIX}$FILE_NAME: Local copy updated."
            else
                logger -t "$0" "${LOG_MSG_PREFIX}${FILE_PREFIX}$FILE_NAME: Failed to move file to $LOCAL_FILE"
                rm -f "$TMP_FILE"
            fi
        else
            logger -t "$0" "${LOG_MSG_PREFIX}${FILE_PREFIX}$FILE_NAME: Local copy update error (Download failed)."
            rm -f "$TMP_FILE"
        fi
    fi
done

rmdir "$TMP_DIR" 2>/dev/null
exit 0
