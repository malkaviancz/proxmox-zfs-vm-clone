#!/bin/bash
# Usage: ./zfs-clone.sh <vmid> <snap>
# Example: ./zfs-clone.sh 100 snap1

VMID=$1; SNAP=$2
CONF="/etc/pve/qemu-server/$VMID.conf"

# Validation
[ -z "$VMID" ] && echo "ERROR: VMID required" && exit 1
[ -z "$SNAP" ] && echo "ERROR: SNAP required" && exit 1
[ ! -f "$CONF" ] && echo "ERROR: VM $VMID not found" && exit 1
qm status $VMID | grep -q running && echo "ERROR: VM $VMID is running" && exit 1

SUFFIX=$(date +%Y%m%d%H%M%S)

BASE_ZVOLS=$(qm config $VMID --snapshot $SNAP | grep -E "^(ide|sata|scsi|virtio|efidisk|tpmstate)[0-9]+:" | grep -oE "\bvm-$VMID-disk-[0-9]+\b" | sort -u)
[ -z "$BASE_ZVOLS" ] && echo "ERROR: no disks found for snapshot $SNAP" && exit 1
echo "INFO: disks found: $BASE_ZVOLS"

for BASE_ZVOL in $BASE_ZVOLS; do
    SRC_ZVOL=$(zfs list -H -o name -t snap | grep -E "/$BASE_ZVOL(\.[0-9]{14})?@$SNAP$" | sed 's/@.*//')
    [ -z "$SRC_ZVOL" ] && echo "ERROR: snapshot $SNAP not found for $BASE_ZVOL" && exit 1
    echo "INFO: source disk: $SRC_ZVOL"
    zfs list -H -o name | grep -q "/$BASE_ZVOL\.$SUFFIX$" && echo "ERROR: $BASE_ZVOL.$SUFFIX already exists" && exit 1
done

# Capture suffix-named disks in current VM section before rewrite (orphan disk candidates)
ORPHAN_ZVOLS=$(qm config $VMID | grep -E "^(ide|sata|scsi|virtio|efidisk|tpmstate)[0-9]+:" | grep -oE "\bvm-$VMID-disk-[0-9]+\.[0-9]{14}\b" | sort -u)

# Execution: clone each disk, update disk refs in current VM section only
for BASE_ZVOL in $BASE_ZVOLS; do
    SRC_ZVOL=$(zfs list -H -o name -t snap | grep -E "/$BASE_ZVOL(\.[0-9]{14})?@$SNAP$" | sed 's/@.*//')
    CLONE_ZVOL="${SRC_ZVOL%/*}/$BASE_ZVOL.$SUFFIX"

    echo "INFO: cloning $SRC_ZVOL@$SNAP -> $CLONE_ZVOL"
    zfs clone "$SRC_ZVOL@$SNAP" "$CLONE_ZVOL" || { echo "ERROR: clone $SRC_ZVOL@$SNAP failed"; exit 1; }
    echo "INFO: updating conf: $BASE_ZVOL -> $BASE_ZVOL.$SUFFIX"
    sed -i -E "0,/^\[/s|\b$BASE_ZVOL(\.[0-9]{14})?\b|$BASE_ZVOL.$SUFFIX|" $CONF
done

# Set parent in current VM section: remove existing, insert fresh at top
echo "INFO: setting parent: $SNAP"
sed -i "0,/^\[/{/^parent:/d}" $CONF
sed -i "1s/^/parent: $SNAP\n/" $CONF

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
