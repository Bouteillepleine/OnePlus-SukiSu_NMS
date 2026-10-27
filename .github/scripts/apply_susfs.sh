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

for sym in SUSFS_IS_INODE_SUS_MAP susfs_is_current_proc_umounted_app; do
  grep -rqs "$sym" fs include/linux || { echo "::error::apply_susfs: $sym never reached the tree"; exit 1; }
done
grep -q 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || { echo "::error::apply_susfs: fs/Makefile does not build susfs.o"; exit 1; }
grep -q 'susfs_init[[:space:]]*();' "$KSU_FOLDER/kernel/core/init.c" || { echo "::error::apply_susfs: susfs_init() is not called from the KSU tree"; exit 1; }

SUSVER="$(grep '#define SUSFS_VERSION' include/linux/susfs.h | awk -F'"' '{print $2}')"
echo "SUSFS $SUSVER applied to ${ANDROID_VER}-${KERNEL_VER} ($OP_MODEL)"
