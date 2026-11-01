#!/usr/bin/env bash
#
# SUSFS for this builder: the DRIVER side here, the TREE side in kernel_patches.
#
# The split is not arbitrary. Every rule that re-anchors a susfs hunk encodes
# knowledge of NoMount's patches -- which function pathhide renamed, where
# ghost_o_path put its guard -- so that rule and that patch have to version
# together, the same argument apply_nomount_stack.sh makes for itself. They live
# in kernel_patches/scripts now: susfs_patch_surgery.py, assert_guard_sites.py,
# the per-KMI record of which hunks are expected to reject, and every assertion
# about the kernel tree. This file keeps what is specific to the SukiSU driver:
# configs/apply_susfs_patches.sh and susfs_sukisu_selinux_hide.py.
#
# It runs in three parts because the middle one is not ours: the fixer applies
# the kernel patch itself, as part of doing the KernelSU-tree work, so the tree
# side has to run either side of it.
#   prepare  reconcile the patch against this tree and write it back, so the
#            fixer -- which re-derives the path -- applies the reconciled one.
#   fixer    applies it, patches the SukiSU tree, exports SUSVER.
#   verify   post-apply fixups and assertions, including that every guard sits
#            in the function it belongs to.
set -euo pipefail

for v in KERNEL_PLATFORM_FOLDER COMMON_KERNEL_FOLDER SUSFS_FOLDER KSU_FOLDER \
         ARTIFACTS_FOLDER OP_MODEL OP_OS_VERSION ANDROID_VER KERNEL_VER \
         BOUTEILLE_KERNEL_PATCHES_FOLDER GITHUB_ENV; do
  [ -n "${!v:-}" ] || { echo "::error::apply_susfs: $v is not set"; exit 1; }
done

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE_SIDE="$BOUTEILLE_KERNEL_PATCHES_FOLDER/scripts/apply_susfs_kernel.sh"
FIXER="$SCRIPTS_DIR/../../configs/apply_susfs_patches.sh"
HIDE="$SCRIPTS_DIR/susfs_sukisu_selinux_hide.py"
for f in "$TREE_SIDE" "$FIXER" "$HIDE"; do
  [ -f "$f" ] || { echo "::error::apply_susfs: $f is missing"; exit 1; }
done

export SUSFS_KERNEL_BRANCH="${SUSFS_KERNEL_BRANCH:-gki-${ANDROID_VER}-${KERNEL_VER}}"

bash "$TREE_SIDE" prepare

export ANDROID_VER_LOCAL="$ANDROID_VER" KERNEL_VER_LOCAL="$KERNEL_VER" \
       SUSFS_KERNEL_BRANCH_LOCAL="$SUSFS_KERNEL_BRANCH"
export OP_SPOOF_UNAME="${OP_SPOOF_UNAME:-true}"
bash "$FIXER"

# Driver side, and it has to land before the tree side's verify: that restores
# __nocfi on my_setprocattr(), whose signature this rewrites.
python3 -I "$HIDE" "$KSU_FOLDER/kernel/feature/selinux_hide.c"

bash "$TREE_SIDE" verify
echo "   model: $OP_MODEL ($OP_OS_VERSION)"
