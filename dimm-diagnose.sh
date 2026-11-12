
#!/bin/bash
#
# DIMM DIAGNOSE
#
# Linux memory error analysis using:
#   - dmidecode
#   - EDAC sysfs
#
# Supported platform mapping:
#   HP ProLiant BL460c Gen8
#
# Run:
#   chmod +x dimm-diagnose.sh
#   sudo ./dimm-diagnose.sh
#

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

# ==================================================
# 2. SYSTEM IDENTIFICATION
# ==================================================

MANUFACTURER=$(dmidecode -s system-manufacturer 2>/dev/null)
PRODUCT=$(dmidecode -s system-product-name 2>/dev/null)

echo
echo "================================================"
echo "                 DIMM DIAGNOSTICS"
echo "================================================"

echo "Manufacturer : $MANUFACTURER"
echo "Model        : $PRODUCT"

IS_HP_BL460=0

if [[ "$PRODUCT" == *"BL460c Gen8"* ]]; then
    IS_HP_BL460=1
fi

# ==================================================
# 3. HP BL460c GEN8 SLOT MAPPING
# ==================================================
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
#

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
# 4. READ INSTALLED DIMMs FROM DMI
# ==================================================

declare -A DIMM_INSTALLED
declare -A DIMM_SIZE
declare -A DIMM_PART

while IFS='|' read -r LOCATOR SIZE PART; do

    [[ -z "$LOCATOR" ]] && continue

    if [[ "$LOCATOR" =~ PROC[[:space:]]*([0-9]+)[[:space:]]*DIMM[[:space:]]*([0-9]+) ]]; then

        PROC="${BASH_REMATCH[1]}"
        SLOT="${BASH_REMATCH[2]}"

        KEY="${PROC}:${SLOT}"

        DIMM_INSTALLED["$KEY"]=1
        DIMM_SIZE["$KEY"]="$SIZE"
        DIMM_PART["$KEY"]="$PART"

    fi

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

# ==================================================
# 5. DISPLAY INSTALLED DIMMs
# ==================================================

echo
echo "------------------------------------------------"
echo "INSTALLED DIMM MODULES"
echo "------------------------------------------------"

if [[ ${#DIMM_INSTALLED[@]} -eq 0 ]]; then

    echo "WARNING: No installed DIMMs detected through DMI."

else

    for KEY in "${!DIMM_INSTALLED[@]}"; do

        PROC="${KEY%%:*}"
        SLOT="${KEY##*:}"

        echo "PROC $PROC DIMM $SLOT - ${DIMM_SIZE[$KEY]}"

        if [[ -n "${DIMM_PART[$KEY]}" ]]; then
            echo "  Part Number: ${DIMM_PART[$KEY]}"
        fi

    done | sort -V

fi

# ==================================================
# 6. READ EDAC COUNTERS
# ==================================================

declare -A EDAC_CE
declare -A EDAC_UE
declare -A EDAC_LABEL

echo
echo "------------------------------------------------"
echo "EDAC DIMM COUNTERS"
echo "------------------------------------------------"

for DIR in /sys/devices/system/edac/mc/mc*/dimm*; do

    [[ -d "$DIR" ]] || continue

    LABEL=$(cat "$DIR/dimm_label" 2>/dev/null)
    CE=$(cat "$DIR/dimm_ce_count" 2>/dev/null)
    UE=$(cat "$DIR/dimm_ue_count" 2>/dev/null)

    CE=${CE:-0}
    UE=${UE:-0}

    echo
    echo "Label: ${LABEL:-unknown}"
    echo "Corrected errors: $CE"
    echo "Uncorrected errors: $UE"

    if [[ "$LABEL" =~ SrcID#([0-9]+).*Chan#([0-9]+).*DIMM#([0-9]+) ]]; then

        SOCKET="${BASH_REMATCH[1]}"
        CHANNEL="${BASH_REMATCH[2]}"
        DIMM_INDEX="${BASH_REMATCH[3]}"

        KEY="${SOCKET}:${CHANNEL}:${DIMM_INDEX}"

        EDAC_CE["$KEY"]="$CE"
        EDAC_UE["$KEY"]="$UE"
        EDAC_LABEL["$KEY"]="$LABEL"

    fi

done

# ==================================================
# 7. ANALYZE EDAC ERRORS
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

    PROC=$((SOCKET + 1))

    echo
    echo "------------------------------------------------"
    echo "EDAC LABEL: ${EDAC_LABEL[$KEY]}"
    echo "Socket: $SOCKET"
    echo "Processor: PROC $PROC"
    echo "Channel: $CHANNEL"
    echo "DIMM index: $DIMM_INDEX"
    echo "Corrected errors: $CE"
    echo "Uncorrected errors: $UE"

    if [[ "$IS_HP_BL460" -eq 1 ]]; then

        MAP_KEY="${CHANNEL}:${DIMM_INDEX}"
        SLOT="${SLOT_MAP[$MAP_KEY]}"

        if [[ -z "$SLOT" ]]; then

            echo "WARNING: No physical slot mapping available."
            MAPPING_WARNING=1
            continue

        fi

        LETTER="${SLOT_LETTER[$SLOT]}"
        DMI_KEY="${PROC}:${SLOT}"

        echo
        echo "POTENTIAL DIMM:"
        echo "PROC $PROC DIMM $SLOT (P$PROC-$LETTER)"

        if [[ -n "${DIMM_INSTALLED[$DMI_KEY]+x}" ]]; then

            echo "DMI status: INSTALLED"
            echo "DIMM size: ${DIMM_SIZE[$DMI_KEY]}"

            if [[ -n "${DIMM_PART[$DMI_KEY]}" ]]; then
                echo "Part Number: ${DIMM_PART[$DMI_KEY]}"
            fi

        else

            echo "WARNING: DMI does not confirm this DIMM as installed."
            MAPPING_WARNING=1

        fi

        if [[ "$UE" -gt 0 ]]; then
            echo "SEVERITY: UNCORRECTED ERRORS"
        else
            echo "SEVERITY: CORRECTED ERRORS"
        fi

        FOUND=1

    else

        echo
        echo "GENERIC PLATFORM"
        echo "EDAC logical DIMM identified:"
        echo "${EDAC_LABEL[$KEY]}"
        echo "Physical slot mapping is not configured."

        FOUND=1
        MAPPING_WARNING=1

    fi

done

# ==================================================
# 8. FINAL DIAGNOSIS
# ==================================================

echo
echo "================================================"
echo "                 FINAL RESULT"
echo "================================================"

if [[ "$FOUND" -eq 1 ]]; then

    echo "Potential DIMM candidate(s) detected."

else

    echo "No DIMM errors detected in EDAC counters."

fi

if [[ "$MAPPING_WARNING" -eq 1 ]]; then
    echo
    echo "WARNING: Physical slot mapping requires verification."
fi

echo
echo "Possible causes of memory errors:"
echo " 1. Faulty DIMM module"
echo " 2. DIMM slot or contact"
echo " 3. CPU memory controller"
echo " 4. CPU socket"
echo " 5. Motherboard"
echo
echo "NOTE:"
echo "EDAC error counters do not prove physical DIMM failure."
echo "They identify the logical DIMM/channel reporting errors."
echo "================================================"
echo
