#!/usr/bin/env bash

# =============================================================================
# FC SAN Traffic Monitor
#
# Script version: 8.5
# Tested on: Proxmox VE: 9.1.x, 9.2.x.
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
#     - Per-path I/O utilization (individual /dev/sdX path)
#     - SCSI device state
#     - I/O requests currently in progress
#
# Data sources:
#   - /sys/class/fc_host               (FC HBA statistics)
#   - /sys/block/sdX/device            (SCSI and ALUA state)
#   - /sys/block/sdX/stat              (per-path I/O statistics)
#   - multipathd show paths            (multipath topology and health)
#
# Important:
#   IO-utilization is calculated separately for each SCSI path (sdb, sdc,
#   sdd, etc.) using the delta of io_ticks (field 10 in /sys/block/sdX/stat).
#   It does NOT use the top-level multipath device (dm-X) statistics.
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
declare -A IO_TICKS_PREV

trap 'tput sgr0 2>/dev/null; tput cnorm 2>/dev/null; echo; exit 0' INT TERM

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
    [[ -d "$h" ]] || continue
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
    [[ -d "$sd" ]] || continue
    dev=$(basename "$sd")
    [[ -f "$sd/stat" ]] || continue

    read -r -a stat_fields < "$sd/stat"

    # Fields 1 and 5: completed reads and writes.
    IO_PREV[$dev]=$(( ${stat_fields[0]:-0} + ${stat_fields[4]:-0} ))

    # Field 10: milliseconds spent with I/O in progress (io_ticks).
    IO_TICKS_PREV[$dev]=${stat_fields[9]:-0}
done

tput civis 2>/dev/null

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
        [[ -d "$h" ]] || continue

        host=$(basename "$h")
        hnum=${host//host/}
        speed=${SPEED[$host]:-0}

        tx_now=$(cat "$h/statistics/tx_words" 2>/dev/null || echo 0)
        rx_now=$(cat "$h/statistics/rx_words" 2>/dev/null || echo 0)

        tx_delta=$((tx_now - ${TX_PREV[$host]:-$tx_now}))
        rx_delta=$((rx_now - ${RX_PREV[$host]:-$rx_now}))

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
            [[ -e "$dev" ]] || continue
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

        echo "       -------------------------------------------------------------------------------------------------------------------------------------"

        printf "       %-6s | %-7s | %-11s | %-20s | %-6s | %-20s | %-9s | %-6s | %-15s | %-10s | %-14s\n" \
            "Drive" "Maj:min" "SCSI state" "Path state" "Prio" "MP device" "MP Health" "IOPS" "I/O in progress" "ALUA" "IO-utilization"

        echo "       -------------------------------------------------------------------------------------------------------------------------------------"

        # ---------------------------------------------------------------------
        # Per-path details: all I/O metrics are read from the individual sdX.
        # No dm-X / top-level multipath statistics are used here.
        # ---------------------------------------------------------------------
        for sd in "${paths[@]}"; do
            majmin=$(cat "/sys/block/$sd/dev" 2>/dev/null | tr ':' ',')
            acc=$(cat "/sys/block/$sd/device/access_state" 2>/dev/null)
            scsi_state=$(cat "/sys/block/$sd/device/state" 2>/dev/null || echo "unknown")

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

            if [[ -r "/sys/block/$sd/stat" ]]; then
                read -r -a stat_fields < "/sys/block/$sd/stat"

                # Fields 1 and 5: completed read/write requests.
                total=$(( ${stat_fields[0]:-0} + ${stat_fields[4]:-0} ))
                previous_total=${IO_PREV[$sd]:-$total}
                delta=$((total - previous_total))
                iops=$((delta / INTERVAL))

                # Field 9: I/O requests currently in progress.
                io_in_progress=${stat_fields[8]:-0}

                # Field 10: milliseconds with I/O in progress (io_ticks).
                io_ticks_now=${stat_fields[9]:-0}
                previous_io_ticks=${IO_TICKS_PREV[$sd]:-$io_ticks_now}
                io_ticks_delta=$((io_ticks_now - previous_io_ticks))

                io_util=$(awk -v d="$io_ticks_delta" -v i="$INTERVAL" \
                    'BEGIN {
                        if (i <= 0 || d < 0) {
                            printf "n/a"
                        } else {
                            v = (d / (i * 1000)) * 100
                            if (v > 100) v = 100
                            printf "%.1f%%", v
                        }
                    }')

                IO_PREV[$sd]=$total
                IO_TICKS_PREV[$sd]=$io_ticks_now
            else
                iops=0
                io_in_progress="n/a"
                io_util="n/a"
            fi

            printf "       %-6s | %-7s | %-11s | %-20s | %-6s | %-20s | %-9s | %-6s | %-15s | %-10s | %-14s\n" \
                "$sd" \
                "$majmin" \
                "$scsi_state" \
                "$acc" \
                "$prio" \
                "$mpstat" \
                "$chk" \
                "$iops" \
                "$io_in_progress" \
                "$tag" \
                "$io_util"
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
    echo "---------------------------------------------------------------------"
    echo "Legend:"
    echo "HOST           -> FC HBA port."
    echo "Drive          -> Individual SCSI/FC path (sdX)."
    echo "Maj:min        -> Linux device major:minor numbers."
    echo "SCSI state     -> Device state: running, blocked, offline."
    echo "Path state     -> Multipath path status."
    echo "Prio           -> Multipath path priority."
    echo "MP device      -> Associated multipath device."
    echo "MP Health      -> Multipath path checker status."
    echo "IOPS           -> Completed read/write operations per second."
    echo "I/O progress   -> Current I/O requests (block layer, stat field 9)."
    echo "ALUA           -> [AO] optimized, [ANO] non-optimized."
    echo "IO-utilization -> Interval percentage with I/O active (io_ticks)."
    echo "                 High value with 0 IOPS may indicate pending I/O."
    echo "---------------------------------------------------------------------"

    sleep "$INTERVAL"
done
