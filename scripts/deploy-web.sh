#!/usr/bin/env bash
# Publish the MacLucent site (web/) and the current DMG (build/MacLucent-<date>-<commit>.dmg).
#
#     ./scripts/deploy-web.sh              # site + the DMG, if it changed
#     ./scripts/deploy-web.sh --no-dmg     # site only
#     ./scripts/deploy-web.sh --dry-run    # print every AWS call, make none
#     ./scripts/deploy-web.sh --allow-unsigned  # publish a DMG that isn't notarized
#
# Build the DMG first with ./scripts/package.sh. Idempotent: run it again after
# editing the page — it creates what's missing and updates the rest.
#
# It never touches bucket access: ./scripts/deploy-cdn.sh owns that (the bucket
# is private, readable only through CloudFront), and two scripts writing one
# policy would undo each other. Modelled on starch's tools/deploy-web.sh.
set -euo pipefail

HOST="${ML_HOST:-maclucent.pbcs.io}"
LATEST_KEY="MacLucent.dmg" # a stable name for "whatever is current"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WEB="$HERE/web"
OUT="$HERE/build"

DRY=0
DO_DMG=1
ALLOW_UNSIGNED=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        --no-dmg)  DO_DMG=0 ;;
        --allow-unsigned) ALLOW_UNSIGNED=1 ;;
        -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (try --dry-run, --no-dmg)" >&2; exit 2 ;;
    esac
done

C_B=$'\e[1;34m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_0=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
run()  { if [[ $DRY -eq 1 ]]; then printf '    %s[dry-run]%s %s\n' "$C_Y" "$C_0" "$*"; else "$@"; fi; }

# ── preflight ────────────────────────────────────────────────────────────────
step "Checking prerequisites"
command -v aws >/dev/null || die "the aws CLI is not installed"
[[ -f $WEB/index.html ]] || die "no site at $WEB"
aws sts get-caller-identity >/dev/null 2>&1 \
    || die "the aws CLI has no working credentials — run: aws login"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${ML_BUCKET:-maclucent-downloads-$ACCOUNT}"
REGION="${ML_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
ok "aws CLI, account $ACCOUNT, region $REGION, bucket $BUCKET"

if [[ $DO_DMG -eq 1 ]]; then
    # Newest by mtime: MacLucent-<date>-<commit>.dmg, as package.sh names it.
    dmg="$(ls -t "$OUT"/MacLucent-*-*.dmg 2>/dev/null | head -1 || true)"
    [[ -n $dmg ]] || die "no DMG in $OUT — run ./scripts/package.sh first, or pass --no-dmg"
    DMG_KEY="$(basename "$dmg")"
    ok "DMG: $DMG_KEY ($(du -h "$dmg" | cut -f1 | tr -d ' '))"
    # The page tells people the download just opens: only publish a notarized, stapled DMG.
    if xcrun stapler validate -q "$dmg" 2>/dev/null; then
        ok "signed and notarized"
    elif [[ $ALLOW_UNSIGNED -eq 1 ]]; then
        warn "NOT notarized — Gatekeeper will warn (--allow-unsigned)"
    else
        die "$DMG_KEY isn't notarized — package it on a Mac with the Developer ID certificates, or pass --allow-unsigned"
    fi
else
    # The page still has to link to something: the newest DMG already uploaded.
    DMG_KEY="$(aws s3 ls "s3://$BUCKET/" 2>/dev/null | awk '{print $4}' \
        | grep -E '^MacLucent-[0-9]{8}-[0-9a-f]+\.dmg$' | sort | tail -1 || true)"
    [[ -n $DMG_KEY ]] || die "no DMG uploaded yet — run without --no-dmg once"
fi

# The page shows the release date, for people: MacLucent-20261114-7f1f1d6.dmg → "14 November 2026".
day="$(sed -nE 's/^MacLucent-([0-9]{8})-[0-9a-f]+\.dmg$/\1/p' <<<"$DMG_KEY")"
VERSION="$( [[ -n $day ]] && LC_ALL=C date -j -f %Y%m%d "$day" "+%-d %B %Y" 2>/dev/null || echo "Latest version")"

# ── the bucket ───────────────────────────────────────────────────────────────
step "Bucket"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    ok "s3://$BUCKET"
else
    # us-east-1 must NOT be given a LocationConstraint (InvalidLocationConstraint).
    if [[ $REGION == us-east-1 ]]; then
        run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
    else
        run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
            --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    fi
    ok "created s3://$BUCKET (private)"
    warn "new bucket — run ./scripts/deploy-cdn.sh to publish it over https"
fi

# ── the DMG ──────────────────────────────────────────────────────────────────
if [[ $DO_DMG -eq 1 ]]; then
    step "DMG"
    local_sum="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
    remote_sum="$(aws s3 cp "s3://$BUCKET/$DMG_KEY.sha256" - 2>/dev/null | cut -d' ' -f1 || true)"
    if [[ $local_sum == "$remote_sum" ]]; then
        ok "unchanged — skipping the upload"
    else
        run aws s3 cp "$dmg" "s3://$BUCKET/$DMG_KEY" \
            --content-type application/x-apple-diskimage \
            --cache-control "public, max-age=86400" --only-show-errors
        ok "s3://$BUCKET/$DMG_KEY"
        # After the DMG, never before: if the upload failed, the old checksum must stay.
        sumfile="$(mktemp)"
        printf '%s  %s\n' "$local_sum" "$DMG_KEY" > "$sumfile"
        run aws s3 cp "$sumfile" "s3://$BUCKET/$DMG_KEY.sha256" \
            --content-type text/plain --cache-control "public, max-age=300" --only-show-errors
        rm -f "$sumfile"
        ok "sha256 $local_sum"
    fi
    # Server-side copies: "latest" costs an API call, not another upload.
    run aws s3 cp "s3://$BUCKET/$DMG_KEY" "s3://$BUCKET/$LATEST_KEY" \
        --content-type application/x-apple-diskimage \
        --cache-control "public, max-age=300" --only-show-errors
    run aws s3 cp "s3://$BUCKET/$DMG_KEY.sha256" "s3://$BUCKET/$LATEST_KEY.sha256" \
        --content-type text/plain --cache-control "public, max-age=300" --only-show-errors
    ok "$LATEST_KEY points at $DMG_KEY"
fi

# ── the site ─────────────────────────────────────────────────────────────────
# The repo keeps placeholders, so index.html stays a template; the real values
# go into a staged copy.
step "Site"
dmg_url="https://$HOST/$DMG_KEY"
size="$(aws s3api head-object --bucket "$BUCKET" --key "$DMG_KEY" --query ContentLength --output text 2>/dev/null || true)"
if [[ $size =~ ^[0-9]+$ ]]; then
    size="$(awk -v b="$size" 'BEGIN { printf "%.1f MB", b / 1048576 }')"
elif [[ -n ${dmg:-} ]]; then
    size="$(du -h "$dmg" | cut -f1 | tr -d ' ')B"
else
    size="DMG"
fi
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
cp -R "$WEB"/. "$stage"/
# (perl, not sed -i: BSD and GNU sed disagree about -i.)
DMG_URL="$dmg_url" SIZE="$size" VERSION="$VERSION" perl -pi -e '
    s/DOWNLOAD-URL/$ENV{DMG_URL}/g; s/DOWNLOAD-SIZE/$ENV{SIZE}/g; s/RELEASE-VERSION/$ENV{VERSION}/g
' "$stage/index.html"
grep -q 'DOWNLOAD-URL\|DOWNLOAD-SIZE\|RELEASE-VERSION' "$stage/index.html" && die "placeholders left in index.html"
ok "download links → $dmg_url ($size, $VERSION)"

# Assets cache for a week, the page not at all (or an edit stays invisible).
run aws s3 sync "$stage/assets/" "s3://$BUCKET/assets/" \
    --cache-control "public, max-age=604800" --only-show-errors --delete
run aws s3 cp "$stage/style.css" "s3://$BUCKET/style.css" \
    --content-type "text/css" --cache-control "public, max-age=3600" --only-show-errors
run aws s3 cp "$stage/index.html" "s3://$BUCKET/index.html" \
    --content-type "text/html; charset=utf-8" --cache-control "no-cache" --only-show-errors
ok "site uploaded"

# ── CloudFront ───────────────────────────────────────────────────────────────
# Uploading isn't publishing: CloudFront serves its cache until told otherwise.
step "CloudFront"
dist="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '$HOST')].Id | [0]" \
    --output text 2>/dev/null || echo None)"
if [[ -z $dist || $dist == None ]]; then
    warn "no distribution serving $HOST yet — run ./scripts/deploy-cdn.sh"
    site_url="s3://$BUCKET (not published over https yet)"
else
    run aws cloudfront create-invalidation --distribution-id "$dist" --paths "/*" >/dev/null
    ok "invalidated $dist"
    site_url="https://$HOST"
fi

step "Done"
cat <<EOF

  Site      ${site_url}
  DMG       ${dmg_url}
  Checksum  ${dmg_url}.sha256
  Latest    https://${HOST}/${LATEST_KEY}

EOF
