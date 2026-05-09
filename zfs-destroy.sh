#!/bin/bash
# Usage: ./zfs-destroy.sh <vmid>
# Example: ./zfs-destroy.sh 100

VMID=$1
[ -z "$VMID" ] && echo "ERROR: VMID required" && exit 1

TARGETS=$(zfs list -H -o name -t vol,snap -S creation | grep -E "/vm-$VMID-disk-[0-9]+(\.[0-9]{14})?(@|$)")
[ -z "$TARGETS" ] && echo "INFO: nothing to delete for VM $VMID" && exit 0

echo "INFO: targets (newest first):"
echo "$TARGETS"
read -p "Type 'y' to destroy: " ANSWER
[ "$ANSWER" = "y" ] || { echo "INFO: cancelled"; exit 0; }

echo "$TARGETS" | xargs -tn1 zfs destroy
