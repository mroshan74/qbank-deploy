#!/usr/bin/env bash
#
# Prove the server's hostnames are right BEFORE Traefik asks Let's Encrypt for
# a certificate.
#
#   ./scripts/check-hosts.sh                    # every host
#   ./scripts/check-hosts.sh web homepage       # only the hosts those services own
#
# Run by deploy.sh (for the one service it deploys) and deploy-latest.sh (for
# all of them) before anything is touched; also safe to run by hand at any time.
# It changes nothing.
#
# Why it exists: on 2026-11-07 the first deploy on the new server ran with
# qfoundry.com typed into /opt/qbank/.env instead of qfoundry.in. Every ACME
# challenge failed, Let's Encrypt rate-limited each name for an hour after five
# failures, and nothing said why until `docker logs traefik`. A failed check
# here costs nothing; a failed challenge costs one of five attempts an hour.
#
# Two checks:
#
#   1. The hostnames in .env equal the ones in .env.example, and CLIENT_URL
#      names the three app origins. The template is the production record, in
#      git; the server's .env is typed by hand, and only the template gets
#      reviewed. (A second server with other hostnames changes the template
#      on its own branch, not this check.)
#
#   2. Each hostname, plus www.<HOMEPAGE_HOST>, resolves, and resolves to this
#      machine. A name that does not resolve can never get a certificate. Skipped
#      where getent is missing (Windows/macOS smoke tests); the address
#      comparison is skipped behind NAT, where the public IP is not on any
#      interface and so cannot be compared.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}! $*${NC}"; }

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$DEPLOY_DIR/.env"
ENV_TEMPLATE="$DEPLOY_DIR/.env.example"

[[ -f "$ENV_FILE" ]] || { echo -e "${RED}✗ $ENV_FILE is missing.${NC}" >&2; exit 1; }

# The value of KEY in FILE, without a CR (a .env saved on Windows) or
# surrounding quotes and spaces.
value_of() {
  sed -n "s/^[[:space:]]*$2[[:space:]]*=//p" "$1" | head -1 | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//'
}

# Which hostnames each service owns. The api serves no hostname of its own, but
# its CLIENT_URL and ADMIN_URL are built from the app hosts, so it gets check 1.
SERVICES=("$@")
(( ${#SERVICES[@]} )) || SERVICES=(api web learner writer homepage)
DNS_KEYS=()
for service in "${SERVICES[@]}"; do
  case "$service" in
    api)      ;;
    web)      DNS_KEYS+=(ADMIN_HOST) ;;
    learner)  DNS_KEYS+=(LEARNER_HOST) ;;
    writer)   DNS_KEYS+=(WRITER_HOST) ;;
    homepage) DNS_KEYS+=(HOMEPAGE_HOST) ;;
    *) echo -e "${RED}✗ Unknown service '$service'.${NC}" >&2; exit 1 ;;
  esac
done

problems=()

# ── 1. .env matches the template ───────────────────────────────────────────
for key in HOMEPAGE_HOST ADMIN_HOST LEARNER_HOST WRITER_HOST; do
  want="$(value_of "$ENV_TEMPLATE" "$key")"
  have="$(value_of "$ENV_FILE" "$key")"
  if [[ "$have" != "$want" ]]; then
    problems+=("$key is '${have:-<empty>}' in .env, but .env.example says '$want'.")
  fi
done

client_url="$(value_of "$ENV_FILE" CLIENT_URL)"
for key in ADMIN_HOST LEARNER_HOST WRITER_HOST; do
  origin="https://$(value_of "$ENV_TEMPLATE" "$key")"
  # Compare whole comma-separated entries, ignoring spaces and a trailing slash,
  # so studio.qfoundry.in does not match studio.qfoundry.in.example.com.
  if ! tr ',' '\n' <<<"$client_url" | sed -e 's/[[:space:]]//g' -e 's|/$||' | grep -qxF "$origin"; then
    problems+=("CLIENT_URL does not name $origin (it is '${client_url:-<empty>}').")
  fi
done

if (( ${#problems[@]} == 0 )); then
  ok "Hostnames match .env.example: $(value_of "$ENV_FILE" HOMEPAGE_HOST), $(value_of "$ENV_FILE" ADMIN_HOST), $(value_of "$ENV_FILE" LEARNER_HOST), $(value_of "$ENV_FILE" WRITER_HOST)"
fi

# ── 2. DNS points at this machine ──────────────────────────────────────────
names=()
for key in "${DNS_KEYS[@]}"; do
  host="$(value_of "$ENV_FILE" "$key")"
  [[ -n "$host" ]] || continue
  names+=("$host")
  # The homepage router also answers www. and the two share one certificate,
  # so a missing www record fails the apex's certificate as well.
  if [[ "$key" == HOMEPAGE_HOST ]]; then names+=("www.$host"); fi
done

if (( ${#names[@]} == 0 )); then
  :
elif ! command -v getent >/dev/null 2>&1; then
  warn "getent unavailable: DNS not checked (fine on a workstation, not on the server)."
else
  # This machine's public IPv4 addresses: everything on an interface, minus
  # loopback, private, CGNAT and link-local ranges (Docker's bridges are private).
  local_ips="$(hostname -I 2>/dev/null | tr ' ' '\n' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|169\.254\.)' || true)"
  [[ -n "$local_ips" ]] || warn "No public IPv4 on any interface (behind NAT?): checking only that each name resolves."

  for name in "${names[@]}"; do
    resolved="$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if [[ -z "$resolved" ]]; then
      problems+=("$name does not resolve. Add its A record before deploying.")
      continue
    fi
    if [[ -n "$local_ips" ]] && ! grep -qxF -f <(echo "$local_ips") <<<"$resolved"; then
      problems+=("$name resolves to $(echo $resolved), not this server ($(echo $local_ips)).")
      continue
    fi
    ok "$name -> $(echo $resolved)"
    # Let's Encrypt validates over IPv6 when a name has an AAAA record. One
    # left behind by the registrar's parking page fails the challenge even
    # though the A record is right.
    if getent ahosts "$name" 2>/dev/null | awk '{print $1}' | grep -q ':'; then
      warn "$name also has an AAAA (IPv6) record. Let's Encrypt prefers it: make sure it reaches this server, or delete it."
    fi
  done
fi

# ── Verdict ────────────────────────────────────────────────────────────────
if (( ${#problems[@]} )); then
  echo -e "${RED}Hostname problems:${NC}" >&2
  printf '    %s\n' "${problems[@]}" >&2
  echo -e "${RED}✗ Fix .env or DNS first. Nothing was changed, and no certificate was requested.${NC}" >&2
  exit 1
fi
