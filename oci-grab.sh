#!/usr/bin/env bash
# Keeps asking Oracle for a free server until one is free, then stops.
#
# It takes turns between the two Always Free shapes:
#   - Ampere A1 (1 OCPU, 6 GB, ARM)  with Ubuntu 24.04 aarch64
#   - AMD E2.1.Micro (1 GB, x86)     with Ubuntu 24.04
# and uses the hearth-vcn network, its public subnet, a public IP,
# and your ~/.ssh/id_ed25519.pub key — the same choices as the web form.
#
# Usage:   bash oci-grab.sh           keeps trying until it gets one
#          ONCE=1 bash oci-grab.sh    tries each shape once, then exits (used by GitHub Actions)
# Stop it: Ctrl+C (safe at any time)
#
# Exit codes: 0 = got a server (or one already exists)
#             3 = nothing free right now (ONCE mode only)
#             1 = something went wrong — read the message
#
# Needs the OCI CLI set up first (`oci iam region list` must work).

set -u

NAME="hearth"
VCN_NAME="hearth-vcn"
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
WAIT="${WAIT:-120}"          # seconds between tries — slow enough to avoid "too many requests"
BACKOFF="${BACKOFF:-600}"    # seconds to pause if Oracle says "too many requests"
ONCE="${ONCE:-}"             # set to 1 for a single round (one try per shape)
OCI_CONFIG="${OCI_CONFIG_FILE:-$HOME/.oci/config}"

say() { echo "[$(date '+%H:%M:%S')] $*"; }
notify() { command -v notify-send >/dev/null && notify-send "Oracle server" "$1"; }

# --- checks -----------------------------------------------------------------
command -v oci >/dev/null || { echo "The 'oci' command isn't installed yet — do the install step first."; exit 1; }
[ -f "$SSH_KEY" ] || { echo "Can't find $SSH_KEY"; exit 1; }
[ -f "$OCI_CONFIG" ] || { echo "Can't find $OCI_CONFIG — do the API key step first."; exit 1; }

TENANCY=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$OCI_CONFIG")
[ -n "$TENANCY" ] || { echo "No 'tenancy=' line in $OCI_CONFIG"; exit 1; }

say "Checking your Oracle login..."
oci iam region list >/dev/null 2>&1 || { echo "The OCI CLI can't log in — re-check the API key step."; exit 1; }

# --- look up everything the web form had ---------------------------------------
AD=$(oci iam availability-domain list --compartment-id "$TENANCY" --query 'data[0].name' --raw-output)
VCN=$(oci network vcn list --compartment-id "$TENANCY" --display-name "$VCN_NAME" --query 'data[0].id' --raw-output)
[ -n "$VCN" ] && [ "$VCN" != "null" ] || { echo "Can't find a network called $VCN_NAME."; exit 1; }
SUBNET=$(oci network subnet list --compartment-id "$TENANCY" --vcn-id "$VCN" \
  --query 'data[?"prohibit-public-ip-on-vnic"==`false`] | [0].id' --raw-output)
[ -n "$SUBNET" ] && [ "$SUBNET" != "null" ] || { echo "Can't find the public subnet in $VCN_NAME."; exit 1; }

newest_ubuntu() {  # newest Ubuntu 24.04 image that works on shape $1
  oci compute image list --compartment-id "$TENANCY" --operating-system "Canonical Ubuntu" \
    --shape "$1" --sort-by TIMECREATED --sort-order DESC \
    --query 'data[?contains("operating-system-version", `"24.04"`)] | [0].id' --raw-output
}
IMG_ARM=$(newest_ubuntu VM.Standard.A1.Flex)
IMG_AMD=$(newest_ubuntu VM.Standard.E2.1.Micro)

if [ -z "$ONCE" ]; then
  say "Availability domain: $AD"
  say "Public subnet found. Images found: ARM=${IMG_ARM:0:30}…  AMD=${IMG_AMD:0:30}…"
fi

already_have_one() {
  local count
  count=$(oci compute instance list --compartment-id "$TENANCY" --display-name "$NAME" \
    --query 'length(data[?"lifecycle-state"!=`"TERMINATED"` && "lifecycle-state"!=`"TERMINATING"`])' --raw-output 2>/dev/null)
  [ -n "$count" ] && [ "$count" != "0" ]
}

try_launch() {  # $1 = shape, $2 = image, $3 = shape config (or empty)
  local args=(compute instance launch --compartment-id "$TENANCY" --availability-domain "$AD"
              --shape "$1" --image-id "$2" --subnet-id "$SUBNET" --assign-public-ip true
              --display-name "$NAME" --ssh-authorized-keys-file "$SSH_KEY"
              --query 'data.id' --raw-output)
  [ -n "$3" ] && args+=(--shape-config "$3")
  oci "${args[@]}" 2>&1
}

# Only the error code and message — the rest of Oracle's answer has IDs
# that shouldn't end up in a public log.
short_error() {
  grep -oE '"(code|message)": "[^"]*"' <<<"$1" | head -2
}

# --- the loop -----------------------------------------------------------------
attempt=0
while true; do
  if already_have_one; then
    say "You already have a server named '$NAME' — stopping so you don't get two."
    exit 0
  fi

  if [ -n "$ONCE" ] && [ "$attempt" -ge 2 ]; then
    say "Nothing free this round."
    exit 3
  fi

  attempt=$((attempt + 1))
  if [ $((attempt % 2)) -eq 1 ]; then
    shape="VM.Standard.A1.Flex"; image="$IMG_ARM"; config='{"ocpus": 1, "memoryInGBs": 6}'
  else
    shape="VM.Standard.E2.1.Micro"; image="$IMG_AMD"; config=""
  fi

  if [ -z "$image" ] || [ "$image" = "null" ]; then
    say "Try $attempt: no Ubuntu image found for $shape, skipping it."
  else
    say "Try $attempt: asking for $shape..."
    out=$(try_launch "$shape" "$image" "$config")

    if [[ "$out" == ocid1.instance.* ]]; then
      say "GOT ONE! Waiting for it to start..."
      notify "Got a free server! Starting up now."
      oci compute instance get --instance-id "$out" --wait-for-state RUNNING >/dev/null 2>&1
      if [ -n "$ONCE" ]; then
        # Don't print the IP into a public log — it's in the Oracle console.
        say "Server is RUNNING. Shape: $shape. Find its public IP in the Oracle console."
      else
        ip=$(oci compute instance list-vnics --instance-id "$out" --query 'data[0]."public-ip"' --raw-output 2>/dev/null)
        say "Server is RUNNING. Shape: $shape   Public IP: $ip"
        say "Log in with:   ssh ubuntu@$ip"
        notify "Server ready: ssh ubuntu@$ip"
      fi
      exit 0
    elif grep -qiE "out of (host )?capacity|OutOfHostCapacity|InternalError" <<<"$out"; then
      say "  Full right now."
    elif grep -qiE "TooManyRequests|Too many requests|429" <<<"$out"; then
      if [ -n "$ONCE" ]; then
        say "  Oracle says 'too many requests' — skipping this round."
        exit 3
      fi
      say "  Oracle says 'too many requests' — pausing $((BACKOFF / 60)) minutes."
      sleep "$BACKOFF"
      continue
    elif grep -qiE "LimitExceeded" <<<"$out"; then
      say "  Free limit reached for $shape (you may already have one). Stopping."
      short_error "$out"
      exit 1
    else
      say "  Unexpected answer from Oracle — stopping so you can check it:"
      if [ -n "$ONCE" ]; then short_error "$out"; else echo "$out" | tail -15; fi
      exit 1
    fi
  fi

  if [ -n "$ONCE" ]; then
    sleep 5
  else
    sleep $((WAIT + RANDOM % 30))
  fi
done
