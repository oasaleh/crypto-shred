#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Crypto-Shred${NC}"
echo -e "Encrypt → Fill → Destroy key\n"

# Detect external drives
disks=()
while IFS= read -r line; do
    disks+=("$line")
done < <(diskutil list external physical 2>/dev/null | grep -o '/dev/disk[0-9]*')

if [[ ${#disks[@]} -eq 0 ]]; then
    echo -e "${RED}No external drives found.${NC}"
    exit 1
fi

# Display drives
echo -e "${BOLD}External drives:${NC}"
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

    echo -e "${YELLOW}${label} Step 4/4 — Destroying key — reformatting as ${FINAL_FS}...${NC}"
    if ! diskutil eraseDisk "$FINAL_FS" "USB" GPT "$disk" > /dev/null 2>&1; then
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

# Wait for all to finish
failed=0
for pid in "${pids[@]}"; do
    wait "$pid" || ((failed++))
done

echo ""
if (( failed == 0 )); then
    echo -e "${GREEN}${BOLD}All ${#selected[@]} drive(s) crypto-shredded successfully.${NC}"
else
    echo -e "${RED}${BOLD}${failed} drive(s) failed. Check output above.${NC}"
    exit 1
fi
