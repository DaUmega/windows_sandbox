# windows-sandbox — hardened Windows 11 test box

Disposable Windows 11 VM for testing (including the ANGLE/Edge PoC): Docker only,
no compose. Real Windows 11 under QEMU/KVM via [dockurr/windows](https://github.com/dockur/windows),
Defender maxed out via provisioning, RDP access.

## Requirements

- Docker on a **Linux host with KVM** (`/dev/kvm` must exist). Docker Desktop on
  macOS / Windows 10 does not expose KVM — won't run there.
- ~80 GB free disk, 8 GB+ RAM.

## Quickstart

```bash
./manage.sh build
./manage.sh up        # first boot installs Windows 11 — ~20-40 min, watch with ./manage.sh logs
./manage.sh snapshot  # bank the clean, hardened state once the desktop is up
```

RDP to `127.0.0.1:3389` as `lab:lab` (admin) or `Administrator:lab`
(`tester:pass` is a low-priv RDP user for privesc-style testing).
Web viewer: `http://127.0.0.1:8006` (handy during install).

```bash
./manage.sh reset     # restore snapshot in seconds
./manage.sh rebuild   # pull latest base image + fresh install of current Win 11 build
./manage.sh purge      # nuke everything (asks for confirmation)
```

Drop payloads/files into `./shared/` on the host — it shows up as the `Z:` drive
and a `Shared` folder on the Windows desktop.

## Lab networking: Kali (virt-manager) <-> Windows (docker)

The two directions work differently:

- **Windows -> Kali (reverse shells): no config needed.** Outbound traffic leaves
  through the container's NAT, so a payload on Windows can always call back to a
  listener on your Kali VM. Point `LHOST` at Kali's `192.168.122.x` address.
- **Kali -> Windows (bind shells, direct exploitation): publish the ports.**
  The script auto-detects libvirt's `virbr0` address and publishes there:

  ```bash
  INBOUND_PORTS="445 135 139" ./manage.sh up
  ```

  Kali then reaches Windows at `192.168.122.1:445` (your virbr0 IP may differ —
  `./manage.sh status` prints it). `PUBLISH_ON` overrides the bind address;
  empty `INBOUND_PORTS` (the default) keeps everything localhost-only.

No virbr0 on the machine? The script falls back to `127.0.0.1` — behavior is
identical to before. No extra programs, no per-network config, so the repo works
the same in any environment and lights up the Kali path automatically wherever
libvirt exists.

> Note: `docker run` flags (ports, networks, volumes) only apply when the
> container is **created**. To pick up changes: `docker rm windows-sandbox`
> (the Windows disk in `./storage/` is kept), then `./manage.sh up`.

### virt-manager Kali (CachyOS)

```bash
sudo pacman -S virt-manager qemu-desktop libvirt dnsmasq dmidecode
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $USER   # log out/in
```

New VM from the Kali ISO, default NAT network. Typical flow: generate the payload
on Kali (`msfvenom ... LHOST=<kali 192.168.122.x>`), drop it in `./shared/` (or
fetch it over RDP), start the handler on Kali, execute on Windows.

### Optional: LAN-flat mode (no port bookkeeping)

Needs a wired NIC and your LAN details — opt in only, not portable:

```bash
docker network create -d macvlan --subnet=192.168.1.0/24 --gateway=192.168.1.1 -o parent=eth0 winlan
WIN_NET=winlan WIN_DHCP=Y ./manage.sh up
```

Windows then gets its own IP from your router (check DHCP leases or `ipconfig`
in the guest) — RDP to that IP. Caveats: the container's own macvlan IP isn't
reachable from the host (kernel limitation), and port publishes are skipped on
macvlan networks. Keep Kali bridged too if you want direct Kali->Windows here.

## What's hardened

`oem/install.bat` runs as SYSTEM at the end of unattended setup and applies
`oem/harden-defender.ps1`:

- Defender real-time / behavior / script / archive / removable / email scanning on
- Cloud-delivered protection **High**, full sample submission, PUA protection
- Controlled Folder Access + Network Protection on
- All 15 Attack Surface Reduction rules in **Block** mode
- Signature update, firewall on for all profiles, RDP enabled
- Inbound ICMPv4 echo allowed (lab diagnostics only — firewall itself stays on)

Check `C:\OEM\install.log` and `C:\OEM\PROVISIONED.txt` on the box to confirm
provisioning ran. **Tamper Protection can't be scripted** (Microsoft blocks it) —
flip it manually once in Windows Security if you want it on.

## Notes

- `oem/` is **bind-mounted** to `/oem` (per upstream docs), so editing the
  hardening script needs no image rebuild — just `reset` to re-provision.
  (The generated `install.bat` itself is rewritten on every `up`.)
- `USERNAME=Administrator` is rejected by the answer file (reserved name), so
  setup creates `lab:lab` and `install.bat` enables the real built-in
  Administrator with password `lab`.
- Ports bind to 127.0.0.1 only. Remote host? `ssh -L 3389:127.0.0.1:3389 -L 8006:127.0.0.1:8006 user@host`.
- Knobs without rebuilding: `WIN_RAM=16G WIN_CPU=8 ./manage.sh up`
  (`WIN_VERSION`, `WIN_USER`, `WIN_PASS`, `WIN_DISK`, `INBOUND_PORTS`,
  `PUBLISH_ON`, `WIN_NET`, `WIN_DHCP` also supported).
- Credentials are lab-simple by design — never expose this box beyond localhost
  (or your trusted LAN in `WIN_NET` mode).
