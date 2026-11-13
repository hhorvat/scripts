#!/bin/bash
#
# DIMM DIAGNOSE
#
# Linux memory error analysis using:
#   - dmidecode / SMBIOS Type 17
#   - Linux EDAC sysfs counters
#   - External model database: dimm-mapping.conf
#
# The configuration file is DATA. It is parsed; it is never sourced/evaluated.
#
# Physical EDAC-to-slot translation currently implemented:
#   - HPE ProLiant BL460c Gen8 (verified physical mapping)
#   - HPE ProLiant BL460c Gen9 (EDAC/SMBIOS correlation only)
#
# Other profiles are recognized but remain REFERENCE_ONLY until their
# EDAC-to-physical-slot translations have been validated.
#
# Files required in the same directory:
#   dimm-diagnose.sh
#   dimm-mapping.conf
#
# Version: 0.8
# Validation: syntax-checked; Gen8 tested by user; Gen9 profile based on supplied
#             SMBIOS/EDAC output. Gen9 physical slot mapping is NOT verified.
# License: CC BY-SA 4.0
# Author: Hrvoje Horvat

export LC_ALL=C

# ==========================================================
# 1. BASIC CHECKS AND CONFIGURATION FILE
# ==========================================================

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this script as root." >&2
    exit 1
fi

if ! command -v dmidecode >/dev/null 2>&1; then
    echo "ERROR: dmidecode is not installed." >&2
    exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="${SCRIPT_DIR}/dimm-mapping.conf"

if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found or not readable:" >&2
    echo "       $CONFIG_FILE" >&2
    echo "Place dimm-mapping.conf in the same directory as this script." >&2
    exit 1
fi

EDAC_ROOT="/sys/devices/system/edac/mc"

# ==========================================================
# 2. SAFE CONFIGURATION PARSER
# ==========================================================
# This parser accepts:
#   [SECTION]
#   key=value
#   # comments
#
# It does not execute configuration contents.
# Only simple section names and key names are accepted.

declare -A CFG
CURRENT_SECTION=""
CONFIG_ERRORS=0
LINE_NUMBER=0

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    ((LINE_NUMBER++))
    LINE="${LINE%$'\r'}"
    LINE="$(trim "$LINE")"

    [[ -z "$LINE" ]] && continue
    [[ "$LINE" == \#* ]] && continue

    if [[ "$LINE" =~ ^\[([A-Za-z0-9_]+)\]$ ]]; then
        CURRENT_SECTION="${BASH_REMATCH[1]}"
        continue
    fi

    if [[ "$LINE" =~ ^([A-Za-z0-9_]+)=(.*)$ ]]; then
        if [[ -z "$CURRENT_SECTION" ]]; then
            echo "ERROR: Key outside a section at line $LINE_NUMBER." >&2
            CONFIG_ERRORS=1
            continue
        fi

        KEY="${BASH_REMATCH[1]}"
        VALUE="$(trim "${BASH_REMATCH[2]}")"
        FULL_KEY="${CURRENT_SECTION}:${KEY}"

        if [[ -n "${CFG[$FULL_KEY]+x}" ]]; then
            echo "ERROR: Duplicate configuration key at line $LINE_NUMBER: $FULL_KEY" >&2
            CONFIG_ERRORS=1
            continue
        fi

        CFG["$FULL_KEY"]="$VALUE"
        continue
    fi

    echo "ERROR: Invalid configuration syntax at line $LINE_NUMBER:" >&2
    echo "       $LINE" >&2
    CONFIG_ERRORS=1
done < "$CONFIG_FILE"

if [[ "$CONFIG_ERRORS" -ne 0 ]]; then
    echo "ERROR: Configuration file contains errors; refusing to continue." >&2
    exit 1
fi

# ==========================================================
# 3. SYSTEM IDENTIFICATION AND PROFILE SELECTION
# ==========================================================

MANUFACTURER=$(dmidecode -s system-manufacturer 2>/dev/null | head -n1)
PRODUCT=$(dmidecode -s system-product-name 2>/dev/null | head -n1)
VERSION=$(dmidecode -s system-version 2>/dev/null | head -n1)

MODEL="GENERIC"
MAPPING_STATUS="UNSUPPORTED"
MODEL_NOTE="No matching platform profile was found."
MAPPING_SCOPE="EDAC logical location only"
PROFILE_MATCHED=0

for SECTION in HPE_BL460C_GEN8 HPE_BL460C_GEN9 HPE_DL380_GEN10 DELL_R630 DELL_R740 DELL_R750 LENOVO_SR650; do
    MFR_REGEX="${CFG[$SECTION:manufacturer_match_regex]}"
    PRODUCT_REGEX="${CFG[$SECTION:product_match_regex]}"

    [[ -z "$MFR_REGEX" || -z "$PRODUCT_REGEX" ]] && continue

    if [[ "$MANUFACTURER" =~ $MFR_REGEX && "$PRODUCT" =~ $PRODUCT_REGEX ]]; then
        MODEL="$SECTION"
        MAPPING_STATUS="${CFG[$SECTION:mapping_status]:-REFERENCE_ONLY}"
        MAPPING_SCOPE="${CFG[$SECTION:mapping_scope]:-Not specified}"
        PROFILE_MATCHED=1
        break
    fi
done

if [[ "$PROFILE_MATCHED" -eq 1 ]]; then
    CHANNELS_PER_CPU="${CFG[$MODEL:channels_per_cpu]:-Unknown}"
    DIMMS_PER_CHANNEL="${CFG[$MODEL:dimms_per_channel]:-Unknown}"
    DIMMS_PER_CPU="${CFG[$MODEL:dimms_per_cpu]:-Unknown}"
    MODEL_NOTE="${CFG[$MODEL:physical_layout]:-No physical layout description.}"
else
    CHANNELS_PER_CPU="Unknown"
    DIMMS_PER_CHANNEL="Unknown"
    DIMMS_PER_CPU="Unknown"
fi

echo
echo "================================================"
echo "                 DIMM DIAGNOSTICS"
echo "================================================"
echo "Manufacturer       : ${MANUFACTURER:-Unknown}"
echo "Model              : ${PRODUCT:-Unknown}"
echo "System version     : ${VERSION:-Unknown}"
echo "Selected profile   : $MODEL"
echo "Mapping status     : $MAPPING_STATUS"
echo "Mapping scope      : $MAPPING_SCOPE"
echo "Channels / CPU     : $CHANNELS_PER_CPU"
echo "DIMMs / channel    : $DIMMS_PER_CHANNEL"
echo "DIMMs / CPU        : $DIMMS_PER_CPU"
echo
echo "Platform layout:"
echo "$MODEL_NOTE"

if [[ "$MODEL" == "HPE_BL460C_GEN9" ]]; then
    echo "EDAC driver        : ${CFG[$MODEL:edac_driver]:-Unknown}"
    echo "EDAC mapping       : logical controller/channel only"
    echo "SMBIOS correlation: candidate DIMMs are listed by processor; channel-to-slot mapping is not asserted"
fi

if [[ "$MAPPING_STATUS" == "REFERENCE_ONLY" ]]; then
    echo
    echo "NOTE: This profile describes physical layout only."
    echo "      EDAC-to-physical-slot translation is not validated."
fi

# ==========================================================
# 4. READ INSTALLED DIMMs FROM SMBIOS TYPE 17
# ==========================================================

declare -A DIMM_INSTALLED
declare -A DIMM_SIZE
declare -A DIMM_PART

while IFS='|' read -r LOCATOR SIZE PART; do
    [[ -z "$LOCATOR" ]] && continue
    LOCATOR="$(trim "$LOCATOR")"
    DIMM_INSTALLED["$LOCATOR"]=1
    DIMM_SIZE["$LOCATOR"]="$SIZE"
    DIMM_PART["$LOCATOR"]="$PART"
done < <(
    dmidecode -t 17 2>/dev/null |
    awk '
        BEGIN { RS=""; FS="\n" }
        {
            locator=""; size=""; part=""
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[[:space:]]*Locator:/) {
                    sub(/^[[:space:]]*Locator:[[:space:]]*/, "", $i)
                    locator=$i
                }
                if ($i ~ /^[[:space:]]*Size:/) {
                    sub(/^[[:space:]]*Size:[[:space:]]*/, "", $i)
                    size=$i
                }
                if ($i ~ /^[[:space:]]*Part Number:/) {
                    sub(/^[[:space:]]*Part Number:[[:space:]]*/, "", $i)
                    part=$i
                }
            }
            if (locator != "" && size != "" &&
                size !~ /No Module Installed/ && size != "Unknown") {
                print locator "|" size "|" part
            }
        }
    '
)

echo
echo "------------------------------------------------"
echo "INSTALLED DIMM MODULES (SMBIOS TYPE 17)"
echo "------------------------------------------------"

if [[ ${#DIMM_INSTALLED[@]} -eq 0 ]]; then
    echo "WARNING: No installed DIMMs detected through SMBIOS."
else
    for LOCATOR in "${!DIMM_INSTALLED[@]}"; do
        echo "$LOCATOR - ${DIMM_SIZE[$LOCATOR]}"
        [[ -n "${DIMM_PART[$LOCATOR]}" ]] && echo "  Part Number: ${DIMM_PART[$LOCATOR]}"
    done | sort -V
fi

# ==========================================================
# 5. READ EDAC COUNTERS
# ==========================================================

declare -A EDAC_CE
declare -A EDAC_UE
declare -A EDAC_LABEL
declare -A EDAC_PATH
declare -A EDAC_HA
declare -A EDAC_LOCATION
declare -A EDAC_SIZE
declare -A EDAC_MC_NAME

echo
echo "------------------------------------------------"
echo "EDAC DIMM COUNTERS"
echo "------------------------------------------------"

EDAC_FOUND=0
UNPARSED_EDAC=0

if [[ -d "$EDAC_ROOT" ]]; then
    for DIR in "$EDAC_ROOT"/mc*/dimm*; do
        [[ -d "$DIR" ]] || continue
        EDAC_FOUND=1

        LABEL=$(cat "$DIR/dimm_label" 2>/dev/null)
        CE=$(cat "$DIR/dimm_ce_count" 2>/dev/null)
        UE=$(cat "$DIR/dimm_ue_count" 2>/dev/null)
        LOCATION=$(cat "$DIR/dimm_location" 2>/dev/null)
        DIMM_SIZE_MB=$(cat "$DIR/size" 2>/dev/null)
        MC_DIR="${DIR%/dimm*}"
        MC_NAME=$(cat "$MC_DIR/mc_name" 2>/dev/null)

        CE=${CE:-0}
        UE=${UE:-0}
        LABEL=${LABEL:-unknown}
        LOCATION=${LOCATION:-unknown}
        DIMM_SIZE_MB=${DIMM_SIZE_MB:-unknown}
        MC_NAME=${MC_NAME:-unknown}

        echo
        echo "EDAC path: $DIR"
        echo "Controller: $MC_NAME"
        echo "Label: $LABEL"
        echo "EDAC location: $LOCATION"
        echo "EDAC DIMM size: ${DIMM_SIZE_MB} MB"
        echo "Corrected errors: $CE"
        echo "Uncorrected errors: $UE"

        if [[ "$CE" =~ ^[0-9]+$ && "$UE" =~ ^[0-9]+$ ]]; then
            :
        else
            echo "WARNING: EDAC counter is not a non-negative integer."
            UNPARSED_EDAC=1
            continue
        fi

        if [[ "$LABEL" =~ SrcID#([0-9]+).*Ha#([0-9]+).*Chan#([0-9]+).*DIMM#([0-9]+) ]]; then
            SOCKET="${BASH_REMATCH[1]}"
            HA="${BASH_REMATCH[2]}"
            CHANNEL="${BASH_REMATCH[3]}"
            DIMM_INDEX="${BASH_REMATCH[4]}"
            KEY="${SOCKET}:${HA}:${CHANNEL}:${DIMM_INDEX}"
        elif [[ "$LABEL" =~ SrcID#([0-9]+).*Chan#([0-9]+).*DIMM#([0-9]+) ]]; then
            SOCKET="${BASH_REMATCH[1]}"
            HA="NA"
            CHANNEL="${BASH_REMATCH[2]}"
            DIMM_INDEX="${BASH_REMATCH[3]}"
            KEY="${SOCKET}:${HA}:${CHANNEL}:${DIMM_INDEX}"
        else
            echo "NOTE: EDAC label format is not recognized by this parser."
            UNPARSED_EDAC=1
            continue
        fi

        EDAC_CE["$KEY"]="$CE"
        EDAC_UE["$KEY"]="$UE"
        EDAC_LABEL["$KEY"]="$LABEL"
        EDAC_PATH["$KEY"]="$DIR"
        EDAC_HA["$KEY"]="$HA"
        EDAC_LOCATION["$KEY"]="$LOCATION"
        EDAC_SIZE["$KEY"]="$DIMM_SIZE_MB"
        EDAC_MC_NAME["$KEY"]="$MC_NAME"
    done
fi

if [[ "$EDAC_FOUND" -eq 0 ]]; then
    echo "No EDAC DIMM directories found."
fi

# ==========================================================
# 5A. NON-DESTRUCTIVE SMBIOS / EDAC CORRELATION FOR GEN9
# ==========================================================

if [[ "$MODEL" == "HPE_BL460C_GEN9" ]]; then
    echo
    echo "------------------------------------------------"
    echo "GEN9 SMBIOS / EDAC CORRELATION (CANDIDATES ONLY)"
    echo "------------------------------------------------"
    echo "The following is a processor-level candidate list, not a channel-to-slot map."
    echo "SrcID-to-PROC numbering is assumed from the observed two-socket system."
    for SRCID in 0 1; do
        PROC=$((SRCID + 1))
        echo
        echo "SrcID#$SRCID -> assumed PROC $PROC"
        MATCHED=0
        for LOCATOR in "PROC $PROC DIMM 1" "PROC $PROC DIMM 2" "PROC $PROC DIMM 3" "PROC $PROC DIMM 4" "PROC $PROC DIMM 5" "PROC $PROC DIMM 6" "PROC $PROC DIMM 7" "PROC $PROC DIMM 8"; do
            if [[ -n "${DIMM_INSTALLED[$LOCATOR]+x}" ]]; then
                echo "  Candidate installed DIMM: $LOCATOR (${DIMM_SIZE[$LOCATOR]})"
                MATCHED=1
            fi
        done
        [[ "$MATCHED" -eq 0 ]] && echo "  No installed DIMM locator found for this processor."
    done
    echo
    echo "No physical slot is assigned to Chan#0/Chan#1 by this report."
fi

# ==========================================================
# 6. ANALYZE EDAC ERRORS AND APPLY VERIFIED MAP
# ==========================================================

echo
echo "================================================"
echo "              POTENTIAL FAULTY DIMMs"
echo "================================================"

FOUND=0
MAPPING_WARNING=0

for KEY in "${!EDAC_CE[@]}"; do
    CE="${EDAC_CE[$KEY]}"
    UE="${EDAC_UE[$KEY]}"
    TOTAL=$((CE + UE))

    if [[ "$TOTAL" -eq 0 ]]; then
        continue
    fi

    IFS=: read -r SOCKET HA CHANNEL DIMM_INDEX <<< "$KEY"

    # This socket conversion is part of the existing BL460c Gen8
    # mapping convention. Do not generalize it to another EDAC driver
    # without validation.
    PROC=$((SOCKET + 1))

    echo
    echo "------------------------------------------------"
    echo "EDAC LABEL: ${EDAC_LABEL[$KEY]}"
    echo "Socket ID / SrcID: $SOCKET"
    echo "HA: $HA"
    echo "Processor index (assumed): PROC $PROC"
    echo "Channel: $CHANNEL"
    echo "EDAC location: ${EDAC_LOCATION[$KEY]}"
    echo "EDAC DIMM size: ${EDAC_SIZE[$KEY]} MB"
    echo "DIMM index: $DIMM_INDEX"
    echo "Corrected errors: $CE"
    echo "Uncorrected errors: $UE"

    if [[ "$MAPPING_STATUS" == "VERIFIED" && "$MODEL" == "HPE_BL460C_GEN8" ]]; then
        MAP_KEY="${MODEL}:edac_map_${CHANNEL}_${DIMM_INDEX}"
        SLOT="${CFG[$MAP_KEY]}"

        if [[ ! "$SLOT" =~ ^[1-9][0-9]*$ ]]; then
            echo "WARNING: No valid physical slot mapping for this EDAC index."
            MAPPING_WARNING=1
        else
            LETTER="${CFG[$MODEL:slot_label_$SLOT]}"
            DMI_LOCATOR="PROC $PROC DIMM $SLOT"

            if [[ -z "$LETTER" ]]; then
                echo "WARNING: Physical slot label is missing in configuration."
                MAPPING_WARNING=1
            else
                echo
                echo "POTENTIAL DIMM:"
                echo "$DMI_LOCATOR (P$PROC-$LETTER)"

                if [[ -n "${DIMM_INSTALLED[$DMI_LOCATOR]+x}" ]]; then
                    echo "SMBIOS status: INSTALLED"
                    echo "DIMM size: ${DIMM_SIZE[$DMI_LOCATOR]}"
                    [[ -n "${DIMM_PART[$DMI_LOCATOR]}" ]] && echo "Part Number: ${DIMM_PART[$DMI_LOCATOR]}"
                else
                    echo "WARNING: SMBIOS does not confirm locator: $DMI_LOCATOR"
                    echo "Available SMBIOS locator strings may use another naming scheme."
                    MAPPING_WARNING=1
                fi
            fi
        fi
    else
        echo
        echo "EDAC logical DIMM identified:"
        echo "${EDAC_LABEL[$KEY]}"
        echo "Physical DIMM connector: NOT DETERMINED"
        echo "Reason: no validated EDAC-to-physical-slot translation."
        MAPPING_WARNING=1
    fi

    if [[ "$UE" -gt 0 ]]; then
        echo "SEVERITY: UNCORRECTED ERRORS"
    else
        echo "SEVERITY: CORRECTED ERRORS"
    fi

    FOUND=1
done

# ==========================================================
# 7. FINAL DIAGNOSIS
# ==========================================================

echo
echo "================================================"
echo "                 FINAL RESULT"
echo "================================================"

if [[ "$FOUND" -eq 1 ]]; then
    echo "Potential DIMM candidate(s) detected."
else
    echo "No errors detected in the EDAC DIMM counters that were read and recognized."
fi

if [[ "$EDAC_FOUND" -eq 0 ]]; then
    echo "WARNING: EDAC data is unavailable."
fi

if [[ "$UNPARSED_EDAC" -eq 1 ]]; then
    echo "WARNING: Some EDAC entries could not be parsed."
fi

if [[ "$MAPPING_WARNING" -eq 1 ]]; then
    echo "WARNING: Physical slot mapping is unavailable or requires verification."
fi

echo
echo "Possible causes of memory errors:"
echo " 1. Faulty DIMM module"
echo " 2. DIMM slot or contact"
echo " 3. CPU memory controller"
echo " 4. CPU socket"
echo " 5. Motherboard"

echo
echo "NOTES:"
echo "EDAC counters do not prove physical DIMM failure."
echo "They identify the logical memory location reporting errors."
echo "SMBIOS Type 17 provides firmware-reported DIMM inventory."
echo "Only VERIFIED configuration mappings are used for physical identification."
echo "REFERENCE_ONLY profiles may show SMBIOS candidate lists, never physical slot assignments."
echo "================================================"
echo
