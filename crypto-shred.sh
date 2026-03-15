#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Crypto-Shred${NC}"
echo -e "Encrypt → Fill → Destroy key\n"

# Detect removable drives (external USB + internal SD card reader)
# Find the physical disk backing the boot volume, so we never touch it
boot_container=$(diskutil info / | awk -F: '/Part of Whole/{print $2}' | xargs)
boot_phys=$(diskutil info "$boot_container" | awk -F: '/Physical Store/{print $2}' | xargs | sed 's/s[0-9]*$//')

disks=()
while IFS= read -r line; do
    disks+=("$line")
done < <(diskutil list physical 2>/dev/null | grep -o '/dev/disk[0-9]*')

# Filter out the boot disk and disk images
filtered=()
for d in "${disks[@]}"; do
    disk_id=$(basename "$d")
    # Skip the boot disk
    if [[ "$disk_id" == "$boot_phys" ]]; then
        continue
    fi
    # Skip disk images
    proto=$(diskutil info "$d" 2>/dev/null | awk -F: '/Protocol/{print $2}' | xargs)
    if [[ "$proto" == "Disk Image" ]]; then
        continue
    fi
    filtered+=("$d")
done
disks=("${filtered[@]}")

if [[ ${#disks[@]} -eq 0 ]]; then
    echo -e "${RED}No removable drives found.${NC}"
    exit 1
fi

# Display drives
echo -e "${BOLD}Available drives:${NC}"
for i in "${!disks[@]}"; do
    disk="${disks[$i]}"
    name=$(diskutil info "$disk" | awk -F: '/Media Name/{print $2}' | xargs)
    size=$(diskutil info "$disk" | awk -F: '/Disk Size/{print $2}' | xargs)
    echo -e "  ${GREEN}$((i+1)))${NC} $disk — $name ($size)"
done

echo -e "\nSelect drives to shred (e.g. ${BOLD}1 2 3${NC} or ${BOLD}all${NC}):"
read -rp "> " selection

# Parse selection
selected=()
if [[ "$selection" == "all" ]]; then
    selected=("${disks[@]}")
else
    for n in $selection; do
        idx=$((n - 1))
        if (( idx >= 0 && idx < ${#disks[@]} )); then
            selected+=("${disks[$idx]}")
        else
            echo -e "${RED}Invalid: $n${NC}"; exit 1
        fi
    done
fi

if [[ ${#selected[@]} -eq 0 ]]; then
    echo "Nothing selected."
    exit 1
fi

# Final format
echo -e "\n${BOLD}Final format after shred:${NC}"
echo "  1) ExFAT  (macOS + Windows)"
echo "  2) APFS   (macOS only)"
read -rp "Choice [1]: " fmt
fmt=${fmt:-1}

case $fmt in
    1) FINAL_FS="ExFAT" ;;
    2) FINAL_FS="APFS" ;;
    *) echo "Invalid."; exit 1 ;;
esac

# Confirm
echo -e "\n${RED}${BOLD}WARNING: ALL DATA WILL BE PERMANENTLY DESTROYED ON:${NC}"
for d in "${selected[@]}"; do
    name=$(diskutil info "$d" | awk -F: '/Media Name/{print $2}' | xargs)
    size=$(diskutil info "$d" | awk -F: '/Disk Size/{print $2}' | xargs)
    echo -e "  ${RED}• $d — $name ($size)${NC}"
done
echo -e "\nType ${BOLD}SHRED${NC} to confirm:"
read -rp "> " confirm
if [[ "$confirm" != "SHRED" ]]; then
    echo "Aborted."
    exit 0
fi

# One-time random passphrase (never saved anywhere)
PASS=$(openssl rand -base64 48)

shred_drive() {
    local disk=$1
    local label="[$(basename "$disk")]"

    echo -e "${YELLOW}${label} Step 1/4 — Formatting as APFS...${NC}"
    local out
    if ! out=$(diskutil eraseDisk APFS "CryptoShred" GPT "$disk" 2>&1); then
        echo -e "${RED}${label} Failed to format: ${out}${NC}"; return 1
    fi

    # Find the APFS container, then the volume inside it
    local container vol
    container=$(diskutil list "$disk" | awk '/Apple_APFS/{print $NF; exit}')
    if [[ -z "$container" ]]; then
        echo -e "${RED}${label} Could not find APFS container.${NC}"; return 1
    fi
    # The container is a partition (e.g. disk6s2) — find the synthesized container disk
    local container_disk
    container_disk=$(diskutil info "$container" | awk -F: '/APFS Container:/{print $2}' | xargs)
    if [[ -z "$container_disk" ]]; then
        echo -e "${RED}${label} Could not find APFS container disk.${NC}"; return 1
    fi
    vol=$(diskutil list "$container_disk" | awk '/APFS Volume/{print $NF; exit}')
    if [[ -z "$vol" ]]; then
        echo -e "${RED}${label} Could not find APFS volume.${NC}"; return 1
    fi

    echo -e "${YELLOW}${label} Step 2/4 — Encrypting volume (${vol})...${NC}"
    if ! diskutil apfs encryptVolume "$vol" -user disk -passphrase "$PASS" > /dev/null 2>&1; then
        echo -e "${RED}${label} Failed to encrypt.${NC}"; return 1
    fi
    sleep 2

    echo -e "${YELLOW}${label} Step 3/4 — Filling with encrypted zeros (this takes a while)...${NC}"
    local mnt
    mnt=$(diskutil info "$vol" | awk -F: '/Mount Point/{print $2}' | xargs)
    if [[ -n "$mnt" && -d "$mnt" ]]; then
        dd if=/dev/zero of="${mnt}/.fill" bs=1m 2>/dev/null || true
        sync
    else
        echo -e "${RED}${label} Volume not mounted, skipping fill.${NC}"
    fi

    # Name based on drive type
    local drive_label="USB"
    local drive_proto
    drive_proto=$(diskutil info "$disk" 2>/dev/null | awk -F: '/Protocol/{print $2}' | xargs)
    if [[ "$drive_proto" == "Secure Digital" ]]; then
        drive_label="SD"
    fi

    echo -e "${YELLOW}${label} Step 4/4 — Destroying key — reformatting as ${FINAL_FS}...${NC}"
    if ! diskutil eraseDisk "$FINAL_FS" "$drive_label" GPT "$disk" > /dev/null 2>&1; then
        echo -e "${RED}${label} Failed final format.${NC}"; return 1
    fi

    echo -e "${GREEN}${label} Crypto-shred complete.${NC}"
}

echo ""
# Run all drives in parallel
pids=()
for d in "${selected[@]}"; do
    shred_drive "$d" &
    pids+=($!)
done

# Progress monitor — prints status every 3 minutes
show_progress() {
    while true; do
        sleep 180
        # Check if any shred processes are still running
        local any_alive=false
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                any_alive=true
                break
            fi
        done
        $any_alive || return

        echo -e "\n${BOLD}— Progress ($(date +%H:%M:%S)) —${NC}"
        # Collect rows
        local rows=()
        for vol in /Volumes/CryptoShred*; do
            [[ -d "$vol" ]] || continue
            local volname disk media size_hr fill_hr size_bytes fill_bytes pct
            volname=$(basename "$vol")
            disk=$(diskutil info "$vol" 2>/dev/null | awk -F: '/Part of Whole/{print $2}' | xargs)
            media=$(diskutil info "/dev/$disk" 2>/dev/null | awk -F: '/Media Name/{print $2}' | xargs)
            size_hr=$(diskutil info "/dev/$disk" 2>/dev/null | awk -F'[()]' '/Disk Size/{print $2}' | grep -o '^[0-9.]* [A-Z]*')
            size_bytes=$(diskutil info "/dev/$disk" 2>/dev/null | awk -F'[()]' '/Disk Size/{print $2}' | grep -o '[0-9]*')
            fill_bytes=$(stat -f%z "$vol/.fill" 2>/dev/null || echo 0)
            if [[ -n "$size_bytes" && "$size_bytes" -gt 0 ]]; then
                # Human-readable fill size
                if (( fill_bytes >= 1073741824 )); then
                    fill_hr="$(awk "BEGIN{printf \"%.1f GB\", $fill_bytes/1073741824}")"
                elif (( fill_bytes >= 1048576 )); then
                    fill_hr="$(awk "BEGIN{printf \"%.0f MB\", $fill_bytes/1048576}")"
                else
                    fill_hr="$(awk "BEGIN{printf \"%.0f KB\", $fill_bytes/1024}")"
                fi
                pct=$((fill_bytes * 100 / size_bytes))
                # Find the physical disk (container's parent)
                local phys_disk
                phys_disk=$(diskutil info "$vol" 2>/dev/null | awk -F: '/Part of Whole/{print $2}' | xargs)
                phys_disk=$(diskutil info "$phys_disk" 2>/dev/null | awk -F: '/APFS Physical Store/{print $2}' | xargs | sed 's/s[0-9]*$//')
                [[ -z "$phys_disk" ]] && phys_disk="$disk"
                rows+=("${volname}|${phys_disk}|${media}|${size_hr}|${fill_hr}|~${pct}%")
            fi
        done

        if [[ ${#rows[@]} -gt 0 ]]; then
            # Calculate column widths
            local w1=6 w2=4 w3=5 w4=4 w5=6 w6=8  # minimum header widths
            for row in "${rows[@]}"; do
                IFS='|' read -r c1 c2 c3 c4 c5 c6 <<< "$row"
                (( ${#c1} > w1 )) && w1=${#c1}
                (( ${#c2} > w2 )) && w2=${#c2}
                (( ${#c3} > w3 )) && w3=${#c3}
                (( ${#c4} > w4 )) && w4=${#c4}
                (( ${#c5} > w5 )) && w5=${#c5}
                (( ${#c6} > w6 )) && w6=${#c6}
            done

            # Print table
            local hline="+-$(printf '%*s' $w1 '' | tr ' ' '-')-+-$(printf '%*s' $w2 '' | tr ' ' '-')-+-$(printf '%*s' $w3 '' | tr ' ' '-')-+-$(printf '%*s' $w4 '' | tr ' ' '-')-+-$(printf '%*s' $w5 '' | tr ' ' '-')-+-$(printf '%*s' $w6 '' | tr ' ' '-')-+"
            echo "$hline"
            printf "| ${BOLD}%-${w1}s${NC} | ${BOLD}%-${w2}s${NC} | ${BOLD}%-${w3}s${NC} | ${BOLD}%-${w4}s${NC} | ${BOLD}%-${w5}s${NC} | ${BOLD}%-${w6}s${NC} |\n" "Volume" "Disk" "Drive" "Size" "Filled" "Progress"
            echo "$hline"
            for row in "${rows[@]}"; do
                IFS='|' read -r c1 c2 c3 c4 c5 c6 <<< "$row"
                printf "| %-${w1}s | %-${w2}s | %-${w3}s | %-${w4}s | %-${w5}s | %-${w6}s |\n" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6"
            done
            echo "$hline"
        fi
    done
}
show_progress &
progress_pid=$!

# Wait for all to finish
failed=0
for pid in "${pids[@]}"; do
    wait "$pid" || ((failed++))
done

# Stop the progress monitor
kill "$progress_pid" 2>/dev/null
wait "$progress_pid" 2>/dev/null

echo ""
if (( failed == 0 )); then
    echo -e "${GREEN}${BOLD}All ${#selected[@]} drive(s) crypto-shredded successfully.${NC}"
else
    echo -e "${RED}${BOLD}${failed} drive(s) failed. Check output above.${NC}"
    exit 1
fi
