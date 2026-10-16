#!/usr/bin/env bash
# allow-win-kali.sh - temporarily let the Windows container reach libvirt VMs
# (e.g. Kali on virbr0). Run it whenever you need sandbox -> Kali connectivity.
#
#   ./allow-win-kali.sh        discover interfaces, insert accept rule (no-op if present)
#   ./allow-win-kali.sh down   remove the rule again
#
# Why this exists: libvirt programs nftables directly and its forward chain
# runs before the iptables/Docker FORWARD chain, so its REJECT kills
# container->VM traffic first ("destination port unreachable"). A plain
# iptables ACCEPT can never win - the accept must live inside libvirt's own
# chain. Nothing here is persisted: the rule evaporates on reboot or when
# the libvirt network restarts, just re-run this script.
#
# Env knobs: CONTAINER_NAME (default: windows-sandbox)

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-windows-sandbox}"
NFT_TABLE="ip libvirt_network"
NFT_CHAIN="guest_input"

log()  { echo -e "\033[1;36m[win-kali]\033[0m $*"; }
warn() { echo -e "\033[1;33m[win-kali]\033[0m $*" >&2; }
die()  { warn "$*"; exit 1; }

command -v ip >/dev/null || die "ip not found in PATH"

check_tools() {
  command -v docker >/dev/null || die "docker not found in PATH"
  command -v nft >/dev/null || die "nft not found in PATH"
}

# Host interface of the docker network the container is attached to.
docker_if() {
  local net name drv nid
  net="$(docker inspect "$CONTAINER_NAME" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | awk '{print $1}' || true)"
  [[ -n $net ]] || die "container '$CONTAINER_NAME' not found - set CONTAINER_NAME or create it first"
  log "container '$CONTAINER_NAME' is on docker network '$net'" >&2
  if [[ $net == "bridge" ]]; then
    name="$(docker network inspect bridge --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || true)"
    [[ -n $name && $name != "<no value>" ]] || name="docker0"
    echo "$name"
  else
    drv="$(docker network inspect "$net" --format '{{.Driver}}' 2>/dev/null || true)"
    [[ $drv == "bridge" ]] || die "network '$net' uses driver '$drv' - only bridge networks supported"
    nid="$(docker network inspect "$net" --format '{{.Id}}' 2>/dev/null || true)"
    [[ -n $nid ]] || die "could not read id of network '$net'"
    echo "br-${nid:0:12}"
  fi
}

# Libvirt bridge interface (usually virbr0).
libvirt_if() {
  local ifc
  ifc="$(ip -o -4 addr show | awk '$4 ~ /^192\.168\.122\.1\// {print $2; exit}' || true)"
  [[ -n $ifc ]] || die "no libvirt bridge found (expected virbr0 holding 192.168.122.1)"
  echo "$ifc"
}

# True when libvirt drives nftables directly (its managed table exists).
nft_backend() { sudo nft list chain $NFT_TABLE $NFT_CHAIN >/dev/null 2>&1; }

nft_rule_present() { # $1=src_if $2=dst_if
  sudo nft list chain $NFT_TABLE $NFT_CHAIN 2>/dev/null | grep -q "iifname \"$1\" oifname \"$2\" accept"
}

cmd_up() {
  check_tools
  local src dst
  src="$(docker_if)"
  dst="$(libvirt_if)"
  ip -o link show "$src" >/dev/null 2>&1 || die "interface $src not present on host"
  log "source interface : $src (docker)"
  log "dest interface   : $dst (libvirt)"

  if nft_backend; then
    log "libvirt nftables backend detected (table $NFT_TABLE)"
    if nft_rule_present "$src" "$dst"; then
      log "accept rule already present - nothing to do"
    else
      sudo nft insert rule $NFT_TABLE $NFT_CHAIN iifname "$src" oifname "$dst" accept
      log "inserted accept rule at top of $NFT_CHAIN"
    fi
  else
    log "no libvirt nftables chain - falling back to iptables"
    if sudo iptables -C FORWARD -i "$src" -o "$dst" -j ACCEPT 2>/dev/null; then
      log "iptables rule already present - nothing to do"
    else
      sudo iptables -I FORWARD -i "$src" -o "$dst" -j ACCEPT
      log "inserted iptables FORWARD rule"
    fi
  fi

  echo
  log "Windows guest can now reach VMs on $dst"
  log "from Windows, try:  ping 192.168.122.51"
  if command -v virsh >/dev/null 2>&1; then
    log "libvirt DHCP leases (your Kali IP):"
    timeout 5 virsh --connect qemu:///system net-dhcp-leases default 2>/dev/null | sed 's/^/  /' || warn "could not read DHCP leases"
  fi
}

cmd_down() {
  check_tools
  local src dst h found=0
  src="$(docker_if)"
  dst="$(libvirt_if)"
  log "source interface : $src (docker)"
  log "dest interface   : $dst (libvirt)"

  if nft_backend; then
    while IFS= read -r h; do
      [[ -n $h ]] || continue
      sudo nft delete rule $NFT_TABLE $NFT_CHAIN handle "$h"
      log "removed nftables rule (handle $h)"
      found=1
    done < <(sudo nft --handle list chain $NFT_TABLE $NFT_CHAIN 2>/dev/null \
        | grep "iifname \"$src\" oifname \"$dst\" accept" \
        | sed -n 's/.*handle \([0-9][0-9]*\).*/\1/p' || true)
  else
    if sudo iptables -C FORWARD -i "$src" -o "$dst" -j ACCEPT 2>/dev/null; then
      sudo iptables -D FORWARD -i "$src" -o "$dst" -j ACCEPT
      log "removed iptables FORWARD rule"
      found=1
    fi
  fi
  [[ $found == 1 ]] || log "no matching rule found - nothing to do"
}

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-up}" in
  up)   cmd_up ;;
  down) cmd_down ;;
  *)    usage ;;
esac
