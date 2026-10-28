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

reasons=()
family="$(grep -E "^$(printf '%s' "$KSU_REF" | sed 's/[.]/\\./g')(-r[0-9]+)?$" <<< "$tags" || true)"
if [ -z "$family" ]; then
  family="$(head -n1 <<< "$tags")"
  reasons+=("the kernels were built from \`$KSU_REF\`, which has no release of its own, so this is the newest upstream release")
fi

tag="" normal="" spoofed="" fallback_tag="" fallback_normal=""
for t in $family; do
  names="$(gh release view "$t" -R "$UPSTREAM" --json assets -q '.assets[].name' | grep -E '_[0-9]+-release(-spoofed)?\.apk$' || true)"
  n="$(grep -E -- '-release\.apk$' <<< "$names" | sort -t_ -k3,3n | awk -v want="$DRIVER_VER" '{ if ($0 ~ "_" want "-release.apk$") exact=$0; last=$0 } END { print (exact != "" ? exact : last) }')"
  s="$(grep -E -- '-release-spoofed\.apk$' <<< "$names" | sort -t_ -k3,3n | awk -v want="$DRIVER_VER" '{ if ($0 ~ "_" want "-release-spoofed.apk$") exact=$0; last=$0 } END { print (exact != "" ? exact : last) }')"
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
fi
if [ -z "$tag" ]; then
  echo "::warning::no release in $UPSTREAM pairs a manager APK with kernel ref $KSU_REF; not attaching a manager"
  exit 0
fi
echo "manager release $tag of $UPSTREAM for kernel ref $KSU_REF (driver build $DRIVER_VER): $normal ${spoofed:-<no spoofed>}"

dl="$(mktemp -d)"
gh release download "$tag" -R "$UPSTREAM" --pattern "$normal" ${spoofed:+--pattern "$spoofed"} --dir "$dl"

build="$(sed -nE 's/.*_([0-9]+)-release\.apk$/\1/p' <<< "$normal")"
cp "$dl/$normal" "$OUT_DIR/SukiSU_${build}_normal.apk"
spoofed_name=""
if [ -n "$spoofed" ]; then
  sb="$(sed -nE 's/.*_([0-9]+)-release-spoofed\.apk$/\1/p' <<< "$spoofed")"
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
