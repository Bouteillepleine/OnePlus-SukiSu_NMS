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
# use here. The CI artifacts ship one un-split APK
# (SukiSU_v4.3.0-r2_41184-release.apk); the manager-ci release splits per ABI,
# and the Nova rename put a brand word in front of the version
# (SukiSU_Nova_v3.0.0_30000-arm64-v8a-release.apk), so that word is optional
# here -- both namings are in flight at once. Anchoring both '_'-delimited
# fields either side of it is what keeps x86_64 out: its own '_' makes the tail
# of SukiSU_Nova_v3.0.0_30000-x86_64-release.apk read as a build number.
apk_re='^SukiSU(_[A-Za-z]+)?_[^_]*_[0-9]+(-arm64-v8a)?-release'

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
# Nova's stable release carries only ksud/ksuinit/lkm assets, no APK at all, so
# the newest release cannot always answer for the certificate; manager-ci can.
reference_signer() {
  local url rel
  url=""
  for rel in latest tags/manager-ci; do
    url="$(gh api "repos/$UPSTREAM/releases/$rel" \
      --jq '[.assets[].browser_download_url | select(endswith("-release.apk"))
             | select(contains("spoofed") | not)] | .[0] // empty' 2>/dev/null || true)"
    [ -n "$url" ] && break
  done
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

# Upstream's own Gitea. kernel/Kbuild already reads LOCAL_COUNT from this host, so
# it is where the driver version itself comes from; GitHub is a mirror of it.
GITEA_HOST="${GITEA_HOST:-https://git.zako.shirkneko.top:20004}"
GITEA_SLUG="${GITEA_SLUG:-shirkneko/SukiSU}"
GITEA_REPO="$GITEA_HOST/$GITEA_SLUG"
GITEA_API="$GITEA_HOST/api/v1/repos/$GITEA_SLUG"

REF_SIGNER=""
signer_once() {
  [ -n "$REF_SIGNER" ] && { printf '%s' "$REF_SIGNER"; return 0; }
  REF_SIGNER="$(reference_signer || true)"
  [ -n "$REF_SIGNER" ] || return 1
  printf '%s' "$REF_SIGNER"
}

# Highest build in $1 that is at or below the driver. Never above it: a manager
# ahead of its driver is the same uapi mismatch from the other side.
best_at_or_below() {
  build_of "$1" | awk -v want="$DRIVER_VER" \
    '$0+0 <= want+0 && $0+0 > best+0 { best=$0 } END { if (best) print best }'
}

# Just the names in $1 whose build is exactly $2.
names_at() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [ "$(build_of "$n")" = "$2" ] && printf '%s\n' "$n"
  done <<< "$1"
}

# Asset names of tag $2 on host $1.
host_names() {
  case "$1" in
    gitea)  curl -fsSL -m 60 --retry 2 --retry-delay 3 "$GITEA_API/releases/tags/$2" 2>/dev/null \
              | jq -r '.assets[]?.name' 2>/dev/null || true ;;
    github) gh release view "$2" -R "$UPSTREAM" --json assets -q '.assets[].name' 2>/dev/null || true ;;
  esac
}

# Download asset $3 of tag $2 from host $1 into $dl.
host_fetch() {
  case "$1" in
    gitea)  curl -fsSL -m 300 --retry 3 --retry-delay 5 --retry-connrefused \
              -o "$dl/$3" "$GITEA_REPO/releases/download/$2/$3" ;;
    github) gh release download "$2" -R "$UPSTREAM" --pattern "$3" --dir "$dl" ;;
  esac
}

# Every APK that leaves this script must carry the certificate the kernel checks
# in manager/apk_sign.c. That gate, not the host it came from, is what makes a
# non-GitHub source safe to take: an APK without it could not act as the manager.
verify_signed() {
  local signer
  signer="$(signer_once || true)"
  if [ -z "$signer" ]; then
    echo "  cannot read the official signing certificate"
    return 1
  fi
  if ! python3 -I "$SIGNER" "$1" "$signer" >/dev/null; then
    echo "  x $(basename "$1") is not signed by the official manager certificate"
    return 1
  fi
  echo "  ok $(basename "$1")"
}

# Release assets. A $KSU_REF release family is served by its own assets. Failing
# that, candidates are ranked by how close their build sits to the driver and
# never by which host they live on. GitHub's manager-ci stopped being refreshed
# on 2026-11-15 when upstream moved CI mirroring to cnb.cool: it held 30000 while
# the stable release held 35000 and upstream's Gitea held the exact 35034, so
# ranking by source shipped the worst of the three.
from_release() {
  local tags family t names n s tag fallback_tag fallback_normal b host cand

  tags="$(gh release list -R "$UPSTREAM" -L 50 --json tagName,isPrerelease,isDraft \
    -q '.[] | select((.isPrerelease or .isDraft) | not) | .tagName')"
  [ -n "$tags" ] || { echo "  $UPSTREAM has no release"; return 1; }

  family="$(grep -E "^$(printf '%s' "$KSU_REF" | sed 's/[.]/\\./g')(-r[0-9]+)?$" <<< "$tags" || true)"
  if [ -n "$family" ]; then
    tag="" fallback_tag="" fallback_normal=""
    for t in $family; do
      names="$(host_names github "$t" | grep -E -- "${apk_re}(-spoofed)?\.apk\$" || true)"
      n="$(pick "$names" "")"
      s="$(pick "$names" "-spoofed")"
      if [ -n "$n" ] && [ -n "$s" ]; then tag="$t"; break; fi
      if [ -n "$n" ] && [ -z "$fallback_tag" ]; then
        fallback_tag="$t" fallback_normal="$n"
      fi
    done
    if [ -z "$tag" ] && [ -n "$fallback_tag" ]; then
      tag="$fallback_tag" n="$fallback_normal" s=""
      echo "::warning::no release in the $KSU_REF family ships a spoofed manager; attaching the plain one from $tag only"
    fi
    [ -n "$tag" ] || { echo "  no release pairs a manager APK with $KSU_REF"; return 1; }
    host=github
  else
    # One line per candidate: "<build>\t<host>\t<tag>", best build first.
    cand="$( { for host in gitea github; do
                 b="$(best_at_or_below "$(host_names "$host" manager-ci)")"
                 [ -z "$b" ] || printf '%s\t%s\tmanager-ci\n' "$b" "$host"
               done
               t="$(head -n1 <<< "$tags")"
               b="$(best_at_or_below "$(host_names github "$t")")"
               [ -z "$b" ] || printf '%s\tgithub\t%s\n' "$b" "$t"
             } | sort -t"$(printf '\t')" -k1,1nr )"
    [ -n "$cand" ] || { echo "  no manager at or below driver $DRIVER_VER"; return 1; }

    tag="" n="" s=""
    while IFS="$(printf '\t')" read -r b host t; do
      [ -n "${b:-}" ] || continue
      echo "  candidate: $t on $host, build $b"
      names="$(names_at "$(host_names "$host" "$t")" "$b" \
               | grep -E -- "${apk_re}(-spoofed)?\.apk\$" || true)"
      n="$(pick "$names" "")"
      [ -n "$n" ] || { echo "    no arm64 plain APK"; continue; }
      s="$(pick "$names" "-spoofed")"
      tag="$t"
      if [ "$b" = "$DRIVER_VER" ]; then
        reasons+=("\`$KSU_REF\` has no release of its own, so this is the \`$t\` build that matches driver $DRIVER_VER")
      else
        reasons+=("\`$KSU_REF\` has no release of its own, so this is \`$t\` build $b -- the newest upstream manager at or below driver $DRIVER_VER")
      fi
      break
    done <<< "$cand"
    [ -n "$tag" ] || { echo "  no candidate carried an arm64 manager"; return 1; }
    [ -n "$s" ] || echo "::warning::no release in the $KSU_REF family ships a spoofed manager; attaching the plain one from $tag only"
  fi

  host_fetch "$host" "$tag" "$n" || return 1
  verify_signed "$dl/$n" || return 1
  normal_path="$dl/$n"
  if [ -n "$s" ]; then
    if host_fetch "$host" "$tag" "$s" && verify_signed "$dl/$s"; then
      spoofed_path="$dl/$s"
    else
      s=""
    fi
  fi
  build="$(build_of "$n")"
  if [ "$host" = gitea ]; then
    source_md="the upstream prerelease [$tag]($GITEA_REPO/releases/tag/$tag) on upstream's own Gitea -- GitHub's mirror of it is stale"
  else
    source_md="the upstream release [$tag](https://github.com/$UPSTREAM/releases/tag/$tag)"
  fi
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
