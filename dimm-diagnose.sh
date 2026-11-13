#!/bin/bash
#
# DIMM DIAGNOSE
#
# Linux memory error analysis using:
#   - dmidecode / SMBIOS Type 17
#   - EDAC sysfs counters
#   - Model identification
#
# Implemented physical slot mapping:
#   - HPE ProLiant BL460c Gen8
#
# Reference-only platform layouts:
#   - HPE ProLiant DL380 Gen10
#   - Dell PowerEdge R630
#   - Dell PowerEdge R740
#   - Dell PowerEdge R750
#   - Lenovo ThinkSystem SR650 (1st generation)
#
#  Downloaad also dimm-mapping.conf
#
# Version: 0.6
# Tested: Not yet validated on all listed platforms.
# License: CC BY-SA 4.0
# Author: Hrvoje Horvat

export LC_ALL=C

# ==================================================
# 1. BASIC CHECKS
# ==================================================

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

if ! command -v dmidecode >/dev/null 2>&1; then
    echo "ERROR: dmidecode is not installed."
    exit 1
fi

EDAC_ROOT="/sys/devices/system/edac/mc"

if [[ ! -d "$EDAC_ROOT" ]]; then
    echo "WARNING: EDAC sysfs directory not found."
    echo "The kernel may not expose EDAC memory-controller data."
fi

# ==================================================
# 2. SYSTEM IDENTIFICATION
# ==================================================

MANUFACTURER=$(dmidecode -s system-manufacturer 2>/dev/null)
PRODUCT=$(dmidecode -s system-product-name 2>/dev/null)
VERSION=$(dmidecode -s system-version 2>/dev/null)

MODEL="GENERIC"
MAPPING_STATUS="NOT CONFIGURED"
MODEL_NOTE="No platform-specific physical DIMM mapping is available."

case "$PRODUCT" in
    *"BL460c Gen8"*)
        MODEL="HPE_BL460C_GEN8"
        MAPPING_STATUS="IMPLEMENTED"
        MODEL_NOTE="HPE ProLiant BL460c Gen8 physical slot mapping."
        ;;
    *"DL380 Gen10"*)
        MODEL="HPE_DL380_GEN10"
        MODEL_NOTE="12 DIMM connectors per processor; 6 memory channels."
        ;;
    *"PowerEdge R630"*)
        MODEL="DELL_R630"
        MODEL_NOTE="4 memory channels per processor; up to 3 DIMMs per channel."
        ;;
    *"PowerEdge R740"*)
        MODEL="DELL_R740"
        MODEL_NOTE="6 memory channels per processor; up to 2 DIMMs per channel."
        ;;
    *"PowerEdge R750"*)
        MODEL="DELL_R750"
        MODEL_NOTE="16 DIMM connectors per processor in documented configurations."
        ;;
    *"ThinkSystem SR650"*)
        MODEL="LENOVO_SR650"
        MODEL_NOTE="First-generation SR650 reference: 12 DIMM connectors per processor."
        ;;
esac

echo
echo "================================================"
echo "                 DIMM DIAGNOSTICS"
echo "================================================"
echo "Manufacturer : ${MANUFACTURER:-Unknown}"
echo "Model        : ${PRODUCT:-Unknown}"
echo "Version      : ${VERSION:-Unknown}"
echo "Profile      : $MODEL"
echo "Mapping      : $MAPPING_STATUS"
echo
echo "Platform note:"
echo "$MODEL_NOTE"

# ==================================================
# 3. HPE BL460c GEN8 PHYSICAL SLOT MAPPING
# ==================================================
#
# This is the only physical EDAC mapping implemented
# in this version.
#
# Channel 1: A / E
# Channel 2: B / F
# Channel 3: C / G
# Channel 4: D / H
#
# DMI slot numbers:
#   1=A, 2=E, 3=B, 4=F,
#   5=H, 6=D, 7=G, 8=C
#
# EDAC DIMM index:
#   DIMM#0 = first slot in channel
#   DIMM#1 = second slot in channel

declare -A SLOT_MAP
declare -A SLOT_LETTER

SLOT_MAP["1:0"]=1
SLOT_MAP["1:1"]=2
SLOT_MAP["2:0"]=3
SLOT_MAP["2:1"]=4
SLOT_MAP["3:0"]=8
SLOT_MAP["3:1"]=7
SLOT_MAP["4:0"]=6
SLOT_MAP["4:1"]=5

SLOT_LETTER[1]="A"
SLOT_LETTER[2]="E"
SLOT_LETTER[3]="B"
SLOT_LETTER[4]="F"
SLOT_LETTER[5]="H"
SLOT_LETTER[6]="D"
SLOT_LETTER[7]="G"
SLOT_LETTER[8]="C"

# ==================================================
# 4. READ INSTALLED DIMMs FROM SMBIOS TYPE 17
# ==================================================

declare -A DIMM_INSTALLED
declare -A DIMM_SIZE
declare -A DIMM_PART

while IFS='|' read -r LOCATOR SIZE PART; do
    [[ -z "$LOCATOR" ]] && continue

    DIMM_INSTALLED["$LOCATOR"]=1
    DIMM_SIZE["$LOCATOR"]="$SIZE"
    DIMM_PART["$LOCATOR"]="$PART"

done < <(
    dmidecode -t 17 2>/dev/null |
    awk '
        BEGIN {
            RS=""
            FS="\n"
        }
        {
            locator=""
            size=""
            part=""

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

            if (locator != "" &&
                size != "" &&
                size !~ /No Module Installed/ &&
                size != "Unknown") {
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

        if [[ -n "${DIMM_PART[$LOCATOR]}" ]]; then
            echo "  Part Number: ${DIMM_PART[$LOCATOR]}"
        fi
    done | sort -V
fi

# ==================================================
# 5. READ EDAC COUNTERS
# ==================================================

declare -A EDAC_CE
declare -A EDAC_UE
declare -A EDAC_LABEL
declare -A EDAC_PATH

echo
echo "------------------------------------------------"
echo "EDAC DIMM COUNTERS"
echo "------------------------------------------------"

EDAC_FOUND=0

for DIR in "$EDAC_ROOT"/mc*/dimm*; do
    [[ -d "$DIR" ]] || continue

    EDAC_FOUND=1

    LABEL=$(cat "$DIR/dimm_label" 2>/dev/null)
    CE=$(cat "$DIR/dimm_ce_count" 2>/dev/null)
    UE=$(cat "$DIR/dimm_ue_count" 2>/dev/null)

    CE=${CE:-0}
    UE=${UE:-0}
    LABEL=${LABEL:-unknown}

    echo
    echo "EDAC path: $DIR"
    echo "Label: $LABEL"
    echo "Corrected errors: $CE"
    echo "Uncorrected errors: $UE"

    # This parser supports the label format used by
    # the original script. Other EDAC drivers may
    # expose different label formats.

    if [[ "$LABEL" =~ SrcID#([0-9]+).*Chan#([0-9]+).*DIMM#([0-9]+) ]]; then
        SOCKET="${BASH_REMATCH[1]}"
        CHANNEL="${BASH_REMATCH[2]}"
        DIMM_INDEX="${BASH_REMATCH[3]}"

        KEY="${SOCKET}:${CHANNEL}:${DIMM_INDEX}"

        EDAC_CE["$KEY"]="$CE"
        EDAC_UE["$KEY"]="$UE"
        EDAC_LABEL["$KEY"]="$LABEL"
        EDAC_PATH["$KEY"]="$DIR"
    else
        echo "NOTE: EDAC label format is not recognized by this parser."
    fi
done

if [[ "$EDAC_FOUND" -eq 0 ]]; then
    echo "No EDAC DIMM directories found."
fi

# ==================================================
# 6. ANALYZE EDAC ERRORS
# ==================================================

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

    IFS=: read -r SOCKET CHANNEL DIMM_INDEX <<< "$KEY"

    # The original EDAC label convention used by this
    # script treats SrcID as a zero-based socket index.
    # Verify this assumption for every new EDAC driver.
    PROC=$((SOCKET + 1))

    echo
    echo "------------------------------------------------"
    echo "EDAC LABEL: ${EDAC_LABEL[$KEY]}"
    echo "Socket ID: $SOCKET"
    echo "Processor: PROC $PROC"
    echo "Channel: $CHANNEL"
    echo "DIMM index: $DIMM_INDEX"
    echo "Corrected errors: $CE"
    echo "Uncorrected errors: $UE"

    if [[ "$MODEL" == "HPE_BL460C_GEN8" ]]; then
        MAP_KEY="${CHANNEL}:${DIMM_INDEX}"
        SLOT="${SLOT_MAP[$MAP_KEY]}"

        if [[ -z "$SLOT" ]]; then
            echo "WARNING: No physical slot mapping for this EDAC index."
            MAPPING_WARNING=1
            continue
        fi

        LETTER="${SLOT_LETTER[$SLOT]}"
        DMI_LOCATOR="PROC $PROC DIMM $SLOT"

        echo
        echo "POTENTIAL DIMM:"
        echo "$DMI_LOCATOR (P$PROC-$LETTER)"

        # Verify the corresponding DMI locator.
        if [[ -n "${DIMM_INSTALLED[$DMI_LOCATOR]+x}" ]]; then
            echo "SMBIOS status: INSTALLED"
            echo "DIMM size: ${DIMM_SIZE[$DMI_LOCATOR]}"

            if [[ -n "${DIMM_PART[$DMI_LOCATOR]}" ]]; then
                echo "Part Number: ${DIMM_PART[$DMI_LOCATOR]}"
            fi
        else
            echo "WARNING: SMBIOS does not confirm this DIMM locator."
            MAPPING_WARNING=1
        fi
    else
        echo
        echo "GENERIC / REFERENCE PLATFORM"
        echo "EDAC logical DIMM identified:"
        echo "${EDAC_LABEL[$KEY]}"
        echo "Physical DIMM connector: NOT DETERMINED"
        echo "A validated model-specific EDAC mapping is required."
        MAPPING_WARNING=1
    fi

    if [[ "$UE" -gt 0 ]]; then
        echo "SEVERITY: UNCORRECTED ERRORS"
    else
        echo "SEVERITY: CORRECTED ERRORS"
    fi

    FOUND=1
done

# ==================================================
# 7. FINAL DIAGNOSIS
# ==================================================

echo
echo "================================================"
echo "                 FINAL RESULT"
echo "================================================"

if [[ "$FOUND" -eq 1 ]]; then
    echo "Potential DIMM candidate(s) detected."
else
    echo "No DIMM errors detected in recognized EDAC counters."
fi

if [[ "$EDAC_FOUND" -eq 0 ]]; then
    echo "WARNING: EDAC data is unavailable."
fi

if [[ "$MAPPING_WARNING" -eq 1 ]]; then
    echo
    echo "WARNING: Physical slot mapping is not fully verified."
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
echo "SMBIOS Type 17 reports firmware-provided DIMM inventory."
echo "Physical slot identification requires a validated platform map."
echo "================================================"
echo
