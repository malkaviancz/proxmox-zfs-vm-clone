#!/bin/bash
# Usage: ./zfs-clone.sh <vmid> <snap>
# Example: ./zfs-clone.sh 100 snap1

VMID=$1; SNAP=$2
CONF="/etc/pve/qemu-server/$VMID.conf"
DISK_SLOT_RE="(ide|sata|scsi|virtio|efidisk|tpmstate)[0-9]+:"

# Validation
[ -z "$VMID" ] && echo "ERROR: VMID required" && exit 1
[ -z "$SNAP" ] && echo "ERROR: SNAP required" && exit 1
[ ! -f "$CONF" ] && echo "ERROR: VM $VMID not found" && exit 1
STATUS=$(qm status $VMID --verbose)
echo "$STATUS" | grep -q "^status: running" && echo "ERROR: VM $VMID is running" && exit 1
echo "$STATUS" | grep -q "^lock:" && echo "ERROR: VM $VMID is locked" && exit 1

# Try qm rollback first; on non-zero exit nothing was mutated, fall through.
if qm rollback $VMID $SNAP; then
    echo "INFO: qm rollback succeeded"
    exit 0
fi
echo "INFO: qm rollback declined; falling back to clone path"

SUFFIX=$(date +%Y%m%d%H%M%S)

BASE_ZVOLS=$(qm config $VMID --snapshot $SNAP | grep -E "^$DISK_SLOT_RE" | grep -oE "\bvm-$VMID-disk-[0-9]+\b" | sort -u)
[ -z "$BASE_ZVOLS" ] && echo "ERROR: no disks found for snapshot $SNAP" && exit 1
echo "INFO: disks found: $BASE_ZVOLS"

for BASE_ZVOL in $BASE_ZVOLS; do
    SRC_ZVOL=$(zfs list -H -o name -t snap | grep -E "/$BASE_ZVOL(\.[0-9]{14})?@$SNAP$" | sed 's/@.*//')
    [ -z "$SRC_ZVOL" ] && echo "ERROR: snapshot $SNAP not found for $BASE_ZVOL" && exit 1
    echo "INFO: source disk: $SRC_ZVOL"
    zfs list -H -o name | grep -q "/$BASE_ZVOL\.$SUFFIX$" && echo "ERROR: $BASE_ZVOL.$SUFFIX already exists" && exit 1
done

# Capture suffix-named disks in current VM section before rewrite (orphan disk candidates)
ORPHAN_ZVOLS=$(qm config $VMID | grep -E "^$DISK_SLOT_RE" | grep -oE "\bvm-$VMID-disk-[0-9]+\.[0-9]{14}\b" | sort -u)

# Execution: clone each disk
for BASE_ZVOL in $BASE_ZVOLS; do
    SRC_ZVOL=$(zfs list -H -o name -t snap | grep -E "/$BASE_ZVOL(\.[0-9]{14})?@$SNAP$" | sed 's/@.*//')
    CLONE_ZVOL="${SRC_ZVOL%/*}/$BASE_ZVOL.$SUFFIX"

    echo "INFO: cloning $SRC_ZVOL@$SNAP -> $CLONE_ZVOL"
    zfs clone "$SRC_ZVOL@$SNAP" "$CLONE_ZVOL" || { echo "ERROR: clone $SRC_ZVOL@$SNAP failed"; exit 1; }
done

# Rebuild conf: parent + snap's saved config (disks renamed) + existing snap sections
echo "INFO: rewriting conf from snapshot $SNAP"
{
    echo "parent: $SNAP"
    qm config $VMID --snapshot $SNAP \
        | sed '/^parent:/d' \
        | sed -E "/^$DISK_SLOT_RE/s|\bbase-[0-9]+-disk-[0-9]+/||g" \
        | sed -E "/^$DISK_SLOT_RE/s|\bvm-$VMID-disk-([0-9]+)(\.[0-9]{14})?\b|vm-$VMID-disk-\1.$SUFFIX|g"
    sed -n '/^\[/,$p' $CONF
} > $CONF.tmp && mv $CONF.tmp $CONF

# Cleanup: destroy suffix-named disks that are no longer referenced and have no snapshots
for ORPHAN_ZVOL in $ORPHAN_ZVOLS; do
    qm config $VMID | grep -q "\b$ORPHAN_ZVOL\b" && continue
    FQ_ORPHAN_ZVOL=$(zfs list -H -o name | grep "/$ORPHAN_ZVOL$")
    [ -z "$FQ_ORPHAN_ZVOL" ] && continue
    [ -n "$(zfs list -H -o name -t snap $FQ_ORPHAN_ZVOL)" ] && continue
    echo "INFO: destroying orphan disk: $FQ_ORPHAN_ZVOL"
    zfs destroy "$FQ_ORPHAN_ZVOL"
done

echo "INFO: done"
