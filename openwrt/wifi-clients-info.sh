#!/bin/sh
# Source: https://forum.openwrt.org/t/802-11r-fast-transition-how-to-understand-that-ft-works/110920/229

HOSTAPD_DIR="/var/run/hostapd"

show_help() {
Usage: $(basename "$0") [OPTIONS]

Displays WiFi station information including:
 - Hostname / IP / MAC
 - WiFi generation
 - WPA protocol / FT / WPA3
 - Cipher

Options:
  -s, --sort    Sort stations alphabetically
  -l, --local   Skip ARP/DNS lookup
  -h, --help    Show help
exit 0
}

[ -d "$HOSTAPD_DIR" ] || { echo "Error: $HOSTAPD_DIR not found."; exit 1; }
command -v hostapd_cli >/dev/null 2>&1 || { echo "Error: hostapd_cli not installed."; exit 1; }

SORT=false
LOCAL_ONLY=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        -s|--sort) SORT=true ;;
        -l|--local) LOCAL_ONLY=true ;;
        -h|--help) show_help ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

echo "=================================================================================================="
echo "STATION DETAILS BY INTERFACE (v17 - Final)"
printf "Sorting: %s | Mode: %s\n" \
    "$( [ "$SORT" = true ] && echo "Enabled" || echo "Disabled" )" \
    "$( [ "$LOCAL_ONLY" = true ] && echo "Local (DHCP/UCI)" || echo "Full (ARP/DNS)" )"
echo "=================================================================================================="

cd "$HOSTAPD_DIR" || exit 1

for socket in *; do
    [ -S "$socket" ] || continue
    [ "$socket" = "global" ] && continue

    status="$(hostapd_cli -i "$socket" status 2>/dev/null)"
    ssid="$(hostapd_cli -i "$socket" get_config 2>/dev/null | sed -n 's/^ssid=//p' | head -n1)"
    [ -z "$ssid" ] && ssid="$(echo "$status" | sed -n 's/^ssid=//p' | head -n1)"

    channel="$(echo "$status" | sed -n 's/^channel=//p' | head -n1)"
    freq="$(echo "$status" | sed -n 's/^freq=//p' | head -n1)"

    printf "\n[ IF: %s | SSID: %s | Channel: %s (%s MHz) ]\n" \
        "$socket" "${ssid:-?}" "${channel:-?}" "${freq:-?}"
    echo "--------------------------------------------------------------------------------------------------"

    stations="$(hostapd_cli -i "$socket" list_sta)"
    [ -z "$stations" ] && { echo "  (No stations connected)"; continue; }

    output=""

    for assoc in $stations; do
        sta_info="$(hostapd_cli -i "$socket" sta "$assoc" 2>/dev/null)"
        [ -z "$sta_info" ] && continue

        u_ip=""
        u_name=""

        if [ -f /tmp/dhcp.leases ]; then
            lease_line="$(awk -v mac="$assoc" 'tolower($2)==tolower(mac){print;exit}' /tmp/dhcp.leases)"
            if [ -n "$lease_line" ]; then
                u_ip="$(echo "$lease_line" | awk '{print $3}')"
                u_name="$(echo "$lease_line" | awk '{print $4}')"
            fi
        fi

        if [ -z "$u_ip" ]; then
            cfg_sec="$(uci show dhcp 2>/dev/null | awk -F'[.=]' -v mac="$assoc" 'tolower($3)=="mac" && tolower($NF)==tolower(mac){print $2;exit}')"
            if [ -n "$cfg_sec" ]; then
                u_ip="$(uci get dhcp.$cfg_sec.ip 2>/dev/null)"
                u_name="$(uci get dhcp.$cfg_sec.name 2>/dev/null)"
            fi
        fi

        if [ "$LOCAL_ONLY" = false ] && [ -z "$u_ip" ]; then
            u_ip="$(ip neigh show | awk -v mac="$assoc" 'tolower($0)~tolower(mac){print $1;exit}')"
            if [ -n "$u_ip" ]; then
                u_name="$(nslookup "$u_ip" 2>/dev/null | awk -F'= ' '/name =/ {print $2}' | sed 's/\.$//' | cut -d'.' -f1)"
            fi
        fi

        if [ -n "$u_name" ] && [ -n "$u_ip" ]; then
            display="$u_name ($u_ip)"
        elif [ -n "$u_name" ]; then
            display="$u_name"
        elif [ -n "$u_ip" ]; then
            display="$u_ip"
        else
            display="$assoc"
        fi

        if echo "$sta_info" | grep -qiE "EHT-CAP|EHT_CAP"; then
            wifi="Wi-Fi 7"
        elif echo "$sta_info" | grep -qiE "HE-CAP|HE_CAP"; then
            wifi="Wi-Fi 6"
        elif echo "$sta_info" | grep -qiE "VHT-CAP|VHT_CAP"; then
            wifi="Wi-Fi 5"
        elif echo "$sta_info" | grep -qiE "HT-CAP|HT_CAP"; then
            wifi="Wi-Fi 4"
        else
            wifi="Legacy"
        fi

        suite="$(echo "$sta_info" | awk -F= '/AKMSuiteSelector/{print $2;exit}' | awk '{print $1}')"
        cipher_hex="$(echo "$sta_info" | awk -F= '/dot11RSNAStatsSelectedPairwiseCipher/{print $2;exit}')"
        wpa_ver="$(echo "$sta_info" | awk -F= '/^wpa=/{print $2;exit}')"

        case "$suite" in
            00-0f-ac-1) akm="802.1X" ;;
            00-0f-ac-2) akm="PSK" ;;
            00-0f-ac-3) akm="FT-802.1X" ;;
            00-0f-ac-4) akm="FT-PSK" ;;
            00-0f-ac-8) akm="SAE" ;;
            00-0f-ac-9) akm="FT-SAE" ;;
            00-0f-ac-18) akm="OWE" ;;
            *) akm="${suite:-Unknown}" ;;
        esac

        case "$cipher_hex" in
            00-0f-ac-4) cipher="CCMP-128" ;;
            00-0f-ac-10) cipher="CCMP-256" ;;
            00-0f-ac-8) cipher="GCMP-128" ;;
            00-0f-ac-9) cipher="GCMP-256" ;;
            *) cipher="AES/Other" ;;
        esac

        case "$suite" in
            00-0f-ac-8|00-0f-ac-9|00-0f-ac-18) proto="WPA3" ;;
            *) [ "$wpa_ver" = "2" ] && proto="WPA2" || proto="WPA/Legacy" ;;
        esac

        line="$(printf "  STA: %-32s | %-8s | %-4s (%-8s) | %-12s" "$display" "$wifi" "$proto" "$akm" "$cipher")"
        output="${output}${line}\n"
    done

    if [ "$SORT" = true ]; then
        printf "%b" "$output" | LC_ALL=C sort -i
    else
        printf "%b" "$output"
    fi
done

echo "=================================================================================================="
