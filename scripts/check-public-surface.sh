#!/usr/bin/env bash
# Checks the public surface from outside: TLS versions, response headers, and
# the DNS records that govern certificate issuance. Needs no cluster access and
# no credential, so it runs on a schedule and from a laptop alike.
#
# Findings the threat model already records are listed in KNOWN_OPEN below, so
# this gates against regression rather than against work not yet done. Closing
# one means deleting its line: a check that passes while still listed fails
# here, which is what keeps the list from going stale.
#
# Usage: scripts/check-public-surface.sh [--strict] [host]
#   --strict  also fail when a check cannot be carried out
set -euo pipefail

HOST=${HOST:-sindrg.com}
STRICT=false

while [ $# -gt 0 ]; do
  case $1 in
    --strict) STRICT=true ;;
    -*)
      printf 'unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *) HOST=$1 ;;
  esac
  shift
done

# Paths on the domain that must all carry the response headers. The root is
# nginx and /sky/ is the application; a header set in one place only is a
# header that is missing.
PATHS=("/" "/sky/")

# Checks expected to fail today, with the threat model finding they belong to.
# Delete a line when its finding closes.
KNOWN_OPEN=(
  "tls10-refused"    # finding 5, no SSL policy is attached to the Gateway
  "tls11-refused"    # finding 5
  "hsts"             # finding 6
  "csp"              # finding 6
  "nosniff"          # finding 6
  "referrer-policy"  # finding 6
  "frame-ancestors"  # finding 6
  "caa"              # finding 3, unverified until this runs
  "dnssec"           # finding 9, unverified until this runs
)

passed=0
regressions=0
known=0
resolved=0
unknown=0

is_known() {
  local id=$1 entry
  for entry in "${KNOWN_OPEN[@]}"; do
    [ "${entry%% *}" = "$id" ] && return 0
  done
  return 1
}

# A check reports one of three outcomes. "inconclusive" exists because a probe
# this host cannot carry out is not evidence that the server is healthy, and
# recording it as a pass is the failure mode this script is written against.
report() {
  local outcome=$1 id=$2 detail=$3
  case "$outcome" in
    pass)
      if is_known "$id"; then
        printf 'RESOLVED  %-16s %s\n' "$id" "$detail"
        printf '          remove %s from KNOWN_OPEN in %s\n' "$id" "$(basename "$0")"
        resolved=$((resolved + 1))
      else
        printf 'ok        %-16s %s\n' "$id" "$detail"
        passed=$((passed + 1))
      fi
      ;;
    fail)
      if is_known "$id"; then
        printf 'known     %-16s %s\n' "$id" "$detail"
        known=$((known + 1))
      else
        printf 'REGRESSED %-16s %s\n' "$id" "$detail"
        regressions=$((regressions + 1))
      fi
      ;;
    inconclusive)
      printf 'unknown   %-16s %s\n' "$id" "$detail"
      unknown=$((unknown + 1))
      ;;
  esac
}

# openssl reads no proxy from the environment, and CI reaches the internet
# directly, so this only matters when running from a proxied network.
openssl_args=()
if [ -n "${HTTPS_PROXY:-}" ]; then
  openssl_args=(-proxy "${HTTPS_PROXY#http://}")
fi

handshake() {
  local version=$1
  # SECLEVEL=0 is required to offer TLS 1.0 and 1.1 at all: OpenSSL 3 refuses
  # them client-side by default, and that refusal is indistinguishable from a
  # healthy server unless the client is allowed to make the offer.
  timeout 30 openssl s_client "-$version" -cipher 'DEFAULT:@SECLEVEL=0' \
    "${openssl_args[@]}" -connect "$HOST:443" -servername "$HOST" \
    </dev/null 2>&1 || true
}

check_refused() {
  local version=$1 id=$2 out
  out=$(handshake "$version")

  if printf '%s' "$out" | grep -q 'no protocols available'; then
    report inconclusive "$id" "this openssl will not offer $version, so the server was never asked"
  elif printf '%s' "$out" | grep -qE 'alert protocol version|wrong version number|unsupported protocol'; then
    report pass "$id" "server refused $version"
  elif printf '%s' "$out" | grep -q '^New,'; then
    report fail "$id" "server accepted $version"
  else
    report inconclusive "$id" "no verdict from the $version handshake"
  fi
}

check_accepted() {
  local version=$1 id=$2 out
  out=$(handshake "$version")

  if printf '%s' "$out" | grep -q '^New,'; then
    report pass "$id" "server accepted $version"
  else
    report fail "$id" "server did not complete a $version handshake"
  fi
}

# Headers are fetched once per path and reused, so one request serves every
# header check rather than one request each. GET rather than HEAD, because a
# server may answer the two differently and a browser sends GET.
declare -A HEADERS
fetch_headers() {
  local path
  for path in "${PATHS[@]}"; do
    HEADERS["$path"]=$(curl -sS -D - -o /dev/null -m 30 "https://${HOST}${path}" 2>/dev/null |
      tr -d '\r' | tr '[:upper:]' '[:lower:]' || true)
  done
}

# A request that never arrived says nothing about the headers the server sets,
# so it is reported as such rather than as an absent header. The last status
# line is the one that counts: a proxy CONNECT and an error page from an
# intermediary both look like responses, and neither carries the site's headers.
unreachable() {
  local path status
  for path in "${PATHS[@]}"; do
    status=$(printf '%s' "${HEADERS[$path]}" |
      grep -E '^http/[0-9.]+ [0-9]{3}' | tail -1 | awk '{print $2}')
    case "$status" in
      2??|3??) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

check_header() {
  local id=$1 header=$2 pattern=$3 path missing=()

  if unreachable; then
    report inconclusive "$id" "no response from $HOST, so headers were not read"
    return
  fi

  for path in "${PATHS[@]}"; do
    if ! printf '%s' "${HEADERS[$path]}" | grep -qE "^${header}:.*${pattern}"; then
      missing+=("$path")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    report pass "$id" "$header present on every path"
  else
    report fail "$id" "$header missing on ${missing[*]}"
  fi
}

check_redirect() {
  local out
  # curl does not follow redirects unless asked, so the first response is the
  # one under test.
  out=$(curl -sS -D - -o /dev/null -m 30 "http://${HOST}/" 2>/dev/null |
    tr -d '\r' | tr '[:upper:]' '[:lower:]' || true)

  local status
  status=$(printf '%s' "$out" | grep -E '^http/[0-9.]+ [0-9]{3}' | tail -1 | awk '{print $2}')

  case "$status" in
    30[128])
      if printf '%s' "$out" | grep -qE '^location: https://'; then
        report pass "http-redirect" "plain HTTP redirects to HTTPS"
      else
        report fail "http-redirect" "redirected, but not to HTTPS"
      fi
      ;;
    2??)
      report fail "http-redirect" "plain HTTP served content instead of redirecting"
      ;;
    "")
      report inconclusive "http-redirect" "no response on port 80"
      ;;
    *)
      # An error status says nothing about how redirects are configured, and
      # may not have come from the origin at all.
      report inconclusive "http-redirect" "port 80 answered $status"
      ;;
  esac
}

check_dns() {
  local id=$1 type=$2 description=$3 out
  if ! command -v dig >/dev/null 2>&1; then
    report inconclusive "$id" "dig is not installed, so $type was not queried"
    return
  fi

  out=$(dig +short "$type" "$HOST" 2>/dev/null || true)
  if [ -n "$out" ]; then
    report pass "$id" "$description"
  else
    report fail "$id" "no $type record"
  fi
}

printf 'Checking the public surface of %s\n\n' "$HOST"

check_refused tls1 tls10-refused
check_refused tls1_1 tls11-refused
check_accepted tls1_2 tls12-accepted
check_accepted tls1_3 tls13-accepted

check_redirect

fetch_headers
check_header hsts strict-transport-security 'max-age=[0-9]+'
check_header csp content-security-policy '.'
check_header nosniff x-content-type-options 'nosniff'
check_header referrer-policy referrer-policy '.'
check_header frame-ancestors content-security-policy 'frame-ancestors'

check_dns caa CAA "certificate issuance is restricted"
check_dns dnssec DS "the zone is signed"

printf '\n%s ok, %s known open, %s regressed, %s resolved, %s inconclusive\n' \
  "$passed" "$known" "$regressions" "$resolved" "$unknown"

status=0
if [ "$regressions" -gt 0 ] || [ "$resolved" -gt 0 ]; then
  status=1
fi
if [ "$STRICT" = true ] && [ "$unknown" -gt 0 ]; then
  status=1
fi
exit "$status"
