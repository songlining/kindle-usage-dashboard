#!/usr/bin/env bash
set -euo pipefail

KINDLE_HOST="${KINDLE_HOST:-192.168.15.244}"
KINDLE_MAC_IP="${KINDLE_MAC_IP:-192.168.15.201}"
KINDLE_USER="${KINDLE_USER:-root}"
RNDIS_SERVICE="${RNDIS_SERVICE:-RNDIS/Ethernet Gadget}"
PNG="${PNG:-/tmp/kindle-usage-dashboard.png}"
REMOTE_PNG="${REMOTE_PNG:-/mnt/us/extensions/kindle-usage-dashboard.png}"
REMOTE_PATH='PATH=$PATH:/usr/sbin:/usr/bin:/sbin:/bin:/mnt/us/usbnet/bin'
AUTO_FIX_USB_ROUTE="${AUTO_FIX_USB_ROUTE:-1}"
DISABLE_RNDIS_AFTER_PUSH="${DISABLE_RNDIS_AFTER_PUSH:-0}"

SSH_OPTS=(
  -o ConnectTimeout=3
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
)

log() {
  printf '%s\n' "$*"
}

warn() {
  printf '%s\n' "$*" >&2
}

service_exists() {
  networksetup -listallnetworkservices 2>/dev/null | sed 's/^\*//' | grep -Fxq "$RNDIS_SERVICE"
}

service_disabled() {
  networksetup -listallnetworkservices 2>/dev/null | grep -Fxq "*$RNDIS_SERVICE"
}

service_device() {
  networksetup -listnetworkserviceorder 2>/dev/null | awk -v svc="$RNDIS_SERVICE" '
    $0 ~ "\\) " svc "$" || $0 == "(*) " svc {found=1; next}
    found && /Device: / {sub(/^.*Device: /, ""); sub(/\).*$/, ""); print; exit}
  '
}

active_rndis_iface() {
  local iface dev
  iface="$(ifconfig -a 2>/dev/null | awk -v ip="$KINDLE_MAC_IP" '
    /^[a-z0-9]+: flags=/ {iface=$1; sub(":$", "", iface)}
    $1 == "inet" && $2 == ip {print iface; exit}
  ')"
  if [[ -n "$iface" ]]; then
    echo "$iface"
    return 0
  fi

  dev="$(service_device)"
  if [[ -n "$dev" ]] && ifconfig "$dev" 2>/dev/null | grep -q "inet $KINDLE_MAC_IP"; then
    echo "$dev"
    return 0
  fi
  return 1
}

route_iface_for() {
  route -n get "$1" 2>/dev/null | awk '/interface:/ {print $2; exit}'
}

has_default_via_kindle() {
  netstat -rn -f inet 2>/dev/null | awk -v gw="$KINDLE_HOST" '$1 == "default" && $2 == gw {found=1} END {exit !found}'
}

remove_kindle_default_route() {
  if has_default_via_kindle; then
    log "Removing extra default route via Kindle ($KINDLE_HOST). This route is the main fragility source."
    route -n delete default "$KINDLE_HOST" >/dev/null 2>&1 || true
  fi
}

ensure_usbnet_route() {
  local iface route_iface

  if ! service_exists; then
    log "Kindle RNDIS service '$RNDIS_SERVICE' not found; skipping push."
    return 1
  fi

  if service_disabled; then
    if [[ "$AUTO_FIX_USB_ROUTE" == "1" ]]; then
      log "Kindle RNDIS service is disabled; enabling for dashboard push."
      networksetup -setnetworkserviceenabled "$RNDIS_SERVICE" on || return 1
      networksetup -setmanual "$RNDIS_SERVICE" "$KINDLE_MAC_IP" 255.255.255.0 0.0.0.0 >/dev/null 2>&1 || true
      networksetup -setadditionalroutes "$RNDIS_SERVICE" "$KINDLE_HOST" 255.255.255.255 "" >/dev/null 2>&1 || true
      networksetup -setv6off "$RNDIS_SERVICE" >/dev/null 2>&1 || true
      sleep 1
    else
      log "Kindle RNDIS service is disabled; skipping push."
      return 1
    fi
  fi

  iface="$(active_rndis_iface || true)"
  if [[ -z "$iface" ]]; then
    log "Kindle usbnet interface has no $KINDLE_MAC_IP address; skipping push."
    return 1
  fi

  route_iface="$(route_iface_for "$KINDLE_HOST")"
  if [[ "$route_iface" != "$iface" ]]; then
    if [[ "$AUTO_FIX_USB_ROUTE" == "1" ]]; then
      log "Kindle route uses '${route_iface:-none}', expected '$iface'; refreshing host route."
      remove_kindle_default_route
      route -n delete -host "$KINDLE_HOST" >/dev/null 2>&1 || true
      if ! route -n add -host "$KINDLE_HOST" -interface "$iface" >/dev/null 2>&1; then
        warn "Could not add host route without sudo. Run once manually if needed:"
        warn "  sudo route -n add -host $KINDLE_HOST -interface $iface"
        return 1
      fi
      route_iface="$(route_iface_for "$KINDLE_HOST")"
    fi
  else
    # Even when the host route is correct, macOS may keep a lower-priority
    # default route via the Kindle because the service has Router configured.
    # Remove it opportunistically; if this non-root launchd run cannot remove it,
    # Wi-Fi remains first due service order and we warn below.
    remove_kindle_default_route
  fi

  if [[ "$route_iface" != "$iface" ]]; then
    log "Kindle route still not on USB interface ($route_iface != $iface); skipping push to avoid Wi-Fi/VPN misroute."
    return 1
  fi

  if has_default_via_kindle; then
    log "Warning: macOS has an extra default route via Kindle ($KINDLE_HOST). Wi-Fi still wins if service order is correct, but this is why the setup feels fragile."
  fi

  return 0
}

cleanup_after_push() {
  if [[ "$DISABLE_RNDIS_AFTER_PUSH" == "1" ]] && service_exists; then
    log "Disabling RNDIS after push because DISABLE_RNDIS_AFTER_PUSH=1."
    networksetup -setnetworkserviceenabled "$RNDIS_SERVICE" off || true
  fi
}
trap cleanup_after_push EXIT

if [[ ! -f "$PNG" ]]; then
  warn "PNG missing: $PNG"
  exit 1
fi

if ! ensure_usbnet_route; then
  # Not an error for launchd/dashboard rendering: Kindle may simply be unplugged.
  exit 0
fi

# Only ping after we know the route points at the USB interface. This avoids leaking
# Kindle pings to Wi-Fi/VPN/default gateway when RNDIS is down.
if ! ping -c 1 -W 1000 "$KINDLE_HOST" >/dev/null 2>&1; then
  log "Kindle usbnet route is present but host did not answer ping at $KINDLE_HOST; skipping push."
  exit 0
fi

if ! ssh "${SSH_OPTS[@]}" "$KINDLE_USER@$KINDLE_HOST" 'true' >/dev/null 2>&1; then
  warn "Kindle SSH not ready or key/passwordless auth not configured for $KINDLE_USER@$KINDLE_HOST."
  warn "Manual first login may be needed: ssh $KINDLE_USER@$KINDLE_HOST"
  exit 1
fi

scp "${SSH_OPTS[@]}" "$PNG" "$KINDLE_USER@$KINDLE_HOST:$REMOTE_PNG" >/dev/null
ssh "${SSH_OPTS[@]}" "$KINDLE_USER@$KINDLE_HOST" "$REMOTE_PATH; eips -c && eips -f -g '$REMOTE_PNG'"
log "Pushed $PNG to Kindle display at $KINDLE_HOST"
