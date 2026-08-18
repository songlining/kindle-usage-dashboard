#!/usr/bin/env bash
# Diagnose and optionally repair macOS routing for Kindle USBNetwork/RNDIS.
# Safe default: read-only diagnostics. It does not enable Kindle networking unless
# you pass --enable-rndis or --fix.

set -u

KINDLE_HOST="${KINDLE_HOST:-192.168.15.244}"
KINDLE_MAC_IP="${KINDLE_MAC_IP:-192.168.15.201}"
RNDIS_SERVICE="${RNDIS_SERVICE:-RNDIS/Ethernet Gadget}"
WIFI_SERVICE="${WIFI_SERVICE:-Wi-Fi}"
PING_COUNT="${PING_COUNT:-2}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-3}"

DO_FIX=0
DO_ENABLE_RNDIS=0
DO_DISABLE_RNDIS=0
DO_ADD_ROUTE=0
DO_PING=1
DO_SSH=0
DO_LOG=0

usage() {
  cat <<'EOF'
Usage: kindle-usbnet-diagnose.sh [options]

Diagnoses macOS routing problems for Kindle USBNetwork/RNDIS.

Safe default:
  kindle-usbnet-diagnose.sh
    Prints network service order, RNDIS config, active interfaces, routes,
    USB hints, and ping result. Does not change settings.

Useful options:
  --fix
      Put Wi-Fi first, move RNDIS lower, disable IPv6 on RNDIS, and add a
      host route to the Kindle if the RNDIS interface is active.
      Does NOT enable RNDIS if it is disabled.

  --enable-rndis
      Enable the RNDIS network service first, then diagnose.

  --disable-rndis
      Disable the RNDIS network service. This is the panic/safe mode if plugging
      in the Kindle breaks Mac routing.

  --add-route
      Add a host route for 192.168.15.244 via the active RNDIS interface.
      Requires sudo if your account cannot alter routes without a password.

  --ssh
      Also test non-interactive SSH to root@192.168.15.244.

  --log
      Save output to ~/Desktop/kindle-usbnet-diagnose-YYYYmmdd-HHMMSS.log.

Environment overrides:
  KINDLE_HOST=192.168.15.244
  KINDLE_MAC_IP=192.168.15.201
  RNDIS_SERVICE='RNDIS/Ethernet Gadget'
  WIFI_SERVICE='Wi-Fi'

Expected healthy state:
  - RNDIS/Ethernet Gadget exists and is enabled when you want USBNetwork active.
  - An interface such as en12 exists with inet 192.168.15.201/24.
  - route -n get 192.168.15.244 uses that RNDIS interface, not Wi-Fi en0.
  - ping 192.168.15.244 succeeds.

Panic reset:
  kindle-usbnet-diagnose.sh --disable-rndis
EOF
}

for arg in "$@"; do
  case "$arg" in
    --fix) DO_FIX=1 ;;
    --enable-rndis) DO_ENABLE_RNDIS=1 ;;
    --disable-rndis) DO_DISABLE_RNDIS=1 ;;
    --add-route) DO_ADD_ROUTE=1 ;;
    --ssh) DO_SSH=1 ;;
    --no-ping) DO_PING=0 ;;
    --log) DO_LOG=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 2 ;;
  esac
done

if [[ "$DO_LOG" -eq 1 ]]; then
  LOG="$HOME/Desktop/kindle-usbnet-diagnose-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee "$LOG") 2>&1
  echo "Writing log to: $LOG"
fi

section() {
  printf '\n==== %s ====\n' "$*"
}

run() {
  printf '\n$ %s\n' "$*"
  "$@"
}

have_service() {
  networksetup -listallnetworkservices 2>/dev/null | sed 's/^\*//' | grep -Fxq "$1"
}

service_is_disabled() {
  networksetup -listallnetworkservices 2>/dev/null | grep -Fxq "*$1"
}

service_device() {
  local svc="$1"
  networksetup -listnetworkserviceorder 2>/dev/null | awk -v svc="$svc" '
    $0 ~ "\\) " svc "$" || $0 == "(*) " svc {found=1; next}
    found && /Device: / {sub(/^.*Device: /, ""); sub(/\).*$/, ""); print; exit}
  '
}

active_rndis_iface_by_ip() {
  ifconfig -a 2>/dev/null | awk -v ip="$KINDLE_MAC_IP" '
    /^[a-z0-9]+: flags=/ {iface=$1; sub(":$", "", iface)}
    $1 == "inet" && $2 == ip {print iface; exit}
  '
}

active_rndis_iface() {
  local dev by_ip

  # A disabled or unplugged service can still have a remembered interface name
  # such as en12. Treat it as active only when macOS has actually assigned the
  # expected Kindle-side address.
  if have_service "$RNDIS_SERVICE" && service_is_disabled "$RNDIS_SERVICE"; then
    return 1
  fi

  by_ip="$(active_rndis_iface_by_ip)"
  if [[ -n "$by_ip" ]]; then
    echo "$by_ip"
    return 0
  fi

  dev="$(service_device "$RNDIS_SERVICE")"
  if [[ -n "$dev" ]] && ifconfig "$dev" 2>/dev/null | grep -q "inet $KINDLE_MAC_IP"; then
    echo "$dev"
    return 0
  fi
  return 1
}

reorder_services() {
  local services_tmp ordered_tmp rest_tmp svc ordered_count
  services_tmp="$(mktemp /tmp/kindle-usbnet-services.XXXXXX)"
  ordered_tmp="$(mktemp /tmp/kindle-usbnet-ordered.XXXXXX)"
  rest_tmp="$(mktemp /tmp/kindle-usbnet-rest.XXXXXX)"
  trap 'rm -f "$services_tmp" "$ordered_tmp" "$rest_tmp"' RETURN

  networksetup -listallnetworkservices 2>/dev/null | sed '1d; s/^\*//' > "$services_tmp"
  : > "$ordered_tmp"
  : > "$rest_tmp"

  # Keep Wi-Fi first. Keep common real internet-capable USB/iPhone services before Kindle.
  for svc in "$WIFI_SERVICE" "USB 10/100/1G/2.5G LAN" "iPhone USB" "$RNDIS_SERVICE" "Thunderbolt Bridge" "MT65xx Preloader"; do
    if grep -Fxq "$svc" "$services_tmp" && ! grep -Fxq "$svc" "$ordered_tmp"; then
      printf '%s\n' "$svc" >> "$ordered_tmp"
    fi
  done

  while IFS= read -r svc; do
    if ! grep -Fxq "$svc" "$ordered_tmp"; then
      printf '%s\n' "$svc" >> "$rest_tmp"
    fi
  done < "$services_tmp"

  ordered_count="$(wc -l < "$ordered_tmp" | tr -d ' ')"
  if [[ "$ordered_count" -gt 0 ]]; then
    local ordered_services=()
    while IFS= read -r svc; do
      [[ -n "$svc" ]] && ordered_services+=("$svc")
    done < <(cat "$ordered_tmp" "$rest_tmp")
    networksetup -ordernetworkservices "${ordered_services[@]}"
  fi
}

configure_rndis_no_router() {
  if have_service "$RNDIS_SERVICE"; then
    echo "Configuring $RNDIS_SERVICE as manual $KINDLE_MAC_IP/24 with no default router plus a direct host route to $KINDLE_HOST."
    run networksetup -setmanual "$RNDIS_SERVICE" "$KINDLE_MAC_IP" 255.255.255.0 0.0.0.0
    run networksetup -setadditionalroutes "$RNDIS_SERVICE" "$KINDLE_HOST" 255.255.255.255 ""
  fi
}

remove_kindle_default_route() {
  if netstat -rn -f inet 2>/dev/null | awk -v gw="$KINDLE_HOST" '$1 == "default" && $2 == gw {found=1} END {exit !found}'; then
    echo "Removing extra default route via Kindle ($KINDLE_HOST). This route is the main fragility source."
    if route -n delete default "$KINDLE_HOST" >/dev/null 2>&1; then
      echo "Extra Kindle default route removed without sudo."
    else
      echo "Default-route removal needs sudo. You may be prompted for your macOS password."
      sudo route -n delete default "$KINDLE_HOST" || true
    fi
  fi
}

add_host_route() {
  local iface="$1"
  if [[ -z "$iface" ]]; then
    echo "No active RNDIS interface found; cannot add route."
    return 1
  fi

  remove_kindle_default_route

  echo "Adding/replacing host route for $KINDLE_HOST via interface $iface"
  route -n delete -host "$KINDLE_HOST" >/dev/null 2>&1 || true
  if route -n add -host "$KINDLE_HOST" -interface "$iface" >/dev/null 2>&1; then
    echo "Route added without sudo."
  else
    echo "Route add needs sudo. You may be prompted for your macOS password."
    sudo route -n add -host "$KINDLE_HOST" -interface "$iface"
  fi
}

section "Kindle USBNetwork diagnose"
echo "Timestamp: $(date)"
echo "Host: $(hostname)"
echo "Kindle host: $KINDLE_HOST"
echo "Mac-side Kindle IP: $KINDLE_MAC_IP"
echo "RNDIS service: $RNDIS_SERVICE"

if ! command -v networksetup >/dev/null 2>&1; then
  echo "ERROR: networksetup not found. This script is for macOS."
  exit 1
fi

if [[ "$DO_DISABLE_RNDIS" -eq 1 ]]; then
  section "Safe mode: disable RNDIS"
  if have_service "$RNDIS_SERVICE"; then
    run networksetup -setnetworkserviceenabled "$RNDIS_SERVICE" off
  else
    echo "RNDIS service not found: $RNDIS_SERVICE"
  fi
fi

if [[ "$DO_ENABLE_RNDIS" -eq 1 ]]; then
  section "Enable RNDIS"
  if have_service "$RNDIS_SERVICE"; then
    run networksetup -setnetworkserviceenabled "$RNDIS_SERVICE" on
  else
    echo "RNDIS service not found: $RNDIS_SERVICE"
  fi
fi

if [[ "$DO_FIX" -eq 1 ]]; then
  section "Fix: service order, no-router RNDIS, and IPv6"
  reorder_services
  configure_rndis_no_router
  if have_service "$RNDIS_SERVICE"; then
    run networksetup -setv6off "$RNDIS_SERVICE"
  fi
fi

section "Network service order"
run networksetup -listnetworkserviceorder

section "RNDIS service config"
if have_service "$RNDIS_SERVICE"; then
  if service_is_disabled "$RNDIS_SERVICE"; then
    echo "NOTE: $RNDIS_SERVICE is currently disabled. This is safe for normal Mac routing, but Kindle USBNetwork will not work until enabled."
  fi
  run networksetup -getinfo "$RNDIS_SERVICE"
else
  echo "RNDIS service not found. Plug the Kindle in USBNetwork mode, then check System Settings > Network."
fi

section "Active interface detection"
RNDIS_DEVICE="$(service_device "$RNDIS_SERVICE")"
RNDIS_ACTIVE="$(active_rndis_iface || true)"
echo "Configured RNDIS device from networksetup: ${RNDIS_DEVICE:-not found}"
echo "Active RNDIS interface: ${RNDIS_ACTIVE:-not found}"
if [[ -n "${RNDIS_DEVICE:-}" ]]; then
  run ifconfig "$RNDIS_DEVICE" || true
fi
if [[ -n "${RNDIS_ACTIVE:-}" && "$RNDIS_ACTIVE" != "${RNDIS_DEVICE:-}" ]]; then
  run ifconfig "$RNDIS_ACTIVE" || true
fi

section "USB hints"
system_profiler SPUSBDataType 2>/dev/null | grep -i -B3 -A8 -E 'kindle|amazon|rndis|ethernet gadget|linux|mass storage' || echo "No obvious Kindle/RNDIS USB device found in system_profiler output."

section "Current IPv4 routing"
run netstat -rn -f inet

section "Route checks"
for ip in "$KINDLE_HOST" "$KINDLE_MAC_IP" 192.168.1.1 8.8.8.8; do
  echo "--- route -n get $ip"
  route -n get "$ip" 2>&1 | sed -n '1,18p'
done

if [[ "$DO_FIX" -eq 1 || "$DO_ADD_ROUTE" -eq 1 ]]; then
  section "Fix: Kindle host route"
  if [[ -n "${RNDIS_ACTIVE:-}" ]]; then
    add_host_route "$RNDIS_ACTIVE" || true
    echo "--- route after add"
    route -n get "$KINDLE_HOST" 2>&1 | sed -n '1,18p'
  else
    echo "Skipping host route: no active RNDIS interface."
  fi
fi

if [[ "$DO_PING" -eq 1 ]]; then
  section "Ping Kindle"
  if ping -c "$PING_COUNT" -W 1000 "$KINDLE_HOST"; then
    echo "PING_OK: Kindle replied at $KINDLE_HOST"
  else
    echo "PING_FAIL: Kindle did not reply at $KINDLE_HOST"
  fi
fi

if [[ "$DO_SSH" -eq 1 ]]; then
  section "SSH test"
  if ssh -o ConnectTimeout="$CONNECT_TIMEOUT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$KINDLE_HOST" 'PATH=$PATH:/usr/sbin:/usr/bin:/sbin:/bin:/mnt/us/usbnet/bin; uname -a; which eips || true' ; then
    echo "SSH_OK: non-interactive SSH works."
  else
    echo "SSH_FAIL: SSH did not work. If ping works, try manually: ssh root@$KINDLE_HOST"
  fi
fi

section "Diagnosis summary"
DEFAULT_IFACE="$(route -n get 8.8.8.8 2>/dev/null | awk '/interface:/ {print $2; exit}')"
KINDLE_ROUTE_IFACE="$(route -n get "$KINDLE_HOST" 2>/dev/null | awk '/interface:/ {print $2; exit}')"
echo "Default internet interface: ${DEFAULT_IFACE:-unknown}"
echo "Kindle route interface: ${KINDLE_ROUTE_IFACE:-unknown}"
echo "Active RNDIS interface: ${RNDIS_ACTIVE:-none}"

if [[ -z "${RNDIS_ACTIVE:-}" ]]; then
  echo "Result: Kindle USBNetwork interface is not active on the Mac. If the Kindle is plugged in, toggle USBNetwork in KUAL and replug."
elif [[ "${KINDLE_ROUTE_IFACE:-}" == "$RNDIS_ACTIVE" ]]; then
  echo "Result: Routing to Kindle is correct."
elif [[ "${KINDLE_ROUTE_IFACE:-}" == "en0" ]]; then
  echo "Result: Routing to Kindle is wrong: it is going via Wi-Fi en0. Run: $0 --add-route"
else
  echo "Result: Routing to Kindle may be wrong; expected $RNDIS_ACTIVE but saw ${KINDLE_ROUTE_IFACE:-unknown}."
fi

if have_service "$RNDIS_SERVICE" && service_is_disabled "$RNDIS_SERVICE"; then
  echo "Note: RNDIS service is disabled. That prevents routing breakage but also prevents USBNetwork access."
fi

cat <<EOF

Quick commands:
  Safe/panic mode:       $0 --disable-rndis
  Read-only diagnose:    $0 --log
  Controlled repair:     $0 --fix --log
  Enable then diagnose:  $0 --enable-rndis --fix --ssh --log
EOF
