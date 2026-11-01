#!/usr/bin/env bash
set -euo pipefail

for v in UPSTREAM DRIVER_VER KSU_REF OUT_DIR GH_TOKEN GITHUB_ENV; do
  [ -n "${!v:-}" ] || { echo "::error::fetch_manager: $v is not set"; exit 1; }
done

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNER="$SCRIPTS_DIR/apk_signer_digest.py"
[ -f "$SIGNER" ] || { echo "::error::fetch_manager: $SIGNER is missing"; exit 1; }

mkdir -p "$OUT_DIR"
dl="$(mktemp -d)"
reasons=()
build="" normal_path="" spoofed_path="" source_md=""

# The kernels are arm64, so of a per-ABI split build only arm64-v8a is of any
# use here. Stable releases and the CI artifacts ship one un-split APK
# (SukiSU_v4.3.0_41100-release.apk); the manager-ci release splits per ABI
# (SukiSU_v4.3.0_41120-arm64-v8a-release.apk). Anchoring both '_'-delimited
# fields is what keeps x86_64 out: its own '_' makes the tail of
# SukiSU_v4.3.0_41120-x86_64-release.apk read as a build number.
apk_re='^SukiSU_[^_]*_[0-9]+(-arm64-v8a)?-release'

build_of() {
  sed -nE 's/.*_([0-9]+)(-arm64-v8a)?-release(-spoofed)?\.apk$/\1/p' <<< "$1"
}

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

# The certificate of the official release asset, taken straight from github.com.
# This is what the kernel itself checks in manager/apk_sign.c, so an APK that
# does not carry it could not act as the manager anyway.
reference_signer() {
  local url
  url="$(gh api "repos/$UPSTREAM/releases/latest" \
    --jq '[.assets[].browser_download_url | select(endswith("-release.apk"))
           | select(contains("spoofed") | not)] | .[0] // empty' 2>/dev/null || true)"
  [ -n "$url" ] || return 1
  curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused \
    -o "$dl/reference.apk" "$url" || return 1
  python3 -I "$SIGNER" "$dl/reference.apk" | cut -d' ' -f1
}

# A branch build has no release of its own, and the pair that upstream's own CI
# built from that branch lives only as Actions artifacts. A repository's
# GITHUB_TOKEN cannot read another repository's artifacts, so nightly.link --
# which proxies public artifacts unauthenticated -- is the route to them, the
# same one the KernelSU Next builder uses. Nothing is trusted on that basis:
# both APKs must match the driver and carry the official signing certificate.
from_nightly_link() {
  local signer a apk base b
  signer="$(reference_signer || true)"
  if [ -z "$signer" ]; then
    echo "  cannot read the official signing certificate"
    return 1
  fi
  echo "  reference signer: $signer"
  rm -rf "$dl/nl"; mkdir -p "$dl/nl"
  for a in Manager Manager-spoofed; do
    curl -fsSL --retry 3 --retry-delay 5 --retry-connrefused -o "$dl/$a.zip" \
      "https://nightly.link/$UPSTREAM/workflows/build-manager/$KSU_REF/$a.zip" || return 1
    unzip -oqq "$dl/$a.zip" -d "$dl/nl" || return 1
  done
  for apk in "$dl/nl"/*.apk; do
    [ -f "$apk" ] || continue
    base="$(basename "$apk")"
    b="$(build_of "$base")"
    if [ "$b" != "$DRIVER_VER" ]; then
      echo "  x $base is build ${b:-?}, driver is $DRIVER_VER"
      return 1
    fi
    if ! python3 -I "$SIGNER" "$apk" "$signer" >/dev/null; then
      echo "  x $base is not signed by the official manager certificate"
      return 1
    fi
    case "$base" in
      *-release-spoofed.apk) spoofed_path="$apk" ;;
      *-release.apk)         normal_path="$apk" ;;
    esac
    echo "  ok $base"
  done
  [ -n "$normal_path" ] && [ -n "$spoofed_path" ] || return 1
  build="$DRIVER_VER"
  source_md="the upstream CI build of \`$KSU_REF\`, [proxied by nightly.link](https://nightly.link/$UPSTREAM/workflows/build-manager/$KSU_REF/Manager.zip)"
}

# Release assets: the $KSU_REF family first, then the rolling manager-ci
# prerelease when it carries the exact driver, then the newest release.
from_release() {
  local tags family t names n s tag fallback_tag fallback_normal ci_names
  tags="$(gh release list -R "$UPSTREAM" -L 50 --json tagName,isPrerelease,isDraft \
    -q '.[] | select((.isPrerelease or .isDraft) | not) | .tagName')"
  [ -n "$tags" ] || { echo "  $UPSTREAM has no release"; return 1; }

  family="$(grep -E "^$(printf '%s' "$KSU_REF" | sed 's/[.]/\\./g')(-r[0-9]+)?$" <<< "$tags" || true)"
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

  tag="" fallback_tag="" fallback_normal=""
  for t in $family; do
    names="$(gh release view "$t" -R "$UPSTREAM" --json assets -q '.assets[].name' \
      | grep -E -- "${apk_re}(-spoofed)?\.apk\$" || true)"
    n="$(pick "$names" "")"
    s="$(pick "$names" "-spoofed")"
    if [ -n "$n" ] && [ -n "$s" ]; then
      tag="$t"
      break
    fi
    if [ -n "$n" ] && [ -z "$fallback_tag" ]; then
      fallback_tag="$t" fallback_normal="$n"
    fi
  done
  if [ -z "$tag" ] && [ -n "$fallback_tag" ]; then
    tag="$fallback_tag" n="$fallback_normal" s=""
    echo "::warning::no release in the $KSU_REF family ships a spoofed manager; attaching the plain one from $tag only"
  fi
  [ -n "$tag" ] || { echo "  no release pairs a manager APK with $KSU_REF"; return 1; }

  gh release download "$tag" -R "$UPSTREAM" --pattern "$n" ${s:+--pattern "$s"} --dir "$dl" || return 1
  build="$(build_of "$n")"
  normal_path="$dl/$n"
  [ -z "$s" ] || spoofed_path="$dl/$s"
  source_md="the upstream release [$tag](https://github.com/$UPSTREAM/releases/tag/$tag)"
}

# A tag build is served by its own release assets, so only reach for the CI
# artifacts when the ref is a branch.
sources="from_release"
if ! grep -qE "^$(printf '%s' "$KSU_REF" | sed 's/[.]/\\./g')(-r[0-9]+)?$" \
     <<< "$(gh release list -R "$UPSTREAM" -L 50 --json tagName,isPrerelease,isDraft \
            -q '.[] | select((.isPrerelease or .isDraft) | not) | .tagName')"; then
  sources="from_nightly_link from_release"
fi

for source in $sources; do
  echo "::group::$source"
  if "$source" && [ -n "$normal_path" ]; then
    echo "::endgroup::"
    break
  fi
  build="" normal_path="" spoofed_path="" source_md=""
  echo "::endgroup::"
done

if [ -z "$normal_path" ]; then
  echo "::warning::nothing in $UPSTREAM pairs a manager APK with kernel ref $KSU_REF (driver build $DRIVER_VER); not attaching a manager"
  exit 0
fi

cp "$normal_path" "$OUT_DIR/SukiSU_${build}_normal.apk"
spoofed_name=""
if [ -n "$spoofed_path" ]; then
  spoofed_name="SukiSU_$(build_of "$(basename "$spoofed_path")")_spoofed.apk"
  cp "$spoofed_path" "$OUT_DIR/$spoofed_name"
else
  reasons+=("the spoofed package is not published for this ref, so take it from the \`Manager-spoofed\` artifact of the matching [Build Manager run](https://github.com/$UPSTREAM/actions/workflows/build-manager.yml)")
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
  echo "MGR_SOURCE=$source_md"
  echo "MGR_NORMAL=SukiSU_${build}_normal.apk"
  echo "MGR_SPOOFED=$spoofed_name"
  echo "MGR_NOTE=$note"
} >> "$GITHUB_ENV"

echo "attached SukiSU manager $build from $source_md"
ls -la "$OUT_DIR"
