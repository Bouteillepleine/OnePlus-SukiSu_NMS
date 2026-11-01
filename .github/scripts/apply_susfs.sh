#!/usr/bin/env bash
set -euo pipefail

for v in KERNEL_PLATFORM_FOLDER COMMON_KERNEL_FOLDER SUSFS_FOLDER KSU_FOLDER ARTIFACTS_FOLDER OP_MODEL OP_OS_VERSION ANDROID_VER KERNEL_VER GITHUB_ENV; do
  [ -n "${!v:-}" ] || { echo "::error::apply_susfs: $v is not set"; exit 1; }
done

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SURGERY="$SCRIPTS_DIR/susfs_patch_surgery.py"
FIXER="$SCRIPTS_DIR/../../configs/apply_susfs_patches.sh"
[ -f "$SURGERY" ] || { echo "::error::apply_susfs: $SURGERY is missing"; exit 1; }
[ -f "$FIXER" ] || { echo "::error::apply_susfs: $FIXER is missing"; exit 1; }

SUSFS_BRANCH="${SUSFS_KERNEL_BRANCH:-gki-${ANDROID_VER}-${KERNEL_VER}}"
SUSFS_PATCH="$SUSFS_FOLDER/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH}.patch"
if [ ! -f "$SUSFS_PATCH" ]; then
  echo "::error::apply_susfs: no kernel patch for $SUSFS_BRANCH in $SUSFS_FOLDER/kernel_patches"
  find "$SUSFS_FOLDER/kernel_patches" -maxdepth 1 -name '50_add_susfs_in_*.patch' | sort
  exit 1
fi

cd "$COMMON_KERNEL_FOLDER"

rejects="$(patch -p1 -F0 --forward --dry-run < "$SUSFS_PATCH" 2>&1 | awk '/^checking file/{f=$3} /Hunk #[0-9]+ FAILED/{n=$2; gsub("#","",n); print f":"n}')" || true
if [ -n "$rejects" ]; then
  echo "SUSFS kernel patch rejects on ${ANDROID_VER}-${KERNEL_VER} ($(grep -m1 '^SUBLEVEL' Makefile | tr -d ' ')):"
  printf '%s\n' "$rejects" | sed 's/^/   rejected: /'
fi

# ---------------------------------------------------------------------------
# Which rejects we have a record of.
#
# susfs and NoMount hook the same VFS and procfs functions for the same reason,
# and NoMount goes in first, so a handful of susfs hunks reject on every build
# and are re-anchored by susfs_patch_surgery.py. That is the mechanism, not a
# workaround -- but it means the surgery runs on hunks nobody has looked at, and
# an upstream susfs change arriving as "6 to 11 hunks reconciled, build green"
# is indistinguishable from the state we are actually in. The KernelSU half of
# this stack already refuses that (EXPECTED_SUKISU_REJECTS in
# configs/apply_susfs_patches.sh plus its 'Unexpected KernelSU-side .rej' gate);
# the kernel half had no equivalent.
#
# So: a reject listed here is reconciled as before, and a reject that is NOT
# listed FAILS THE BUILD with the hunk printed. The list is an allowed set, not
# an exact one -- devices inside one KMI sit on different sublevels and reject
# slightly differently -- so an entry that does not fire is reported as a plain
# line, never as a warning: it fires on some other device of the same KMI.
#
# Seeded from the 26-job op_model=patch-matrix run (every 6.12 target plus one
# per KMI/SoC) against susfs v2.3.0 and SukiSU 41120, so it covers 26 of the 82
# configs. An unsampled sublevel that drifts will now stop the build instead of
# being reconciled unseen; that is the point, and the error says what to add.
# ---------------------------------------------------------------------------
expected_rejects() {
  # Common to every KMI. The reason is what the hunk IS and what it lands on
  # top of, because that is what you need to know when one of them changes.
  cat <<'EOT'
fs/proc/base.c:4            the sus_map skip in proc_map_files_readdir(); NoMount's pathhide_mapfiles patch skips at the same `if (!vma->vm_file) continue;`
fs/proc/task_mmu.c:3        the sus_kstat/OPEN_REDIRECT spoof in show_map_vma(); the hookless engine overrides dev/ino at the same statement
fs/proc/task_mmu.c:4        the sus_map guard at the head of show_smap(); pathhide guards the same spot, and Android's VMA-padding rework moved the statement it anchors on
fs/proc/task_mmu.c:5        the show_smaps_rollup() bypass; same loop pathhide walks, and the padding rework renamed its guard
EOT
  case "${ANDROID_VER}-${KERNEL_VER}" in
  android12-5.10) cat <<'EOT'
fs/namei.c:21               OPEN_REDIRECT in do_o_path(); ghost_o_path.patch guards the same `if (!error) {`
fs/stat.c:5                 the su-compat filename declaration in vfs_statx(); ghost_statx declares ghost_hidden_path() on the same anchor
fs/stat.c:6                 the su-compat preamble at vfs_statx()'s retry: label
EOT
    ;;
  android13-5.15) cat <<'EOT'
fs/Makefile:1               obj-$(CONFIG_KSU_SUSFS) += susfs.o; the hookless engine added its own obj line in the same region
fs/namei.c:18               OPEN_REDIRECT in do_o_path(); ghost_o_path.patch guards the same `if (!error) {`
fs/namespace.c:1            the susfs extern block; anchored on includes that move by sublevel
fs/open.c:1                 the susfs declarations; ghost_access/ghost_open/ghost_truncate sit in the same include region
fs/proc/task_mmu.c:1        the susfs extern block; anchored on includes that move by sublevel
fs/stat.c:4                 the su-compat preamble in vfs_statx(); ghost_statx declares ghost_hidden_path() on the same anchor
fs/stat.c:5                 the su-compat filename declaration in vfs_statx()
mm/memory.c:1               the SUS_MAP include; anchored on includes that move by sublevel
EOT
    ;;
  android14-6.1) cat <<'EOT'
fs/Makefile:1               obj-$(CONFIG_KSU_SUSFS) += susfs.o; the hookless engine added its own obj line in the same region
fs/exec.c:1                 the susfs_def.h include; anchored on #include <linux/dma-buf.h>, which older sublevels do not carry
fs/namei.c:18               OPEN_REDIRECT in do_o_path(); ghost_o_path.patch guards the same `if (!error) {`
fs/namespace.c:1            the susfs extern block; anchored on includes that move by sublevel
fs/proc/base.c:1            the susfs_def.h include; anchored on #include <uapi/linux/lsm.h>, which older sublevels do not carry
fs/stat.c:4                 the su-compat preamble in vfs_statx(); ghost_statx declares ghost_hidden_path() on the same anchor
EOT
    ;;
  android15-6.6) cat <<'EOT'
fs/exec.c:1                 the susfs_def.h include; anchored on #include <linux/dma-buf.h>, which older sublevels do not carry
fs/namei.c:18               OPEN_REDIRECT in do_o_path(); ghost_o_path.patch guards the same `if (!error) {`
fs/proc/base.c:1            the susfs_def.h include; anchored on #include <uapi/linux/lsm.h>, which older sublevels do not carry
fs/stat.c:4                 the su-compat preamble in vfs_statx(); ghost_statx declares ghost_hidden_path() on the same anchor
EOT
    ;;
  android16-6.12) cat <<'EOT'
fs/exec.c:1                 the susfs_def.h include; anchored on #include <linux/dma-buf.h>, which older sublevels do not carry
fs/namei.c:18               OPEN_REDIRECT in do_o_path(); ghost_o_path.patch guards the same `if (!error) {`
fs/proc/base.c:1            the susfs_def.h include; anchored on #include <uapi/linux/lsm.h>, which older sublevels do not carry
fs/proc/task_mmu.c:6        the show_smaps_rollup() bypass label; folded in with hunk #5
fs/stat.c:6                 the su-compat preamble in vfs_statx(); ghost_statx declares ghost_hidden_path() on the same anchor
security/selinux/hooks.c:1  the susfs extern block; anchored on #define SELINUX_INODE_INIT_XATTRS 1
EOT
    ;;
  *)
    echo "::error::apply_susfs: no expected-reject record for ${ANDROID_VER}-${KERNEL_VER}" >&2
    return 1
    ;;
  esac
}

allowed="$(expected_rejects | awk 'NF && $1 !~ /^#/ { print $1 }')"
[ -n "$allowed" ] || { echo "::error::apply_susfs: the expected-reject table came back empty"; exit 1; }

unknown=""
for r in $rejects; do
  grep -qxF -- "$r" <<< "$allowed" || unknown="$unknown $r"
done
if [ -n "$unknown" ]; then
  echo "::error::apply_susfs: susfs hunks reject on ${ANDROID_VER}-${KERNEL_VER} that this builder has no record of:$unknown"
  echo "susfs4ksu has changed shape, or this tree has. Read the hunks below, decide where each one"
  echo "belongs, and add it to expected_rejects() in .github/scripts/apply_susfs.sh with a reason --"
  echo "or give it a named rule in .github/scripts/susfs_patch_surgery.py if it needs placing by content."
  python3 -I "$SURGERY" --show "$SUSFS_PATCH" . $unknown
  exit 1
fi

unused=""
while read -r spec _; do
  [ -n "$spec" ] || continue
  grep -qxF -- "$spec" <<< "${rejects:-}" || unused="$unused $spec"
done <<< "$(expected_rejects | awk 'NF && $1 !~ /^#/ { print $1 }')"
[ -z "$unused" ] || echo "   on record but applied cleanly here (another sublevel of this KMI rejects them):$unused"

python3 -I "$SURGERY" --drop security/selinux/selinuxfs.c "$SUSFS_PATCH" . $rejects
if ! patch -p1 -F0 --forward --dry-run < "$SUSFS_PATCH" >/dev/null 2>&1; then
  echo "::error::apply_susfs: SUSFS kernel patch still rejects after reconciliation"
  patch -p1 -F0 --forward --dry-run < "$SUSFS_PATCH" 2>&1 | grep -E '^(checking file|Hunk .*FAILED)'
  exit 1
fi

export ANDROID_VER_LOCAL="$ANDROID_VER" KERNEL_VER_LOCAL="$KERNEL_VER" SUSFS_KERNEL_BRANCH_LOCAL="$SUSFS_BRANCH"
export OP_SPOOF_UNAME="${OP_SPOOF_UNAME:-true}"
bash "$FIXER"

cd "$COMMON_KERNEL_FOLDER"

if grep -q '#ifndef KSU_NO_PREINIT' fs/exec.c && ! grep -q '^#define KSU_NO_PREINIT' fs/exec.c; then
  if grep -rqs 'ksu_setup_preinit_file' "$KSU_FOLDER/kernel"; then
    echo "KSU tree provides preinit; leaving the SUSFS preinit hooks enabled"
  else
    sed -i '0,/^#ifdef CONFIG_KSU_SUSFS$/s//#ifndef KSU_NO_PREINIT\n#define KSU_NO_PREINIT\n#endif\n&/' fs/exec.c
    grep -q '^#define KSU_NO_PREINIT$' fs/exec.c || { echo "::error::apply_susfs: could not define KSU_NO_PREINIT in fs/exec.c"; exit 1; }
    echo "defined KSU_NO_PREINIT; this KSU tree has no preinit"
  fi
fi

SH="$KSU_FOLDER/kernel/feature/selinux_hide.c"
python3 -I "$SCRIPTS_DIR/susfs_sukisu_selinux_hide.py" "$SH"
if grep -q '^int my_setprocattr(const char \*name, void \*value, size_t size)$' "$SH" && ! grep -q '__nocfi .*setprocattr' "$SH"; then
  sed -i 's/^int my_setprocattr(const char \*name, void \*value, size_t size)$/int __nocfi my_setprocattr(const char *name, void *value, size_t size)/' "$SH"
  echo "restored __nocfi on my_setprocattr() after the SUSFS enable patch rewrote its signature"
fi

tm=fs/proc/task_mmu.c
before="$(md5sum "$tm" | cut -d' ' -f1)"
sed -i -E 's@^([[:blank:]]{3,})end = VMA_PAD_START\(vma\);[[:blank:]]*$@\1end = vma->vm_end;@' "$tm"
sed -i -E '/^[[:blank:]]{3,}__fold_filemap_fixup_entry\(/d' "$tm"
[ "$before" = "$(md5sum "$tm" | cut -d' ' -f1)" ] || echo "neutralised susfs OPEN_REDIRECT VMA_PAD_START/__fold refs in $tm"

if grep -qE 'ksu_selinux_hide_enabled|fake_status|initialize_fake_status|fake_status_initialize_key|my_sel_open_handle_status' security/selinux/selinuxfs.c; then
  echo "::error::apply_susfs: SUSFS selinuxfs hunks reached security/selinux/selinuxfs.c"
  exit 1
fi

python3 -I "$SCRIPTS_DIR/assert_guard_sites.py" .

for sym in SUSFS_IS_INODE_SUS_MAP susfs_is_current_proc_umounted_app; do
  grep -rqs "$sym" fs include/linux || { echo "::error::apply_susfs: $sym never reached the tree"; exit 1; }
done
grep -q 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || { echo "::error::apply_susfs: fs/Makefile does not build susfs.o"; exit 1; }
grep -q 'susfs_init[[:space:]]*();' "$KSU_FOLDER/kernel/core/init.c" || { echo "::error::apply_susfs: susfs_init() is not called from the KSU tree"; exit 1; }

SUSVER="$(grep '#define SUSFS_VERSION' include/linux/susfs.h | awk -F'"' '{print $2}')"
echo "SUSFS $SUSVER applied to ${ANDROID_VER}-${KERNEL_VER} ($OP_MODEL)"
