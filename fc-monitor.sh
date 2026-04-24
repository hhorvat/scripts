#!/usr/bin/env bash

# =============================================================================
# FC SAN Traffic Monitor - Version 8.1 for Proxmox VE 
#
# Tested on: Proxmox VE 9.1.x  
# License: CC BY SA 4
# Author: Hrvoje Horvat
#
# Description:
#   Real-time Fibre Channel (FC) monitoring script for Linux systems.
#
#   This script provides a unified view of:
#     - FC host throughput (TX/RX in MB/s and Gbps)
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
#   MP Health (checker state):
#     -> Indicates whether the path is alive and usable (I/O works)
#
#   ALUA state:
#     -> Indicates whether the path is optimal (performance perspective)
#
#   Important:
#     A path can be healthy but not optimal:
#       chk=active + [ANO]  → working but suboptimal path
#
# Usage:
#   chmod +x fc-monitor.sh
#   ./fc-monitor.sh
#
# =============================================================================

INTERVAL=5
WORD_SIZE=4   # FC word = 4 bytes

# Previous counters and runtime maps
declare -A TX_PREV RX_PREV SPEED
declare -A PRIO_MAP MPATH_STATUS CHECKER_STATE
declare -A IO_PREV

# Restore terminal on exit
trap 'tput sgr0; tput cnorm; echo; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Load multipath information:
#   - device name (sdX)
#   - priority
#   - multipath device state (active/enabled/failed)
#   - checker state (health)
# -----------------------------------------------------------------------------
load_multipath_map() {
    PRIO_MAP=()
    MPATH_STATUS=()
    CHECKER_STATE=()

    while read -r dev prio dmstat chk; do
        PRIO_MAP["$dev"]="$prio"
        MPATH_STATUS["$dev"]="$dmstat"
        CHECKER_STATE["$dev"]="$chk"
    done < <(
        multipathd show paths format "%d %p %s %t" 2>/dev/null | awk 'NR>1'
    )
}

# -----------------------------------------------------------------------------
# Initial read of FC host counters and link speeds
# -----------------------------------------------------------------------------
for h in /sys/class/fc_host/host*; do
    host=$(basename "$h")

    TX_PREV[$host]=$(cat "$h/statistics/tx_words" 2>/dev/null || echo 0)
    RX_PREV[$host]=$(cat "$h/statistics/rx_words" 2>/dev/null || echo 0)

    spd=$(cat "$h/speed" 2>/dev/null || echo 0)
    SPEED[$host]=${spd//[^0-9]/}
done

# -----------------------------------------------------------------------------
# Initial read of block device I/O counters (for IOPS calculation)
# -----------------------------------------------------------------------------
for sd in /sys/block/sd*; do
    dev=$(basename "$sd")
    [[ -f "$sd/stat" ]] || continue
    read r _ _ _ w _ _ _ _ < "$sd/stat"
    IO_PREV[$dev]=$((r+w))
done

# Hide cursor for better UI
tput civis

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------
while true; do
    load_multipath_map
    clear

    echo "===================================================================================================="
    printf "%-8s %-8s %26s %26s %10s\n" \
           "HOST" "STATE" "TX (MB/s / Gbps)" "RX (MB/s / Gbps)" "LINK"
    echo "===================================================================================================="

    # Iterate through FC hosts
    for h in /sys/class/fc_host/host*; do

        host=$(basename "$h")
        hnum=${host//host/}
        speed=${SPEED[$host]:-0}

        # Read current counters
        tx_now=$(cat "$h/statistics/tx_words" 2>/dev/null || echo 0)
        rx_now=$(cat "$h/statistics/rx_words" 2>/dev/null || echo 0)

        # Calculate delta
        tx_delta=$(( tx_now - TX_PREV[$host] ))
        rx_delta=$(( rx_now - RX_PREV[$host] ))

        # Convert to MB/s
        tx_MB=$(awk -v d="$tx_delta" -v i="$INTERVAL" -v w="$WORD_SIZE" \
                 'BEGIN { printf "%.2f", (d*w)/(i*1024*1024) }')
        rx_MB=$(awk -v d="$rx_delta" -v i="$INTERVAL" -v w="$WORD_SIZE" \
                 'BEGIN { printf "%.2f", (d*w)/(i*1024*1024) }')

        # Convert to Gbps
        tx_Gbps=$(awk -v mb="$tx_MB" 'BEGIN { printf "%.2f", mb*8/1024 }')
        rx_Gbps=$(awk -v mb="$rx_MB" 'BEGIN { printf "%.2f", mb*8/1024 }')

        # ---------------------------------------------------------------------
        # Map FC host → SCSI block devices (sdX)
        # ---------------------------------------------------------------------
        paths=()
        for dev in /sys/block/sd*/device; do
            hcil=$(basename "$(readlink -f "$dev")" | cut -d: -f1)
            [[ "$hcil" == "$hnum" ]] && paths+=("$(basename $(dirname $dev))")
        done

        # ---------------------------------------------------------------------
        # Determine host ALUA state (AO if any optimized path exists)
        # ---------------------------------------------------------------------
        host_state="[ANO]"
        for sd in "${paths[@]}"; do
            acc="/sys/block/$sd/device/access_state"
            [[ -f "$acc" ]] || continue
            [[ "$(cat "$acc")" == "active/optimized" ]] && host_state="[AO]"
        done

        # Print host summary
        printf "%-8s %-8s %10s MB/s (%6s Gbps) | %10s MB/s (%6s Gbps) %8s\n" \
               "$host" "$host_state" \
               "$tx_MB" "$tx_Gbps" \
               "$rx_MB" "$rx_Gbps" \
               "$speed Gbps"

        # ---------------------------------------------------------------------
        # Print path details header
        # ---------------------------------------------------------------------
        echo "       ----------------------------------------------------------------------------------------------------------"
        printf "       %-6s | %-7s | %-20s | %-6s | %-20s | %-9s | %-6s | %-10s\n" \
               "Drive" "Maj:min" "State" "Prio" "MP device" "MP Health" "IOPS" "ALUA"
        echo "       ----------------------------------------------------------------------------------------------------------"

        # ---------------------------------------------------------------------
        # Iterate through all paths (sd devices)
        # ---------------------------------------------------------------------
        for sd in "${paths[@]}"; do

            majmin=$(cat /sys/block/$sd/dev 2>/dev/null | tr ':' ',')
            acc=$(cat /sys/block/$sd/device/access_state 2>/dev/null)

            prio="${PRIO_MAP[$sd]:--}"
            mpstat="${MPATH_STATUS[$sd]:--}"
            chk="${CHECKER_STATE[$sd]:--}"

            # Translate ALUA state to tag
            case "$acc" in
                active/optimized)     tag="[AO]" ;;
                active/non-optimized) tag="[ANO]" ;;
                *)                    tag="[--]" ;;
            esac

            # Calculate IOPS (reads + writes per interval)
            if [[ -f "/sys/block/$sd/stat" ]]; then
                read r _ _ _ w _ _ _ _ < "/sys/block/$sd/stat"
                total=$((r+w))
                delta=$(( total - IO_PREV[$sd] ))
                iops=$(( delta / INTERVAL ))
                IO_PREV[$sd]=$total
            else
                iops=0
            fi

            printf "       %-6s | %-7s | %-20s | %-6s | %-20s | %-9s | %-6s | %-10s\n" \
                   "$sd" "$majmin" "$acc" \
                   "$prio" "$mpstat" "$chk" "$iops" "$tag"
        done

        echo "===================================================================================================="

        # Update counters
        TX_PREV[$host]=$tx_now
        RX_PREV[$host]=$rx_now
    done

    # Footer
    echo
    echo "----------------------------------------------------------------------------------------------------"
    echo "Legend:"
    echo "MP Health -> multipath checker (path liveness)"
    echo "ALUA      -> path optimality (AO/ANO)"
    echo "[AO]  active/optimized"
    echo "[ANO] active/non-optimized"
    echo "----------------------------------------------------------------------------------------------------"

    sleep "$INTERVAL"
done
