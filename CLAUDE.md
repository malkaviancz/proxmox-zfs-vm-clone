# ZFS Snapshot Branching for Proxmox VMs

## Goal
Manage ZFS-backed Proxmox VMs with **true snapshot branching** (not linear rollback). Proxmox does support branching VMs via templates and full/linked clones, but those dependencies aren't surfaced as a tree like the snapshot list, so they're hard to track. For snapshots specifically, rollback is linear and destroys later snapshots. This script branches off a historical snapshot by cloning it into a new disk and pointing the VM at the clone, preserving all history.

## Usage
```
./zfs-clone.sh <vmid> <snap>
```
After creating/copying the script, make it executable: `chmod +x zfs-clone.sh`.
The VM must be stopped before running.

## Design Decisions

- **Branch via `zfs clone`**: snapshot → new disk; update VM conf to reference it.
- **Coexists with Proxmox UI**: taking/deleting snapshots from the Proxmox web UI continues to work normally. Use this script only when branching from a historical snapshot.
- **No `zfs promote`**: avoids disrupting snapshot ownership in clone chains.
- **Disk naming**:
  - Base: `vm-<vmid>-disk-<n>`
  - Branched: `vm-<vmid>-disk-<n>.<14-digit-datetime>` (suffix is always `date +%Y%m%d%H%M%S`, no arbitrary user input)
- **Disk discovery**: read from the snapshot's saved config via `qm config <vmid> --snapshot <snap>`, parsed to base names. Only disks that existed at snapshot time are processed.
- **Source disk lookup**: locate via the snapshot itself (`/<disk>(.<suffix>)?@<snap>`), not the base-disk name. This correctly handles chained branches where a disk has multiple `.suffix` variants on disk and the right source is the one that actually owns the snapshot.
- **Conf writes**: directly edit `/etc/pve/qemu-server/<vmid>.conf`. Disk refs are rewritten only in the **current VM section** (above the first `[snapshot]` block), via a `0,/^\[/` sed range.
- **`parent: <snapshot>`**: written into the current VM section so the Proxmox UI shows the branch point correctly. Existing `parent:` line in that section is removed first, then a fresh one is inserted at the top.
- **Orphan disk cleanup**: after a successful branch, suffix-named disks (`vm-<vmid>-disk-<n>.<14-digit-datetime>`) that the current VM section no longer references and that have no ZFS snapshots are destroyed. Reliance on the datetime suffix - only ever produced by this script - keeps base/hand-named disks safe. Cleanup runs only after the main branching succeeds, so a mid-run failure leaves disk state untouched. Anything matching that naming pattern on disk should be assumed disposable by this script.
- **VM must be stopped** before branching.
- **Style**: prefer `grep -E` (avoid `-P` unless PCRE is genuinely needed); avoid unnecessary escapes; no optional/sugar shell syntax.
- **Disk-name boundaries**: every regex consuming `vm-<vmid>-disk-<n>` enforces explicit boundaries to avoid `disk-1` matching inside `disk-10`. Either via surrounding literals (`/…@`, `/…\.<suffix>$`) or via `\b` on both sides (disk extraction and conf rewrite).
- **Orphan-check regex hardening gap**: the orphan-cleanup checks interpolate `$ORPHAN_ZVOL` (e.g. `vm-100-disk-0.20251101010101`) directly into the grep pattern without escaping the `.` in the `.<14-digit>` suffix - so the dot acts as the regex any-char metacharacter rather than matching a literal `.`. Harmless in practice because no real disk name produced by `qm`/`zfs` collides via this any-char meaning, but a hardened version would precompute `ORPHAN_ZVOL_RE="${ORPHAN_ZVOL//./\\.}"` and interpolate that escaped value into the regex.

## Assumptions about input

- **PVE snapshot names** follow the `pve-configid` format defined in `pve-common` as `qr/[a-z][a-z0-9_]+/i` - i.e. `^[a-zA-Z][a-zA-Z0-9_]+$`, with `current` additionally reserved. Allowed chars are only `a-zA-Z`, `0-9`, `_` - none are special in ERE regex or in `sed` patterns/replacements. So `$SNAP` is interpolated raw without escaping in the snapshot-lookup regex and the parent-line sed replacement.
- **Source of snapshots**: only this script and `qm snapshot`. We do not run arbitrary `zfs snapshot` commands. Implications:
  - Snapshot names cannot collide across pools for the same VM (`qm snapshot` rejects duplicates).
  - Same-name snapshots on different links of a clone chain don't occur in practice - the script only ever creates new disk clones with unique 14-digit datetime suffixes, never new ZFS snapshots.
- **VM conf format**: disk refs are bounded by `:` / `,` / EOL, plus `/` on the left for linked-clone volids of the form `base-<tmplid>-disk-<n>/vm-<vmid>-disk-<n>`. Unanchored disk-name patterns are safe in practice; `\b` is added defensively.

## Bug History (for context)

1. **sed only replacing base name** when current conf had a suffix → fixed with `$BASE_ZVOL(\.[0-9]{14})?` and `sed -E`.
2. **Existence check** for the new disk: an exact match on `$BASE_ZVOL\.$SUFFIX$` is correct and sufficient (suffix is always the current datetime).
3. **sed regex needed a right-side anchor** - without it, `vm-100-disk-1` matches the prefix of `vm-100-disk-10`. Fixed with `\b`.
4. **Source disk lookup missed already-branched disks** - `grep -oE "vm-$VMID-disk-[0-9]+"` stops at `.`, so chained branching couldn't find its source. Switched the lookup to use the snapshot itself, which is unique to the correct disk.
5. **`zfs clone` was unchecked** - a clone failure mid-loop would still rewrite the conf. Now guarded with `|| exit 1`.
6. **Disk-name boundary review** - added `\b` on both sides of `vm-$VMID-disk-[0-9]+` in the disk extraction and on the left side in the conf rewrite. The snapshot lookups and existence check already had explicit `/`, `@`, `\.` delimiters, so left untouched.
