#!/usr/bin/env bash
# Put CloudFront, a certificate and a hostname in front of the MacLucent bucket.
# (A copy of starch's tools/deploy-cdn.sh.)
#
#     ./scripts/deploy-cdn.sh            # do it
#     ./scripts/deploy-cdn.sh --dry-run  # print every AWS call, make none
#
# Idempotent at every step: it looks for what it needs before creating it, so
# re-running after a failure picks up where it stopped rather than making a
# second certificate and a second distribution.
#
# What it builds, in order, because each step needs the one before it:
#
#   1. an ACM certificate for the hostname, validated by DNS
#   2. the Route 53 record that validates it, then waits for ISSUED
#   3. an Origin Access Control, so CloudFront can read a private bucket
#   4. the distribution, with the certificate and the hostname
#   5. a bucket policy naming that distribution — and *only* that distribution
#   6. Block Public Access fully back on: with OAC the bucket is not public
#   7. an A/AAAA alias in Route 53 pointing the hostname at CloudFront
#
# The certificate must live in us-east-1 whatever region the bucket is in.
# CloudFront only reads certificates from there; one in another region is
# simply invisible to it, with no error that says so.
set -euo pipefail

HOST="${ML_HOST:-maclucent.pbcs.io}"
ZONE_NAME="${ML_ZONE:-pbcs.io.}"
BUCKET_REGION="${ML_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"

# Fixed by AWS: every CloudFront distribution lives in this hosted zone, and an
# alias record has to name it rather than the distribution's own zone.
CF_ZONE_ID="Z2FDTNDATAQYW2"
ACM_REGION="us-east-1"

DRY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

C_B=$'\e[1;34m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_R=$'\e[1;31m'; C_0=$'\e[0m'
step() { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
run()  { if [[ $DRY -eq 1 ]]; then printf '    %s[dry-run]%s %s\n' "$C_Y" "$C_0" "$*"; else "$@"; fi; }

step "Checking prerequisites"
command -v aws >/dev/null || die "the aws CLI is not installed"
command -v jq  >/dev/null || die "jq is required"
aws sts get-caller-identity >/dev/null 2>&1 || die "no working AWS credentials"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${ML_BUCKET:-maclucent-downloads-$ACCOUNT}"
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 \
    || die "s3://$BUCKET does not exist — run ./scripts/deploy-web.sh first"

ZONE_ID="$(aws route53 list-hosted-zones \
    --query "HostedZones[?Name=='$ZONE_NAME'].Id | [0]" --output text 2>/dev/null)"
[[ -n $ZONE_ID && $ZONE_ID != None ]] || die "no Route 53 hosted zone for $ZONE_NAME"
ZONE_ID="${ZONE_ID#/hostedzone/}"
ok "account $ACCOUNT, zone $ZONE_NAME ($ZONE_ID), bucket $BUCKET"

# ── 1. certificate ───────────────────────────────────────────────────────────
step "Certificate for $HOST"
CERT_ARN="$(aws acm list-certificates --region "$ACM_REGION" \
    --query "CertificateSummaryList[?DomainName=='$HOST'].CertificateArn | [0]" \
    --output text 2>/dev/null)"

if [[ -n $CERT_ARN && $CERT_ARN != None ]]; then
    ok "reusing $CERT_ARN"
else
    if [[ $DRY -eq 1 ]]; then
        printf '    %s[dry-run]%s aws acm request-certificate --domain-name %s\n' "$C_Y" "$C_0" "$HOST"
        CERT_ARN="arn:aws:acm:us-east-1:$ACCOUNT:certificate/DRY-RUN"
    else
        CERT_ARN="$(aws acm request-certificate --region "$ACM_REGION" \
            --domain-name "$HOST" --validation-method DNS \
            --query CertificateArn --output text)"
        ok "requested $CERT_ARN"
        # ACM populates the validation record asynchronously; asking too early
        # returns a certificate with no ResourceRecord at all.
        for _ in $(seq 1 30); do
            rr="$(aws acm describe-certificate --region "$ACM_REGION" \
                --certificate-arn "$CERT_ARN" \
                --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json)"
            [[ $rr != null ]] && break
            sleep 2
        done
    fi
fi

# ── 2. validation record, then wait for ISSUED ───────────────────────────────
step "DNS validation"
if [[ $DRY -eq 1 ]]; then
    printf '    %s[dry-run]%s create the _acm-validations CNAME and wait for ISSUED\n' "$C_Y" "$C_0"
else
    status="$(aws acm describe-certificate --region "$ACM_REGION" \
        --certificate-arn "$CERT_ARN" --query Certificate.Status --output text)"
    if [[ $status == ISSUED ]]; then
        ok "already ISSUED"
    else
        rr="$(aws acm describe-certificate --region "$ACM_REGION" \
            --certificate-arn "$CERT_ARN" \
            --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json)"
        [[ $rr != null ]] || die "ACM has not published a validation record yet — re-run in a moment"
        vname="$(jq -r .Name <<<"$rr")"; vvalue="$(jq -r .Value <<<"$rr")"
        # UPSERT rather than CREATE: re-running must not fail on a record that
        # is already there from an earlier attempt.
        aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
            --change-batch "$(jq -n --arg n "$vname" --arg v "$vvalue" '{
                Changes: [{Action: "UPSERT", ResourceRecordSet: {
                    Name: $n, Type: "CNAME", TTL: 300,
                    ResourceRecords: [{Value: $v}]}}]}')" >/dev/null
        ok "validation CNAME written: ${vname%%.*}…"
        warn "waiting for ACM to validate (usually under two minutes)"
        aws acm wait certificate-validated --region "$ACM_REGION" --certificate-arn "$CERT_ARN"
        ok "certificate ISSUED"
    fi
fi

# ── 3. origin access control ─────────────────────────────────────────────────
step "Origin Access Control"
OAC_NAME="maclucent-$BUCKET"
OAC_ID="$(aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='$OAC_NAME'].Id | [0]" --output text 2>/dev/null)"
if [[ -n $OAC_ID && $OAC_ID != None ]]; then
    ok "reusing $OAC_ID"
elif [[ $DRY -eq 1 ]]; then
    printf '    %s[dry-run]%s aws cloudfront create-origin-access-control %s\n' "$C_Y" "$C_0" "$OAC_NAME"
    OAC_ID="DRYRUNOAC"
else
    OAC_ID="$(aws cloudfront create-origin-access-control \
        --origin-access-control-config "$(jq -n --arg n "$OAC_NAME" '{
            Name: $n, Description: "MacLucent site and DMG",
            SigningProtocol: "sigv4", SigningBehavior: "always",
            OriginAccessControlOriginType: "s3"}')" \
        --query OriginAccessControl.Id --output text)"
    ok "created $OAC_ID"
fi

# ── 4. distribution ──────────────────────────────────────────────────────────
step "CloudFront distribution"
# The REST endpoint, not the website endpoint: OAC signs requests to the S3 API,
# and the website endpoint does not accept signed requests at all.
ORIGIN_DOMAIN="$BUCKET.s3.$BUCKET_REGION.amazonaws.com"
DIST_ID="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?contains(Aliases.Items || \`[]\`, '$HOST')].Id | [0]" \
    --output text 2>/dev/null)"

if [[ -n $DIST_ID && $DIST_ID != None ]]; then
    ok "reusing $DIST_ID"
    DIST_DOMAIN="$(aws cloudfront get-distribution --id "$DIST_ID" \
        --query Distribution.DomainName --output text)"
elif [[ $DRY -eq 1 ]]; then
    printf '    %s[dry-run]%s aws cloudfront create-distribution (alias %s, origin %s)\n' \
        "$C_Y" "$C_0" "$HOST" "$ORIGIN_DOMAIN"
    DIST_ID="DRYRUNDIST"; DIST_DOMAIN="dryrun.cloudfront.net"
else
    cfg="$(jq -n \
        --arg host "$HOST" --arg origin "$ORIGIN_DOMAIN" \
        --arg oac "$OAC_ID" --arg cert "$CERT_ARN" --arg ref "maclucent-$(date +%s)" '
    {
      CallerReference: $ref,
      Comment: "MacLucent — site and DMG",
      Enabled: true,
      Aliases: { Quantity: 1, Items: [$host] },
      DefaultRootObject: "index.html",
      Origins: { Quantity: 1, Items: [{
        Id: "s3-maclucent",
        DomainName: $origin,
        OriginAccessControlId: $oac,
        S3OriginConfig: { OriginAccessIdentity: "" }
      }]},
      DefaultCacheBehavior: {
        TargetOriginId: "s3-maclucent",
        ViewerProtocolPolicy: "redirect-to-https",
        AllowedMethods: { Quantity: 2, Items: ["GET","HEAD"],
          CachedMethods: { Quantity: 2, Items: ["GET","HEAD"] } },
        Compress: true,
        # CachingOptimized. A managed policy, so the cache behaviour is not a
        # pile of legacy ForwardedValues to maintain here.
        CachePolicyId: "658327ea-f89d-4fab-a63d-7e88639e58f6"
      },
      ViewerCertificate: {
        ACMCertificateArn: $cert,
        SSLSupportMethod: "sni-only",
        MinimumProtocolVersion: "TLSv1.2_2021"
      },
      PriceClass: "PriceClass_100"
    }')"
    DIST_JSON="$(aws cloudfront create-distribution --distribution-config "$cfg")"
    DIST_ID="$(jq -r .Distribution.Id <<<"$DIST_JSON")"
    DIST_DOMAIN="$(jq -r .Distribution.DomainName <<<"$DIST_JSON")"
    ok "created $DIST_ID ($DIST_DOMAIN)"
fi
DIST_ARN="arn:aws:cloudfront::$ACCOUNT:distribution/$DIST_ID"

# ── 5. bucket policy: this distribution only ─────────────────────────────────
step "Locking the bucket to CloudFront"
policy="$(jq -n --arg b "$BUCKET" --arg arn "$DIST_ARN" '{
  Version: "2012-10-17",
  Statement: [{
    Sid: "AllowCloudFrontServicePrincipalReadOnly",
    Effect: "Allow",
    Principal: { Service: "cloudfront.amazonaws.com" },
    Action: "s3:GetObject",
    Resource: ("arn:aws:s3:::" + $b + "/*"),
    Condition: { StringEquals: { "AWS:SourceArn": $arn } }
  }]}')"
printf '%s\n' "$policy" | sed 's/^/      /'
if [[ $DRY -eq 1 ]]; then
    printf '    %s[dry-run]%s replace the public policy with the one above\n' "$C_Y" "$C_0"
else
    printf '%s' "$policy" | aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///dev/stdin
    ok "public read removed; only $DIST_ID can read the bucket"
fi

# With OAC the policy names a service principal rather than "*", so nothing
# about the bucket is public any more and all four blocks can go back on.
run aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
ok "Block Public Access fully on"

# The website endpoint is meaningless now — it serves HTTP and the bucket is
# private — so take it off rather than leave a dead URL that looks alive.
run aws s3api delete-bucket-website --bucket "$BUCKET" 2>/dev/null || true
ok "S3 website endpoint removed"

# ── 6. DNS ───────────────────────────────────────────────────────────────────
step "Route 53"
if [[ $DRY -eq 1 ]]; then
    printf '    %s[dry-run]%s UPSERT A and AAAA alias %s -> %s\n' "$C_Y" "$C_0" "$HOST" "$DIST_DOMAIN"
else
    aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
        --change-batch "$(jq -n --arg h "$HOST" --arg d "$DIST_DOMAIN" --arg z "$CF_ZONE_ID" '{
            Changes: [
              {Action:"UPSERT", ResourceRecordSet:{Name:$h, Type:"A",
                AliasTarget:{HostedZoneId:$z, DNSName:$d, EvaluateTargetHealth:false}}},
              {Action:"UPSERT", ResourceRecordSet:{Name:$h, Type:"AAAA",
                AliasTarget:{HostedZoneId:$z, DNSName:$d, EvaluateTargetHealth:false}}}
            ]}')" >/dev/null
    ok "$HOST -> $DIST_DOMAIN (A and AAAA)"
fi

step "Done"
cat <<EOF

  Site      https://${HOST}
  DMG       https://${HOST}/MacLucent.dmg

  CloudFront  ${DIST_ID}  (${DIST_DOMAIN})
  Certificate ${CERT_ARN}

  The distribution takes a few minutes to finish deploying before the
  hostname answers. Watch it with:

      aws cloudfront get-distribution --id ${DIST_ID} --query Distribution.Status --output text

  From now on ./scripts/deploy-web.sh publishes updates and invalidates the
  cache; the bucket is no longer readable except through CloudFront.

EOF
