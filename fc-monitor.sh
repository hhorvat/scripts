#!/usr/bin/env bash

# =============================================================================
# FC SAN Traffic Monitor 
#
# Script version: 8.2
# Tested on: Proxmox VE 9.1.x  
# License: CC BY SA 4
# Author: Hrvoje Horvat
#
# Description:
#   Real-time Fibre Channel (FC) monitoring script for Linux systems.
#
#   This script provides a unified view of:
#     - FC host throughput (TX/RX in MB/s and Gbps)
#     - Total aggregated FC throughput across all HBAs
#     - Link speed per HBA
#     - ALUA path state (AO / ANO)
#     - Multipath priority and device mapping
#     - Multipath health (path checker state)
#     - Per-path IOPS
#     - Host → SCSI device correlation
#
# Data sources:
#   - /sys/class/fc_host               (FC HBA statistics)
#   - /sys/block/sdX/device            (ALUA access state)
#   - multipathd show paths            (multipath topology and health)
#
# Key concepts:
#
#   MP Health (checker state):
#     -> Indicates whether the path is alive and usable
#
#   ALUA state:
#     -> Indicates whether the path is optimal
#
#   Example:
#     chk=active + [ANO]
#       = path works but is non-optimal
#
# Usage:
#   chmod +x fc-monitor.sh
#   ./fc-monitor.sh
#
# =============================================================================

INTERVAL=5
WORD_SIZE=4   # FC word = 4 bytes

declare -A TX_PREV
declare -A RX_PREV
declare -A SPEED

declare -A PRIO_MAP
declare -A MPATH_STATUS
declare -A CHECKER_STATE

declare -A IO_PREV

trap 'tput sgr0; tput cnorm; echo; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Load multipath path information
# -----------------------------------------------------------------------------
load_multipath_map() {
    PRIO_MAP=()
    MPATH_STATUS=()
    CHECKER_STATE=()

    while read -r dev prio dmstat chk; do
        [[ -z "$dev" ]] && continue

        PRIO_MAP["$dev"]="$prio"
        MPATH_STATUS["$dev"]="$dmstat"
        CHECKER_STATE["$dev"]="$chk"
    done < <(
        multipathd show paths format "%d %p %s %t" 2>/dev/null | awk 'NR>1'
    )
}

# -----------------------------------------------------------------------------
# Initial FC counters
# -----------------------------------------------------------------------------
for h in /sys/class/fc_host/host*; do
    host=$(basename "$h")

    TX_PREV[$host]=$(cat "$h/statistics/tx_words" 2>/dev/null || echo 0)
    RX_PREV[$host]=$(cat "$h/statistics/rx_words" 2>/dev/null || echo 0)

    spd=$(cat "$h/speed" 2>/dev/null || echo 0)
    SPEED[$host]=${spd//[^0-9]/}
done

# -----------------------------------------------------------------------------
# Initial disk I/O counters
# -----------------------------------------------------------------------------
for sd in /sys/block/sd*; do
    dev=$(basename "$sd")

    [[ -f "$sd/stat" ]] || continue

    read r _ _ _ w _ _ _ _ < "$sd/stat"
    IO_PREV[$dev]=$((r+w))
done

tput civis

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------
while true; do
    load_multipath_map
    clear

    # Total FC throughput counters
    TOTAL_TX_DELTA=0
    TOTAL_RX_DELTA=0

    echo "===================================================================================================="
    printf "%-8s %-8s %26s %26s %10s\n" \
        "HOST" "STATE" "TX (MB/s / Gbps)" "RX (MB/s / Gbps)" "LINK"
    echo "===================================================================================================="

    # -------------------------------------------------------------------------
    # Iterate through FC hosts
    # -------------------------------------------------------------------------
    for h in /sys/class/fc_host/host*; do

        host=$(basename "$h")
        hnum=${host//host/}
        speed=${SPEED[$host]:-0}

        tx_now=$(cat "$h/statistics/tx_words" 2>/dev/null || echo 0)
        rx_now=$(cat "$h/statistics/rx_words" 2>/dev/null || echo 0)

        tx_delta=$((tx_now - TX_PREV[$host]))
        rx_delta=$((rx_now - RX_PREV[$host]))

        # Aggregate totals
        TOTAL_TX_DELTA=$((TOTAL_TX_DELTA + tx_delta))
        TOTAL_RX_DELTA=$((TOTAL_RX_DELTA + rx_delta))

        tx_MB=$(awk -v d="$tx_delta" -v i="$INTERVAL" -v w="$WORD_SIZE" \
            'BEGIN { printf "%.2f", (d*w)/(i*1024*1024) }')

        rx_MB=$(awk -v d="$rx_delta" -v i="$INTERVAL" -v w="$WORD_SIZE" \
            'BEGIN { printf "%.2f", (d*w)/(i*1024*1024) }')

        tx_Gbps=$(awk -v mb="$tx_MB" \
            'BEGIN { printf "%.2f", mb*8/1024 }')

        rx_Gbps=$(awk -v mb="$rx_MB" \
            'BEGIN { printf "%.2f", mb*8/1024 }')

        # ---------------------------------------------------------------------
        # Map host -> block devices
        # ---------------------------------------------------------------------
        paths=()

        for dev in /sys/block/sd*/device; do
            hcil=$(basename "$(readlink -f "$dev")" | cut -d: -f1)

            if [[ "$hcil" == "$hnum" ]]; then
                paths+=("$(basename "$(dirname "$dev")")")
            fi
        done

        # ---------------------------------------------------------------------
        # Determine host ALUA state
        # ---------------------------------------------------------------------
        host_state="[ANO]"

        for sd in "${paths[@]}"; do
            acc="/sys/block/$sd/device/access_state"

            [[ -f "$acc" ]] || continue

            if [[ "$(cat "$acc")" == "active/optimized" ]]; then
                host_state="[AO]"
                break
            fi
        done

        printf "%-8s %-8s %10s MB/s (%6s Gbps) | %10s MB/s (%6s Gbps) %8s\n" \
            "$host" \
            "$host_state" \
            "$tx_MB" "$tx_Gbps" \
            "$rx_MB" "$rx_Gbps" \
            "$speed Gbps"

        echo "       ----------------------------------------------------------------------------------------------------------"
        printf "       %-6s | %-7s | %-20s | %-6s | %-20s | %-9s | %-6s | %-10s\n" \
            "Drive" "Maj:min" "State" "Prio" "MP device" "MP Health" "IOPS" "ALUA"
        echo "       ----------------------------------------------------------------------------------------------------------"

        # ---------------------------------------------------------------------
        # Per-path details
        # ---------------------------------------------------------------------
        for sd in "${paths[@]}"; do

            majmin=$(cat "/sys/block/$sd/dev" 2>/dev/null | tr ':' ',')
            acc=$(cat "/sys/block/$sd/device/access_state" 2>/dev/null)

            prio="${PRIO_MAP[$sd]:--}"
            mpstat="${MPATH_STATUS[$sd]:--}"
            chk="${CHECKER_STATE[$sd]:--}"

            case "$acc" in
                active/optimized)
                    tag="[AO]"
                    ;;
                active/non-optimized)
                    tag="[ANO]"
                    ;;
                *)
                    tag="[--]"
                    ;;
            esac

            if [[ -f "/sys/block/$sd/stat" ]]; then
                read r _ _ _ w _ _ _ _ < "/sys/block/$sd/stat"

                total=$((r+w))
                delta=$((total - IO_PREV[$sd]))
                iops=$((delta / INTERVAL))

                IO_PREV[$sd]=$total
            else
                iops=0
            fi

            printf "       %-6s | %-7s | %-20s | %-6s | %-20s | %-9s | %-6s | %-10s\n" \
                "$sd" \
                "$majmin" \
                "$acc" \
                "$prio" \
                "$mpstat" \
                "$chk" \
                "$iops" \
                "$tag"
        done

        echo "===================================================================================================="

        TX_PREV[$host]=$tx_now
        RX_PREV[$host]=$rx_now
    done

    # -------------------------------------------------------------------------
    # Total aggregated throughput
    # -------------------------------------------------------------------------
    TOTAL_TX_MB=$(awk -v d="$TOTAL_TX_DELTA" -v i="$INTERVAL" -v w="$WORD_SIZE" \
        'BEGIN { printf "%.2f", (d*w)/(i*1024*1024) }')

    TOTAL_RX_MB=$(awk -v d="$TOTAL_RX_DELTA" -v i="$INTERVAL" -v w="$WORD_SIZE" \
        'BEGIN { printf "%.2f", (d*w)/(i*1024*1024) }')

    TOTAL_TX_Gbps=$(awk -v mb="$TOTAL_TX_MB" \
        'BEGIN { printf "%.2f", mb*8/1024 }')

    TOTAL_RX_Gbps=$(awk -v mb="$TOTAL_RX_MB" \
        'BEGIN { printf "%.2f", mb*8/1024 }')

    echo
    echo "====================================================================================="
    printf "Summary: TX %10s MB/s (%6s Gbps) | RX %10s MB/s (%6s Gbps)\n" \
        "$TOTAL_TX_MB" \
        "$TOTAL_TX_Gbps" \
        "$TOTAL_RX_MB" \
        "$TOTAL_RX_Gbps"
    echo "====================================================================================="

    echo
    echo "----------------------------------------------------------------------------------------------------"
    echo "Legend:"
    echo "HOST      -> Individual FC HBA port (not entire adapter)"
    echo "MP Health -> multipath checker (path liveness)"
    echo "ALUA      -> path optimality"
    echo "----[AO]      -> active/optimized"
    echo "----[ANO]     -> active/non-optimized"
    echo "----------------------------------------------------------------------------------------------------"

    sleep "$INTERVAL"
done
