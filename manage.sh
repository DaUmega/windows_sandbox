#!/usr/bin/env bash
# manage.sh - dockur/windows lifecycle (no compose)
#
#   build       build the image
#   up          create on first run, else start (first boot installs Windows)
#   stop        stop, keep disk
#   status      state + connection info
#   logs        follow boot/install logs
#   snapshot    save disk *.img for a fast reset
#   reset       restore snapshot; without one, wipe the disk image only
#   rebuild     refresh base image + fresh Windows install (ISO cache kept)
#   purge       nuke everything (asks first)
#
# Env knobs: IMAGE_NAME CONTAINER_NAME WIN_VERSION WIN_USER WIN_PASS
#            TESTER_USER TESTER_PASS WIN_RAM WIN_CPU WIN_DISK
#            INBOUND_PORTS="445 135 139" PUBLISH_ON=<ip>
#            WIN_NET=<docker network> WIN_DHCP=Y  ALLOW_NO_KVM=1
#
# Lab net: Windows -> Kali needs no config (outbound NAT).
#   Kali -> Windows: set INBOUND_PORTS; published on virbr0 (auto-detected).

set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-windows-sandbox}"
CONTAINER_NAME="${CONTAINER_NAME:-windows-sandbox}"
WIN_VERSION="${WIN_VERSION:-}"
WIN_USER="${WIN_USER:-lab}";          WIN_PASS="${WIN_PASS:-lab}"
TESTER_USER="${TESTER_USER:-tester}"; TESTER_PASS="${TESTER_PASS:-pass}"
WIN_RAM="${WIN_RAM:-8G}"; WIN_CPU="${WIN_CPU:-4}"; WIN_DISK="${WIN_DISK:-80G}"
INBOUND_PORTS="${INBOUND_PORTS:-}"; PUBLISH_ON="${PUBLISH_ON:-}"
WIN_NET="${WIN_NET:-}";             WIN_DHCP="${WIN_DHCP:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORAGE_DIR="$SCRIPT_DIR/storage"
SNAP_DIR="$SCRIPT_DIR/storage.snapshot"
OEM_DIR="$SCRIPT_DIR/oem"
SHARED_DIR="$SCRIPT_DIR/shared"

log()  { echo -e "\033[1;36m[manage]\033[0m $*"; }
warn() { echo -e "\033[1;33m[manage]\033[0m $*" >&2; }
die()  { warn "$*"; exit 1; }

require_kvm() {
  [[ -e /dev/kvm || "${ALLOW_NO_KVM:-0}" == "1" ]] \
    || die "/dev/kvm missing - enable virtualization in BIOS, or ALLOW_NO_KVM=1 (very slow)"
}

virbr_ip()       { ip -4 -o addr show virbr0 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'; }
have_container() { docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; }
collect_imgs()   { shopt -s nullglob; IMGS=("$1"/*.img); shopt -u nullglob; }  # -> $IMGS

# dockur parks the ISO in storage/tmp/ during install and wipes tmp/ on the
# next boot. If a run was interrupted mid-install, rescue the stranded
# complete ISO (a partial download carries a .aria2 sibling - leave those)
# back to storage/ so the next boot reuses it instead of re-downloading.
# Only when the container is stopped: never yank it from a live install.
rescue_iso() {
  docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" && return 0
  shopt -s nullglob
  local iso
  for iso in "$STORAGE_DIR"/tmp/*.iso; do
    if [[ ! -f "$iso.aria2" ]]; then
      mv -f "$iso" "$STORAGE_DIR/"
      log "Rescued stranded ISO $(basename "$iso") from tmp/ - no re-download."
    fi
  done
  shopt -u nullglob
}

# Prefer buildx (BuildKit); fall back to the legacy builder when missing.
docker_build() {
  local bld=(docker build)
  docker buildx version >/dev/null 2>&1 && bld=(docker buildx build)
  "${bld[@]}" "$@"
}

cmd_build() {
  require_kvm
  docker_build -t "$IMAGE_NAME:latest" "$SCRIPT_DIR"
  log "Built $IMAGE_NAME:latest"
}

cmd_up() {
  require_kvm
  mkdir -p "$STORAGE_DIR" "$OEM_DIR" "$SHARED_DIR"
  rescue_iso
  {
    echo '@echo off'
    echo "net user Administrator $WIN_PASS /active:yes"
    echo "net user $TESTER_USER $TESTER_PASS /add"
    echo "net localgroup \"Remote Desktop Users\" $TESTER_USER /add"
    echo "wmic useraccount where \"name='$TESTER_USER'\" set PasswordExpires=false"
    echo 'netsh advfirewall firewall add rule name="Lab ICMPv4-In" protocol=icmpv4:8,any dir=in action=allow'
    echo 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\OEM\harden-defender.ps1'
  } | sed 's/$/\r/' > "$OEM_DIR/install.bat"
  cp -n "$SCRIPT_DIR/harden-defender.ps1" "$OEM_DIR/" 2>/dev/null || true

  if have_container; then
    log "Container exists - starting it."
    log "Run flags apply at creation only: 'docker rm $CONTAINER_NAME' (disk kept), then up."
    docker start "$CONTAINER_NAME" >/dev/null
  else
    local pre=() pub=(-p 127.0.0.1:8006:8006 -p 127.0.0.1:3389:3389/tcp -p 127.0.0.1:3389:3389/udp)
    if [[ -n $WIN_NET ]]; then
      pre=(--network "$WIN_NET")
      if [[ $(docker network inspect "$WIN_NET" --format '{{.Driver}}' 2>/dev/null) =~ macvlan|ipvlan ]]; then
        log "$WIN_NET is macvlan/ipvlan: no port publishes; reach the box at its network IP."
        pub=()
      fi
      if [[ $WIN_DHCP == Y ]]; then
        pre+=(--device=/dev/vhost-net --device-cgroup-rule "c *:* rwm" -e DHCP=Y)
        [[ -e /dev/vhost-net ]] || warn "/dev/vhost-net missing - DHCP may fail."
      fi
    else
      local virbr on p
      virbr="$(virbr_ip)"
      on="${PUBLISH_ON:-$virbr}"; on="${on:-127.0.0.1}"
      for p in $INBOUND_PORTS; do  # intentional word splitting
        [[ $p =~ ^[0-9]+$ ]] && pub+=(-p "$on:$p:$p") || warn "Ignoring bad port '$p' in INBOUND_PORTS."
      done
      [[ -n $virbr && -n $INBOUND_PORTS ]] && log "Publishing [$INBOUND_PORTS] on $on for Kali."
    fi

    log "Creating + starting $CONTAINER_NAME (first boot installs Windows, ~20-40 min)."
    docker run -d --name "$CONTAINER_NAME" --restart unless-stopped --stop-timeout 120 \
      --device=/dev/kvm --device=/dev/net/tun --cap-add NET_ADMIN \
      "${pre[@]}" \
      ${WIN_VERSION:+-e VERSION="$WIN_VERSION"} \
      -e USERNAME="$WIN_USER" -e PASSWORD="$WIN_PASS" \
      -e RAM_SIZE="$WIN_RAM" -e CPU_CORES="$WIN_CPU" -e DISK_SIZE="$WIN_DISK" \
      "${pub[@]}" \
      -v "$STORAGE_DIR:/storage" -v "$OEM_DIR:/oem" -v "$SHARED_DIR:/shared" \
      "$IMAGE_NAME:latest" >/dev/null
  fi
  cmd_status
}

cmd_stop() {
  log "Stopping $CONTAINER_NAME (disk kept)."
  docker stop "$CONTAINER_NAME" 2>/dev/null || warn "Not running."
}

cmd_status() {
  echo
  docker ps -a --filter "name=$CONTAINER_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  echo
  log "Web: http://127.0.0.1:8006   RDP: 127.0.0.1:3389"
  log "  admin:    $WIN_USER / $WIN_PASS  (or Administrator / $WIN_PASS)"
  log "  low-priv: $TESTER_USER / $TESTER_PASS"
  log "Shared: $SHARED_DIR -> Z: drive in Windows"
  local iso
  for iso in "$STORAGE_DIR"/*.iso; do [[ -f "$iso" ]] && log "ISO cache: $(basename "$iso")"; done
  local virbr; virbr="$(virbr_ip)"
  if [[ -n $virbr ]]; then
    echo
    log "Kali (virbr0=$virbr): Windows->Kali needs no config (Kali's 192.168.122.x IP)."
    if [[ -n $INBOUND_PORTS ]]; then
      log "Kali->Windows inbound: ${PUBLISH_ON:-$virbr} ports [$INBOUND_PORTS]"
    else
      log "Kali->Windows inbound: off (set INBOUND_PORTS)"
    fi
  fi
  echo
}

cmd_logs() { docker logs -f --tail 50 "$CONTAINER_NAME"; }

cmd_snapshot() {
  collect_imgs "$STORAGE_DIR"
  ((${#IMGS[@]})) || die "No disk image in $STORAGE_DIR yet."
  local running=false img
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    running=true
    log "Stopping for a consistent snapshot."
    docker stop "$CONTAINER_NAME" >/dev/null
  fi
  mkdir -p "$SNAP_DIR"
  for img in "${IMGS[@]}"; do cp --sparse=always "$img" "$SNAP_DIR/$(basename "$img")"; done
  log "Snapshot saved."
  rescue_iso
  if $running; then docker start "$CONTAINER_NAME" >/dev/null; log "Restarted."; fi
}

# Only the disk image is wiped - the cached ISO stays, so no re-download.
cmd_reset() {
  log "Resetting $CONTAINER_NAME."
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  collect_imgs "$SNAP_DIR"
  if ((${#IMGS[@]})); then
    local s
    for s in "${IMGS[@]}"; do cp --sparse=always "$s" "$STORAGE_DIR/$(basename "$s")"; done
    log "Snapshot restored."
  else
    warn "No snapshot - wiping disk image (ISO cache kept)."
    rm -f "$STORAGE_DIR"/*.img
  fi
  rescue_iso
  if have_container; then docker start "$CONTAINER_NAME" >/dev/null; log "Box reset and starting."
  else log "Box reset. Run './manage.sh up'."; fi
}

cmd_rebuild() {
  log "Pulling latest dockurr/windows base."
  docker pull dockurr/windows:latest
  log "Rebuilding $IMAGE_NAME:latest."
  docker_build --no-cache --pull -t "$IMAGE_NAME:latest" "$SCRIPT_DIR"
  log "Dropping old container + disk image (ISO cache kept)."
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
  rm -rf "$SNAP_DIR"
  rm -f "$STORAGE_DIR"/*.img
  log "Done. './manage.sh up' reinstalls Windows from the cached ISO."
}

cmd_purge() {
  read -r -p "Nuke container, image, ALL disk state? Type 'purge': " c
  [[ $c == purge ]] || { log "Aborted."; exit 0; }
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
  docker rmi "$IMAGE_NAME:latest" 2>/dev/null || true
  rm -rf "$STORAGE_DIR" "$SNAP_DIR"
  log "Purged. Dockerfile/oem sources kept."
}

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

main() {
  case "${1:-}" in
    build)    cmd_build ;;
    up|start) cmd_up ;;
    stop)     cmd_stop ;;
    status)   cmd_status ;;
    logs)     cmd_logs ;;
    snapshot) cmd_snapshot ;;
    reset)    cmd_reset ;;
    rebuild)  cmd_rebuild ;;
    purge|destroy|clean) cmd_purge ;;
    *) usage ;;
  esac
}

main "$@"
