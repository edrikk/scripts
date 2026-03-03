#!/bin/sh

# --- Default Configuration ---
GITHUB_USER=""
GITHUB_REPO=""
GITHUB_BRANCH="main"
GITHUB_TOKEN=""
DEST_DIR="/etc/openwrt-scripts"
LOG_PREFIX=""
FILE_PREFIX=""
SCRIPTS=""

# --- Parameter Parsing ---
while [ "$#" -gt 0 ]; do
    case "$1" in
        --scripts|-s)
            shift; SCRIPTS="$1"
            ;;
        --dest|-d)
            shift; DEST_DIR="$1"
            ;;
        --prefix|-lp)
            shift; LOG_PREFIX="$1"
            ;;
        --file-prefix|-fp)
            shift; FILE_PREFIX="$1"
            ;;
        --gh-user|-ghu)
            shift; GITHUB_USER="$1"
            ;;
        --gh-repo|-ghr)
            shift; GITHUB_REPO="$1"
            ;;
        --gh-branch|-ghb)
            shift; GITHUB_BRANCH="$1"
            ;;
        --gh-token|-ght)
            shift; GITHUB_TOKEN="$1"
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

# Build Auth Header if token is provided
AUTH_HEADER=""
if [ -n "$GITHUB_TOKEN" ]; then
    # We store the flag and the value together
    AUTH_HEADER="--header=Authorization: token $GITHUB_TOKEN"
fi

GITHUB_RAW="https://raw.githubusercontent.com/$GITHUB_USER/$GITHUB_REPO/refs/heads/$GITHUB_BRANCH"

# --- Main Logic ---
if ! mkdir -p "$DEST_DIR"; then
    logger -t "$0" "${LOG_MSG_PREFIX}Error: Cannot create directory $DEST_DIR"
    exit 1
fi

TMP_DIR="/tmp/em-download"
mkdir -p "$TMP_DIR"

for SCRIPT in $SCRIPTS; do
    FILE_NAME="${SCRIPT##*/}"
    LOCAL_FILE="$DEST_DIR/${FILE_PREFIX}$FILE_NAME"
    ETAG_FILE="$DEST_DIR/${FILE_PREFIX}$FILE_NAME.etag"
    REMOTE_URL="$GITHUB_RAW/$SCRIPT"

    # 1. Get the Remote ETag (Quotes around AUTH_HEADER are mandatory)
    REMOTE_ETAG=$(wget -q "$AUTH_HEADER" --spider --server-response "$REMOTE_URL" 2>&1 | grep -i "etag:" | head -n1 | awk '{print $2}' | tr -d '"\r')

    # 2. Read the local ETag
    LOCAL_ETAG=""
    [ -f "$ETAG_FILE" ] && LOCAL_ETAG=$(cat "$ETAG_FILE")

    # 3. Compare and Act
    if [ -n "$REMOTE_ETAG" ] && [ "$REMOTE_ETAG" = "$LOCAL_ETAG" ] && [ -f "$LOCAL_FILE" ]; then
        logger -t "$0" "${LOG_MSG_PREFIX}${FILE_PREFIX}$FILE_NAME: Local and remote match. No action required."
    else
        TMP_FILE="$TMP_DIR/${FILE_PREFIX}$FILE_NAME.tmp"

        # 4. Download actual file (Quotes around AUTH_HEADER are mandatory)
        if wget -q "$AUTH_HEADER" -O "$TMP_FILE" "$REMOTE_URL"; then
            
            # Safety check: Ensure file is not empty
            if [ -s "$TMP_FILE" ]; then
                if mv "$TMP_FILE" "$LOCAL_FILE"; then
                    echo "$REMOTE_ETAG" > "$ETAG_FILE"
                    chmod +x "$LOCAL_FILE"
                    logger -t "$0" "${LOG_MSG_PREFIX}${FILE_PREFIX}$FILE_NAME: Local copy updated."
                else
                    logger -t "$0" "${LOG_MSG_PREFIX}${FILE_PREFIX}$FILE_NAME: Failed to move file to $LOCAL_FILE"
                    rm -f "$TMP_FILE"
                fi
            else
                logger -t "$0" "${LOG_MSG_PREFIX}${FILE_PREFIX}$FILE_NAME: Downloaded file is empty. Skipping."
                rm -f "$TMP_FILE"
            fi
        else
            logger -t "$0" "${LOG_MSG_PREFIX}${FILE_PREFIX}$FILE_NAME: Download failed (check token/path)."
            rm -f "$TMP_FILE"
        fi
    fi
done

rmdir "$TMP_DIR" 2>/dev/null
exit 0
