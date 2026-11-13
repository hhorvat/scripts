#!/usr/bin/env bash

# =============================================================================
# FC SAN Traffic Monitor
#
# Script version: 8.9.4
# Compatibility target: Proxmox VE 9.x
# License: CC BY SA 4
# Author: Hrvoje Horvat
#
# Description:
#   Real-time Fibre Channel (FC) monitoring script for Linux systems.
#   Includes:
#     - FC HBA TX/RX throughput
#     - SCSI path and device state
#     - ALUA access state
#     - Multipath priority and path checker status
#     - Per-path IOPS and I/O utilization
#     - Kernel and multipathd journal events
#     - Current SCSI ALERT status
#
# Data sources:
#   - /sys/class/fc_host
#   - /sys/block/sdX/device
#   - /sys/block/sdX/stat
#   - multipathd show paths
#   - journalctl -k
#   - journalctl -u multipathd
#
# Event monitoring:
#   Initial scan reads a bounded journal tail.
#   Subsequent scans use journal cursors.
#   Kernel and multipathd are scanned independently.
#   Historical events are not presented as current faults.
#
# Usage:
#   chmod +x fc-monitor.sh
#   ./fc-monitor.sh
#
# =============================================================================

VERSION="8.9.5"

INTERVAL=5
WORD_SIZE=4

EVENT_HISTORY_LIMIT=12
EVENT_SCAN_KERNEL=300
EVENT_SCAN_MULTIPATH=200
EVENT_SEEN_LIMIT=600
EVENT_GROUP_WINDOW=120

declare -A TX_PREV
declare -A RX_PREV
declare -A SPEED

declare -A PRIO_MAP
declare -A MPATH_STATUS
declare -A CHECKER_STATE

declare -A IO_PREV
declare -A IO_TICKS_PREV

declare -A EVENT_SEEN
declare -a EVENT_SEEN_ORDER
declare -a EVENT_HISTORY

KERNEL_JOURNAL_CURSOR=""
MULTIPATH_JOURNAL_CURSOR=""

trap 'tput sgr0 2>/dev/null; tput cnorm 2>/dev/null; echo; exit 0' INT TERM

# -----------------------------------------------------------------------------
# Load multipath path information.
# -----------------------------------------------------------------------------
load_multipath_map() {
    PRIO_MAP=()
    MPATH_STATUS=()
    CHECKER_STATE=()

    while read -r dev prio vendor_product checker; do
        [[ -z "$dev" ]] && continue

        PRIO_MAP["$dev"]="$prio"
        MPATH_STATUS["$dev"]="$vendor_product"
        CHECKER_STATE["$dev"]="$checker"
    done < <(
        multipathd show paths raw format "%d %p %s %T" 2>/dev/null
    )
}

# -----------------------------------------------------------------------------
# Return the FC host associated with an sdX device.
# -----------------------------------------------------------------------------
get_scsi_host() {
    local dev="$1"
    local resolved

    resolved=$(readlink -f "/sys/block/$dev/device" 2>/dev/null) || {
        echo "-"
        return
    }

    if [[ "$resolved" =~ /host([0-9]+)/ ]]; then
        echo "host${BASH_REMATCH[1]}"
    else
        echo "-"
    fi
}

# Return success only for SCSI devices attached to an FC HBA.
is_fc_scsi_device() {
    local dev="$1"
    local host

    host=$(get_scsi_host "$dev")
    [[ "$host" != "-" && -d "/sys/class/fc_host/$host" ]]
}

# -----------------------------------------------------------------------------
# Classify and record one journal event.
# Source is either "kernel" or "multipathd".
# -----------------------------------------------------------------------------
record_event() {
    local source="$1"
    local line="$2"

    local timestamp rest message severity
    local device host did event_text key
    local event_majmin candidate candidate_majmin
    local rport port_id

    # Extract timestamp from short-iso-precise output.
    timestamp="${line%% *}"

    if [[ "$timestamp" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        timestamp="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    fi

    # Remove timestamp and hostname.
    rest="${line#* }"
    rest="${rest#* }"

    # Remove journal program prefix.
    if [[ "$rest" == kernel:\ * ]]; then
        message="${rest#kernel: }"

    elif [[ "$rest" =~ ^multipathd\[[0-9]+\]:\  ]]; then
        message="${rest#*: }"

    else
        message="$rest"
    fi

    # Ignore stack-trace fragments and generic hung-task explanations.
    if grep -Eqi \
        '^\?|^Call Trace:|^RIP:|^Code:|^Modules linked in:|^echo 0 > /proc/sys/kernel/hung_task_timeout_secs' \
        <<< "$message"; then
        return
    fi

    # Critical: confirmed failed I/O or transport/path-loss indicators.
    if grep -Eqi \
        'rejecting I/O to offline device|DID_TRANSPORT_DISRUPTED|DID_NO_CONNECT|DID_TIME_OUT|I/O error, dev |Buffer I/O error|all paths down|Synchronize Cache failed' \
        <<< "$message"; then

        severity="CRITICAL"

    # Warning: failed commands, path failures and explicit timeouts.
    elif grep -Eqi \
        'DID_ERROR|FAILED Result:|aborting command|task abort|resetting device|device reset|checker failed|mark as failed|mark failed|path is down|path down|FCP.*timeout|ELS.*timeout|command.*timed out|I/O.*timed out|Link Down Event|INFO: task .* blocked for more than' \
        <<< "$message"; then

        severity="WARNING"

    # Recovery: explicit indication that a link/path/device returned.
    elif grep -Eqi \
        'Link Up Event|reinstate|reinstated|checker reports path is up|path.*(up|ready|restored)|device.*running|recovered' \
        <<< "$message"; then

        severity="RECOVERY"

    else
        return
    fi

    device="-"
    host="-"
    did="-"

    # Resolve sdX directly from the journal message.
    if [[ "$message" =~ (^|[^[:alnum:]_])(sd[a-z]+)([^[:alnum:]_]|$) ]]; then
        device="${BASH_REMATCH[2]}"
        host=$(get_scsi_host "$device")

    # Resolve SCSI major:minor to sdX when possible.
    elif [[ "$message" =~ (^|[^0-9])([0-9]+):([0-9]+)([^0-9]|$) ]]; then
        event_majmin="${BASH_REMATCH[2]},${BASH_REMATCH[3]}"

        for candidate in /sys/block/sd*; do
            [[ -e "$candidate/dev" ]] || continue

            candidate_majmin=$(cat "$candidate/dev" 2>/dev/null | tr ':' ',')

            if [[ "$candidate_majmin" == "$event_majmin" ]]; then
                device=$(basename "$candidate")
                host=$(get_scsi_host "$device")
                break
            fi
        done
    fi

    # Extract FC destination ID when present.
    if [[ "$message" =~ DID:([[:xdigit:]]+) ]]; then
        did="${BASH_REMATCH[1]}"
    elif [[ "$message" =~ DID[[:space:]]+([[:xdigit:]]+) ]]; then
        did="${BASH_REMATCH[1]}"
    fi

    # Map FC DID to a currently visible remote port when possible.
    if [[ "$host" == "-" && "$did" != "-" ]]; then
        for rport in /sys/class/fc_remote_ports/rport-*; do
            [[ -d "$rport" ]] || continue

            port_id=$(cat "$rport/port_id" 2>/dev/null)
            port_id=${port_id#0x}

            if [[ "${port_id,,}" == "${did,,}" ]]; then
                if [[ "$rport" =~ rport-([0-9]+): ]]; then
                    host="host${BASH_REMATCH[1]}"
                fi
                break
            fi
        done
    fi

    event_text="$message"
    event_text=${event_text//$'\t'/ }
    event_text=${event_text//|/;}
    event_text=${event_text:0:105}

    # De-duplicate identical journal entries.
    key="$source|$line"

    [[ -n "${EVENT_SEEN[$key]:-}" ]] && return

    EVENT_SEEN["$key"]=1
    EVENT_SEEN_ORDER+=("$key")

    if (( ${#EVENT_SEEN_ORDER[@]} > EVENT_SEEN_LIMIT )); then
        local old_key="${EVENT_SEEN_ORDER[0]}"

        unset 'EVENT_SEEN[$old_key]'
        EVENT_SEEN_ORDER=("${EVENT_SEEN_ORDER[@]:1}")
    fi

    EVENT_HISTORY+=("$timestamp|$device|$host|$did|$severity|$event_text")

    if (( ${#EVENT_HISTORY[@]} > EVENT_HISTORY_LIMIT )); then
        EVENT_HISTORY=("${EVENT_HISTORY[@]: -EVENT_HISTORY_LIMIT}")
    fi
}

# -----------------------------------------------------------------------------
# Scan one journal source.
#
# Important:
#   Kernel:     journalctl -k
#   Multipathd: journalctl -u multipathd
#
# The arguments -u and multipathd must remain separate array elements.
# -----------------------------------------------------------------------------
scan_one_journal() {
    local cursor_name="$1"
    local initial_lines="$2"
    local source="$3"

    local output line new_cursor=""
    local -a journal_args=()

    case "$source" in
        kernel)
            journal_args=(-k)
            ;;
        multipathd)
            journal_args=(-u multipathd)
            ;;
        *)
            return 1
            ;;
    esac

    if [[ -z "${!cursor_name:-}" ]]; then
        # Initial bounded scan.
        journal_args+=(
            -b
            -n "$initial_lines"
            --show-cursor
            --no-pager
            -o short-iso-precise
        )
    else
        # Incremental scan from the last journal cursor.
        journal_args+=(
            -b
            --after-cursor="${!cursor_name}"
            --show-cursor
            --no-pager
            -o short-iso-precise
        )
    fi

    output=$(journalctl "${journal_args[@]}" 2>/dev/null)

    while IFS= read -r line; do
        if [[ "$line" == --\ cursor:* ]]; then
            new_cursor="${line#-- cursor: }"

        elif [[ -n "$line" ]]; then
            record_event "$source" "$line"
        fi
    done <<< "$output"

    if [[ -n "$new_cursor" ]]; then
        printf -v "$cursor_name" '%s' "$new_cursor"
    fi
}

# -----------------------------------------------------------------------------
# Scan kernel and multipathd journal entries independently.
# -----------------------------------------------------------------------------
scan_events() {
    scan_one_journal \
        "KERNEL_JOURNAL_CURSOR" \
        "$EVENT_SCAN_KERNEL" \
        "kernel"

    scan_one_journal \
        "MULTIPATH_JOURNAL_CURSOR" \
        "$EVENT_SCAN_MULTIPATH" \
        "multipathd"
}

# -----------------------------------------------------------------------------
# Display recent event history and current non-running SCSI path states.
# -----------------------------------------------------------------------------
display_events() {
    local item timestamp device host did severity event_text
    local active_count=0
    local sd state

    local -a sorted_events=()

    local current_key=""
    local current_time=""
    local current_epoch=0
    local current_device=""
    local current_host=""
    local current_did=""
    local current_severity=""
    local current_text=""

    local event_epoch event_key label
    local severity_rank current_rank

    # Sort the bounded history chronologically.
    if (( ${#EVENT_HISTORY[@]} > 0 )); then
        mapfile -t sorted_events < <(
            printf '%s\n' "${EVENT_HISTORY[@]}" |
                LC_ALL=C sort -t '|' -k1,1
        )
    fi

    echo
    echo "========================== FC / SCSI EVENTS =========================="
    echo "Recent events (last 12; related path events combined)"

    printf "%-19s   %-6s  %-7s  %-8s  %s\n" \
        "TIME" "DEVICE" "HOST" "LEVEL" "EVENT"

    echo "---------------------------------------------------------------------"

    # Print one accumulated incident row.
    flush_event_row() {
        [[ -z "$current_time" ]] && return

        printf "%-19s   %-6s  %-7s  %-8s  %s\n" \
            "$current_time" \
            "$current_device" \
            "$current_host" \
            "$current_severity" \
            "${current_text:0:145}"
    }

    if (( ${#sorted_events[@]} == 0 )); then
        echo "No matching FC / SCSI / multipath events found in the scanned journal."

    else
        local -A GROUP_SEEN=()

        for item in "${sorted_events[@]}"; do
            IFS='|' read -r timestamp device host did severity event_text <<< "$item"

            event_epoch=$(date -d "$timestamp" +%s 2>/dev/null || echo 0)
            event_key="$device|$host"

            # Combine events only for the same SCSI path and host,
            # within the configured time window.
            if [[ -n "$current_time" &&
                  "$device" != "-" &&
                  "$event_key" == "$current_key" &&
                  "$event_epoch" -ge "$current_epoch" &&
                  $((event_epoch - current_epoch)) -le "$EVENT_GROUP_WINDOW" ]]; then

                # Avoid repeating identical messages within one incident.
                if [[ -z "${GROUP_SEEN[$event_text]:-}" ]]; then
                    GROUP_SEEN["$event_text"]=1

                    label="$event_text"

                    if [[ "$severity" != "$current_severity" ]]; then
                        label="$severity: $label"
                    fi

                    current_text+="; $label"
                fi

                # Keep the highest severity for the incident summary.
                case "$severity" in
                    CRITICAL) severity_rank=3 ;;
                    WARNING)  severity_rank=2 ;;
                    RECOVERY) severity_rank=1 ;;
                    *)        severity_rank=0 ;;
                esac

                case "$current_severity" in
                    CRITICAL) current_rank=3 ;;
                    WARNING)  current_rank=2 ;;
                    RECOVERY) current_rank=1 ;;
                    *)        current_rank=0 ;;
                esac

                if (( severity_rank > current_rank )); then
                    current_severity="$severity"
                fi

            else
                flush_event_row

                current_time="$timestamp"
                current_epoch="$event_epoch"
                current_key="$event_key"
                current_device="$device"
                current_host="$host"
                current_did="$did"
                current_severity="$severity"
                current_text="$event_text"

                GROUP_SEEN=()
                GROUP_SEEN["$event_text"]=1

                # Global events remain independent rows.
                if [[ "$device" == "-" ]]; then
                    flush_event_row

                    current_time=""
                    current_key=""
                    GROUP_SEEN=()
                fi
            fi
        done

        flush_event_row
    fi

    # -------------------------------------------------------------------------
    # Current SCSI state is independent of historical journal events.
    # -------------------------------------------------------------------------
    echo "========================================================================"

    for sdpath in /sys/block/sd*; do
        [[ -d "$sdpath/device" ]] || continue

        sd=$(basename "$sdpath")
        host=$(get_scsi_host "$sd")
        # Restrict alerts to devices attached to an FC HBA.
        is_fc_scsi_device "$sd" || continue

        state=$(cat "$sdpath/device/state" 2>/dev/null) || continue

        if [[ "$state" != "running" ]]; then
            printf "SCSI ALERT: %s (%s) %s\n" \
                "$sd" "$host" "${state^^}"

            ((active_count+=1))
        fi
    done

    if (( active_count == 0 )); then
        echo "SCSI ALERT: none"
    fi

    echo "========================================================================"
}

# -----------------------------------------------------------------------------
# Initial FC counters.
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
# Initial disk I/O counters.
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

# Use the actual elapsed time between samples. The loop work and journal scan
# add to the configured sleep interval, so using INTERVAL alone under-reports
# throughput and IOPS when a cycle takes longer than expected.
LAST_SAMPLE_NS=$(date +%s%N)

# -----------------------------------------------------------------------------
# Main monitoring loop.
# -----------------------------------------------------------------------------
while true; do
    NOW_NS=$(date +%s%N)
    SAMPLE_MS=$(( (NOW_NS - LAST_SAMPLE_NS) / 1000000 ))
    LAST_SAMPLE_NS=$NOW_NS
    (( SAMPLE_MS < 1 )) && SAMPLE_MS=1
    SAMPLE_SECONDS=$(awk -v ms="$SAMPLE_MS" 'BEGIN { printf "%.6f", ms/1000 }')

    load_multipath_map
    clear

    TOTAL_TX_DELTA=0
    TOTAL_RX_DELTA=0

    # Compact table width: approximately 122 columns including indentation.
    TABLE_RULE="       $(printf '%115s' '' | tr ' ' '-')"

    printf "FC SAN Traffic Monitor v%s | Refresh: %s | Interval: %ss\n" \
        "$VERSION" "$(date '+%Y-%m-%d %H:%M:%S')" "$INTERVAL"
    echo "===================================================================================================="

    printf "%-8s %-8s %26s %26s %10s\n" \
        "HOST" "STATE" "TX (MB/s / Gbps)" "RX (MB/s / Gbps)" "LINK"

    echo "===================================================================================================="

    for h in /sys/class/fc_host/host*; do
        [[ -d "$h" ]] || continue

        host=$(basename "$h")
        hnum=${host//host/}
        spd=$(cat "$h/speed" 2>/dev/null || echo 0)
        speed=${spd//[^0-9]/}
        [[ -n "$speed" ]] || speed=0
        SPEED[$host]="$speed"

        tx_now=$(cat "$h/statistics/tx_words" 2>/dev/null || echo 0)
        rx_now=$(cat "$h/statistics/rx_words" 2>/dev/null || echo 0)

        tx_prev=${TX_PREV[$host]:-$tx_now}
        rx_prev=${RX_PREV[$host]:-$rx_now}
        tx_delta=$((tx_now - tx_prev))
        rx_delta=$((rx_now - rx_prev))
        # FC counters can reset after link/HBA recovery or device reinitialization.
        (( tx_delta < 0 )) && tx_delta=0
        (( rx_delta < 0 )) && rx_delta=0

        TOTAL_TX_DELTA=$((TOTAL_TX_DELTA + tx_delta))
        TOTAL_RX_DELTA=$((TOTAL_RX_DELTA + rx_delta))

        # Decimal MB/s and Gbit/s units (1 MB = 1,000,000 bytes).
        tx_MB=$(awk -v d="$tx_delta" -v i="$SAMPLE_SECONDS" -v w="$WORD_SIZE" \
            'BEGIN { printf "%.2f", (d*w)/(i*1000000) }')

        rx_MB=$(awk -v d="$rx_delta" -v i="$SAMPLE_SECONDS" -v w="$WORD_SIZE" \
            'BEGIN { printf "%.2f", (d*w)/(i*1000000) }')

        tx_Gbps=$(awk -v mb="$tx_MB" 'BEGIN { printf "%.2f", mb*8/1000 }')
        rx_Gbps=$(awk -v mb="$rx_MB" 'BEGIN { printf "%.2f", mb*8/1000 }')

        paths=()

        for dev in /sys/block/sd*/device; do
            [[ -e "$dev" ]] || continue

            hcil=$(basename "$(readlink -f "$dev")" | cut -d: -f1)

            if [[ "$hcil" == "$hnum" ]]; then
                paths+=("$(basename "$(dirname "$dev")")")
            fi
        done

        host_state="[--]"
        has_ano=0

        for sd in "${paths[@]}"; do
            acc="/sys/block/$sd/device/access_state"
            state_file="/sys/block/$sd/device/state"
            [[ -r "$acc" && -r "$state_file" ]] || continue
            [[ "$(cat "$state_file" 2>/dev/null)" == "running" ]] || continue

            case "$(cat "$acc" 2>/dev/null)" in
                active/optimized)
                    host_state="[AO]"
                    break
                    ;;
                active/non-optimized)
                    has_ano=1
                    ;;
            esac
        done
        if [[ "$host_state" != "[AO]" && "$has_ano" -eq 1 ]]; then
            host_state="[ANO]"
        fi

        printf "%-8s %-8s %10s MB/s (%6s Gbps) | %10s MB/s (%6s Gbps) %8s\n" \
            "$host" "$host_state" "$tx_MB" "$tx_Gbps" \
            "$rx_MB" "$rx_Gbps" "$speed Gbps"

        echo "$TABLE_RULE"

        # Single-line compact headings: keep both width and height down.
        printf "       %-4s | %-7s | %-7s | %-19s | %-4s | %-16s | %-8s | %-5s | %-3s | %-5s | %-7s\n" \
            "Drive" "Maj:min" "SCSI" "Path" "Prio" \
            "Vendor/Prod." "MP" "IOPS" "I/O" "ALUA" "IO-util"

        echo "$TABLE_RULE"

        for sd in "${paths[@]}"; do
            majmin=$(cat "/sys/block/$sd/dev" 2>/dev/null | tr ':' ',')
            acc=$(cat "/sys/block/$sd/device/access_state" 2>/dev/null)
            scsi_state=$(cat "/sys/block/$sd/device/state" 2>/dev/null || echo "unknown")

            prio="${PRIO_MAP[$sd]:--}"
            mpstat="${MPATH_STATUS[$sd]:--}"
            chk="${CHECKER_STATE[$sd]:--}"

            case "$acc" in
                active/optimized)     tag="[AO]" ;;
                active/non-optimized) tag="[ANO]" ;;
                *)                    tag="[--]" ;;
            esac

            if [[ -r "/sys/block/$sd/stat" ]]; then
                read -r -a stat_fields < "/sys/block/$sd/stat"

                total=$(( ${stat_fields[0]:-0} + ${stat_fields[4]:-0} ))
                previous_total=${IO_PREV[$sd]:-$total}
                delta=$((total - previous_total))
                # A re-created SCSI device may restart its statistics at zero.
                (( delta < 0 )) && delta=0

                iops=$(awk -v d="$delta" -v i="$SAMPLE_SECONDS" \
                    'BEGIN { if (i > 0) printf "%.1f", d/i; else printf "n/a" }')

                # Field 9: current I/O requests in progress.
                io_in_progress=${stat_fields[8]:-0}

                # Field 10: milliseconds spent with I/O in progress.
                io_ticks_now=${stat_fields[9]:-0}
                previous_io_ticks=${IO_TICKS_PREV[$sd]:-$io_ticks_now}
                io_ticks_delta=$((io_ticks_now - previous_io_ticks))
                (( io_ticks_delta < 0 )) && io_ticks_delta=0

                io_util=$(awk -v d="$io_ticks_delta" -v ms="$SAMPLE_MS" \
                    'BEGIN {
                        if (ms <= 0 || d < 0) {
                            printf "n/a"
                        } else {
                            v = (d / ms) * 100
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

            printf "       %-4s | %-7s | %-7s | %-19s | %-4s | %-16s | %-8s | %-5s | %-3s | %-5s | %-7s\n" \
                "$sd" "$majmin" "$scsi_state" "$acc" "$prio" \
                "$mpstat" "$chk" "$iops" "$io_in_progress" "$tag" "$io_util"
        done

        echo "$TABLE_RULE"

        TX_PREV[$host]=$tx_now
        RX_PREV[$host]=$rx_now
    done

    TOTAL_TX_MB=$(awk -v d="$TOTAL_TX_DELTA" -v i="$SAMPLE_SECONDS" -v w="$WORD_SIZE" \
        'BEGIN { printf "%.2f", (d*w)/(i*1000000) }')

    TOTAL_RX_MB=$(awk -v d="$TOTAL_RX_DELTA" -v i="$SAMPLE_SECONDS" -v w="$WORD_SIZE" \
        'BEGIN { printf "%.2f", (d*w)/(i*1000000) }')

    TOTAL_TX_Gbps=$(awk -v mb="$TOTAL_TX_MB" 'BEGIN { printf "%.2f", mb*8/1000 }')
    TOTAL_RX_Gbps=$(awk -v mb="$TOTAL_RX_MB" 'BEGIN { printf "%.2f", mb*8/1000 }')

    echo
    echo "====================================================================================="

    printf "Summary: TX %10s MB/s (%6s Gbps) | RX %10s MB/s (%6s Gbps)\n" \
        "$TOTAL_TX_MB" "$TOTAL_TX_Gbps" "$TOTAL_RX_MB" "$TOTAL_RX_Gbps"

    echo "====================================================================================="

    # Collect journal events after the main FC/SCSI dashboard is visible.
    scan_events
    display_events

    # -------------------------------------------------------------------------
    # Legend - two aligned columns.
    # -------------------------------------------------------------------------
    echo
    echo "+------------------------- LEGEND -----------------------------+"
    printf "| %-29s | %-29s |\n" \
        "HOST -> FC HBA port" "Drive -> SCSI/FC path"
    printf "| %-29s | %-29s |\n" \
        "Maj:min -> Linux device IDs" "SCSI -> Device state"
    printf "| %-29s | %-29s |\n" \
        "Path -> ALUA access state" "Prio -> Multipath priority"
    printf "| %-29s | %-29s |\n" \
        "Vendor/Prod. -> SCSI identity" "MP -> Path checker state"
    printf "| %-29s | %-29s |\n" \
        "IOPS -> Completed I/O/s" "I/O -> Requests in progress"
    printf "| %-29s | %-29s |\n" \
        "ALUA -> AO / ANO / unavailable" "IO-util -> Active I/O time"
    printf "| %-29s | %-29s |\n" \
        "CRITICAL -> I/O or transport loss" "WARNING -> Timeout/path fault"
    printf "| %-29s | %-29s |\n" \
        "RECOVERY -> Path/link restored" "SCSI ALERT -> Non-running path"
    echo "+--------------------------------------------------------------+"

    sleep "$INTERVAL"
done
