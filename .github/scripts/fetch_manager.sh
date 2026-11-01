#!/usr/bin/env bash
set -euo pipefail

for v in UPSTREAM DRIVER_VER KSU_REF OUT_DIR GH_TOKEN GITHUB_ENV; do
  [ -n "${!v:-}" ] || { echo "::error::fetch_manager: $v is not set"; exit 1; }
done

mkdir -p "$OUT_DIR"
tags="$(gh release list -R "$UPSTREAM" -L 50 --json tagName,isPrerelease,isDraft -q '.[] | select((.isPrerelease or .isDraft) | not) | .tagName')"
if [ -z "$tags" ]; then
  echo "::warning::$UPSTREAM has no release; not attaching a manager"
  exit 0
fi

# The kernels are arm64, so of a per-ABI split build only arm64-v8a is of any
# use here. Stable releases ship one un-split APK (SukiSU_v4.3.0_41100-release
# .apk); manager-ci splits per ABI (SukiSU_v4.3.0_41120-arm64-v8a-release.apk).
# Anchoring both '_'-delimited fields is what keeps x86_64 out: its own '_'
# makes the tail of SukiSU_v4.3.0_41120-x86_64-release.apk read as a build.
apk_re='^SukiSU_[^_]*_[0-9]+(-arm64-v8a)?-release'

# Newest build among $1, preferring an exact $DRIVER_VER hit. $2 is "" or
# "-spoofed". The build number is read off the name rather than sorted on a
# field, because an ABI segment can itself hold a '_' (x86_64). A miss has to
# return empty rather than fail: pipefail would otherwise abort the script on
# any source that carries a plain manager but no spoofed one.
pick() {
  local hits
  hits="$(grep -E -- "${apk_re}${2}\.apk\$" <<< "$1" || true)"
  [ -n "$hits" ] || return 0
  awk -v want="$DRIVER_VER" '
    { b=$0; sub(/.*_/,"",b); sub(/-.*/,"",b)
      if (b+0 >= best+0) { best=b+0; last=$0 }
      if (b+0 == want+0) exact=$0 }
    END { print (exact != "" ? exact : last) }' <<< "$hits"
}

reasons=()
family="$(grep -E "^$(printf '%s' "$KSU_REF" | sed 's/[.]/\\./g')(-r[0-9]+)?$" <<< "$tags" || true)"

# A branch build has no release of its own. SukiSU republishes every main build
# to the rolling manager-ci prerelease, so take the manager from there when it
# carries the exact driver the kernels report -- a stale stable release would
# otherwise pair a 41100 manager with a 41120 kernel.
if [ -z "$family" ]; then
  ci_names="$(gh release view manager-ci -R "$UPSTREAM" --json assets -q '.assets[].name' 2>/dev/null || true)"
  if grep -qE -- "^SukiSU_[^_]*_${DRIVER_VER}(-arm64-v8a)?-release\.apk\$" <<< "$ci_names"; then
    family="manager-ci"
    reasons+=("the kernels were built from \`$KSU_REF\`, which has no release of its own, so this is the rolling \`manager-ci\` build that matches driver $DRIVER_VER")
  fi
fi

if [ -z "$family" ]; then
  family="$(head -n1 <<< "$tags")"
  reasons+=("the kernels were built from \`$KSU_REF\`, which has no release of its own, so this is the newest upstream release")
fi

tag="" normal="" spoofed="" fallback_tag="" fallback_normal=""
for t in $family; do
  names="$(gh release view "$t" -R "$UPSTREAM" --json assets -q '.assets[].name' | grep -E -- "${apk_re}(-spoofed)?\.apk\$" || true)"
  n="$(pick "$names" "")"
  s="$(pick "$names" "-spoofed")"
  if [ -n "$n" ] && [ -n "$s" ]; then
    tag="$t" normal="$n" spoofed="$s"
    break
  fi
  if [ -n "$n" ] && [ -z "$fallback_tag" ]; then
    fallback_tag="$t" fallback_normal="$n"
  fi
done
if [ -z "$tag" ] && [ -n "$fallback_tag" ]; then
  tag="$fallback_tag" normal="$fallback_normal"
  echo "::warning::no release in the $KSU_REF family ships a spoofed manager; attaching the plain one from $tag only"
  # manager-ci publishes no spoofed APK. It exists only as the Manager-spoofed
  # artifact of the Build Manager run, and GITHUB_TOKEN carries no actions:read
  # on another repository, so CI cannot fetch it -- say where it lives instead.
  if [ "$tag" = "manager-ci" ]; then
    reasons+=("the spoofed package is not published as a release asset, so take it from the \`Manager-spoofed\` artifact of the matching [Build Manager run](https://github.com/$UPSTREAM/actions/workflows/build-manager.yml)")
  fi
fi
if [ -z "$tag" ]; then
  echo "::warning::no release in $UPSTREAM pairs a manager APK with kernel ref $KSU_REF; not attaching a manager"
  exit 0
fi
echo "manager release $tag of $UPSTREAM for kernel ref $KSU_REF (driver build $DRIVER_VER): $normal ${spoofed:-<no spoofed>}"

dl="$(mktemp -d)"
gh release download "$tag" -R "$UPSTREAM" --pattern "$normal" ${spoofed:+--pattern "$spoofed"} --dir "$dl"

build="$(sed -nE 's/.*_([0-9]+)(-arm64-v8a)?-release\.apk$/\1/p' <<< "$normal")"
cp "$dl/$normal" "$OUT_DIR/SukiSU_${build}_normal.apk"
spoofed_name=""
if [ -n "$spoofed" ]; then
  sb="$(sed -nE 's/.*_([0-9]+)(-arm64-v8a)?-release-spoofed\.apk$/\1/p' <<< "$spoofed")"
  spoofed_name="SukiSU_${sb}_spoofed.apk"
  cp "$dl/$spoofed" "$OUT_DIR/$spoofed_name"
fi
if [ "$build" -ne "$DRIVER_VER" ]; then
  reasons+=("the kernels report $DRIVER_VER")
fi
note=""
if [ "${#reasons[@]}" -gt 0 ]; then
  note=" ($(IFS=';'; printf '%s' "${reasons[*]}" | sed 's/;/; /g'))"
fi

{
  echo "MGR_BUILD=$build"
  echo "MGR_TAG=$tag"
  echo "MGR_NORMAL=SukiSU_${build}_normal.apk"
  echo "MGR_SPOOFED=$spoofed_name"
  echo "MGR_NOTE=$note"
} >> "$GITHUB_ENV"

echo "attached SukiSU manager $build from release $tag"
ls -la "$OUT_DIR"
