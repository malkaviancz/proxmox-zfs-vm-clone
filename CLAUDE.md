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

- **Try `qm rollback` first**: invoke `qm rollback <vmid> <snap>` before any clone logic; on non-zero exit fall through to the clone path. PVE pre-validates every attached disk (refuses non-leaf via `volume_rollback_is_possible`, atomic across disks) so a non-zero exit means no mutation occurred. Works the same for cloned disks since PVE's per-volid snapshot listing excludes the origin.
- **Branch via `zfs clone`**: snapshot → new disk; update VM conf to reference it.
- **Coexists with Proxmox UI**: taking/deleting snapshots from the Proxmox web UI continues to work normally. Use this script only when branching from a historical snapshot.
- **No `zfs promote`**: avoids disrupting snapshot ownership in clone chains.
- **Disk naming**:
  - Base: `vm-<vmid>-disk-<n>`
  - Branched: `vm-<vmid>-disk-<n>.<14-digit-datetime>` (suffix is always `date +%Y%m%d%H%M%S`, no arbitrary user input)
- **Disk discovery**: read from the snapshot's saved config via `qm config <vmid> --snapshot <snap>`, parsed to base names. Matches only attached disk slot prefixes (`ide`, `sata`, `scsi`, `virtio`, `efidisk`, `tpmstate`) - `unused<N>:` entries are excluded, matching `qm snapshot/rollback` (both call `foreach_volume` without `include_unused`). Detached disks present at snapshot time are *not* cloned; their entries pass through the VM conf rewrite verbatim and continue to reference the original (uncloned) disk.
- **Source disk lookup**: locate via the snapshot itself (`/<disk>(.<suffix>)?@<snap>`), not the base-disk name. This correctly handles chained branches where a disk has multiple `.suffix` variants on disk and the right source is the one that actually owns the snapshot.
- **VM conf writes**: rebuild `/etc/pve/qemu-server/<vmid>.conf` atomically. The new current VM section is taken from `qm config <vmid> --snapshot <snap>` with `parent:` filtered and disk volids rewritten from `vm-<vmid>-disk-<n>` to `vm-<vmid>-disk-<n>.<suffix>`; a fresh `parent: <snap>` is prepended. `unused<N>:` lines pass through unmodified - `zfs rollback` is not applied to detached disks, matching `qm snapshot/rollback`. The snapshot sections from the existing file are appended verbatim. This reproduces what would have been produced if `qm snapshot/rollback` had succeeded - any divergence in the current VM section (disk or non-disk) since snapshot time is undone, while the future timeline is preserved as snapshot sections. Atomic via `> $CONF.tmp && mv $CONF.tmp $CONF`.
- **Linked-clone source disks**: `base-<tmplid>-disk-<n>/vm-<vmid>-disk-<n>` volids in the snapshot section are supported. The rewrite strips the `base-…-disk-…/` prefix when writing the new current VM section, because the branched disk's direct ZFS origin is the snapshot's leaf (`vm-<vmid>-disk-<n>@<snap>`), not the template's `@__base__` - so the branch is written as a plain disk volid. Template-destroy protection is preserved via the unchanged snapshot sections, which still reference the template. The branch correctly stops appearing under the template's "Linked Clones" UI list (it no longer is one).
- **`parent: <snap>`**: written at the top of the new current VM section so the Proxmox UI shows the branch point correctly. The snapshot's own `parent:` (which points to the snapshot's predecessor, or is absent if `<snap>` is the first snapshot) is filtered out during the rebuild.
- **Orphan disk cleanup**: after a successful branch, suffix-named disks (`vm-<vmid>-disk-<n>.<14-digit-datetime>`) that the current VM section no longer references and that have no ZFS snapshots are destroyed. Reliance on the datetime suffix - only ever produced by this script - keeps base/hand-named disks safe. Cleanup runs only after the main branching succeeds, so a mid-run failure leaves disk state untouched. Anything matching that naming pattern on disk should be assumed disposable by this script. Suffix-named disks living in current `unused<N>:` slots (a previously-branched disk that was later detached without being snapshotted) fall outside this cleanup pass - consistent with the "Manual zfs interference" out-of-scope clause.
- **VM must be stopped and unlocked** before branching. `qm status --verbose` gates both - `^status: running` for the running check, `^lock:` for the lock check (refuses when PVE has the VM locked for backup/migrate/snapshot/etc.).
- **Style**: use plain `grep` for literal patterns and `^`/`$` anchors; `grep -E` only when the pattern actually needs ERE features (alternation, `+`, `?`, `{n}`); never `-P` unless PCRE is genuinely needed. Avoid unnecessary escapes; no optional/sugar shell syntax.
- **Disk-name boundaries**: every regex consuming `vm-<vmid>-disk-<n>` enforces explicit boundaries to avoid `disk-1` matching inside `disk-10`. Either via surrounding literals (`/…@`, `/…\.<suffix>$`) or via `\b` on both sides (disk extraction and VM conf rewrite).
- **Orphan-check regex hardening gap**: the orphan-cleanup checks interpolate `$ORPHAN_ZVOL` (e.g. `vm-100-disk-0.20251101010101`) directly into the grep pattern without escaping the `.` in the `.<14-digit>` suffix - so the dot acts as the regex any-char metacharacter rather than matching a literal `.`. Harmless in practice because no real disk name produced by `qm`/`zfs` collides via this any-char meaning, but a hardened version would precompute `ORPHAN_ZVOL_RE="${ORPHAN_ZVOL//./\\.}"` and interpolate that escaped value into the regex.

## Assumptions about input

- **PVE snapshot names** follow the `pve-configid` format defined in `pve-common` as `qr/[a-z][a-z0-9_]+/i` - i.e. `^[a-zA-Z][a-zA-Z0-9_]+$`, with `current` additionally reserved. Allowed chars are only `a-zA-Z`, `0-9`, `_` - none are special in ERE regex or in `sed` patterns/replacements. So `$SNAP` is interpolated raw without escaping in the snapshot-lookup regex.
- **Source of snapshots**: only this script and `qm snapshot`. We do not run arbitrary `zfs snapshot` commands. Implications:
  - Snapshot names cannot collide across pools for the same VM (`qm snapshot` rejects duplicates).
  - Same-name snapshots on different links of a clone chain don't occur in practice - the script only ever creates new disk clones with unique 14-digit datetime suffixes, never new ZFS snapshots.
- **VM conf format**: disk refs are bounded by `:` / `,` / EOL, plus `/` on the left for linked-clone volids of the form `base-<tmplid>-disk-<n>/vm-<vmid>-disk-<n>`. Unanchored disk-name patterns are safe in practice; `\b` is added defensively.

## Out of scope (not handled, not preflight-detected)

Assumed absent or admin's responsibility - script may misbehave silently in these cases:

- Mid-loop `zfs clone` failure rollback.
- Concurrency: no `flock` on the VM conf. Single-node, single-operator only.
- Manual `zfs` interference (disks added/renamed/destroyed by hand).
- HA-managed VMs.
- Replicated VMs.
- Template VMs (`template: 1`).
- Non-ZFS-storage disks attached.

## Bug History (for context)

1. **sed only replacing base name** when the current VM section already had a suffixed disk entry → fixed with `$BASE_ZVOL(\.[0-9]{14})?` and `sed -E`.
2. **Existence check** for the new disk: an exact match on `$BASE_ZVOL\.$SUFFIX$` is correct and sufficient (suffix is always the current datetime).
3. **sed regex needed a right-side anchor** - without it, `vm-100-disk-1` matches the prefix of `vm-100-disk-10`. Fixed with `\b`.
4. **Source disk lookup missed already-branched disks** - `grep -oE "vm-$VMID-disk-[0-9]+"` stops at `.`, so chained branching couldn't find its source. Switched the lookup to use the snapshot itself, which is unique to the correct disk.
5. **`zfs clone` was unchecked** - a clone failure mid-loop would still rewrite the VM conf. Now guarded with `|| exit 1`.
6. **Disk-name boundary review** - added `\b` on both sides of `vm-$VMID-disk-[0-9]+` in the disk extraction and on the left side in the VM conf rewrite. The snapshot lookups and existence check already had explicit `/`, `@`, `\.` delimiters, so left untouched.
7. **qm-induced VM conf divergence misbehaved**: when `qm set`/`qm disk unlink` had altered disks between snapshot time and now, the per-disk in-place sed rewrite kept silently broken state (added-after-snap disks shared with the original timeline; slot swaps left clones orphaned with the current VM section pointing at the wrong disk; disks removed-via-unlink left orphaned clones with no VM conf restoration; `unused<N>:` disks in the snapshot section skipped entirely). Replaced with a rollback-style rebuild that takes the new current VM section entirely from the snapshot's saved config (matching what `qm snapshot/rollback` would produce).
8. **Linked-clone volid prefix leaked through the rewrite** - the disk-name substitution regex only consumed `\bvm-<vmid>-disk-N\b`, so for lines in the snapshot section of the form `base-<tmplid>-disk-<n>/vm-<vmid>-disk-<n>` the rewrite left the `base-…/` prefix in place, producing a volid in the current VM section that misrepresents the new clone's parent (its ZFS origin is the snapshot's leaf, not the template). Added a separate `sed` pass that strips `\bbase-[0-9]+-disk-[0-9]+/` from disk lines before the disk-name rewrite.

## Documentation style

When editing this file, follow these conventions:

- **VM conf** - refers to `/etc/pve/qemu-server/<vmid>.conf`. Use "VM conf" in prose; the literal filename appears only in paths/examples.
- **current VM section** - the section of the VM conf above the first `[<snapshot>]` block. Always include "VM" - never "current section" alone.
- **snapshot** - write in full in prose. In code or inline backtick-quoted tokens, use the abbreviated `<snap>` (e.g. `parent: <snap>`, `qm config <vmid> --snapshot <snap>`).
- **snapshot section** - the `[<name>]` block in the VM conf. Write in full (not "snap-section"). Singular when referring to one specific snapshot's section; plural for the collection of all snapshot sections.
- **disk** - a ZFS volume backing a VM disk. Use "disk" in prose; reserve "volid" for the conf-format token (e.g. `local-zfs:vm-100-disk-0`).
- **`qm snapshot/rollback`** - use this when describing behavior shared by both commands (e.g. their use of `foreach_volume` without `include_unused`). Use a specific command name (`qm rollback` or `qm snapshot`) only when documenting that specific invocation.
- **Underlying action terms** - e.g. "`zfs rollback` is not applied" rather than "content rollback is not applied". Prefer concrete PVE/ZFS commands and primitives over abstract descriptions.
- **Dash character** - use ASCII hyphen `-`, never em-dash (`—`) or en-dash (`–`).
