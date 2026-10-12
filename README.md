# windows_sandbox

A disposable Windows 11 test box for building and testing - no `docker-compose`, just Windows with Defender turned all the way up and RDP access for you to poke at.

Runs a real Windows 11 install inside a container via [dockur/windows](https://github.com/dockur/windows) (QEMU/KVM under the hood), reachable through a web viewer or RDP.

## What this is / isn't

- ✅ A fast, resettable Windows 11 sandbox with Defender's built-in protections maxed out via policy - useful for testing how far "default Windows hardening" actually gets you, or for building/testing boxes before you point real tooling at them.
- ❌ Not an EDR testbed. No CrowdStrike/SentinelOne/etc. - just Microsoft Defender.
- ❌ Not internet-facing-safe by default. See [Security notes](#security-notes) before exposing this anywhere.

## Requirements

- Docker (or Podman) on a **Linux host with KVM** (`/dev/kvm` must exist), or Docker Desktop on Windows 11 with nested virtualization enabled.
- Docker Desktop on macOS/Windows 10 does **not** expose KVM to containers - this won't run there.
- ~80 GB free disk for the Windows install, 8 GB+ RAM recommended.

Check KVM support:
```bash
sudo apt install cpu-checker  # if needed
kvm-ok
```

## Quick start

```bash
git clone <this-repo>
cd htb-box
./manage.sh build
./manage.sh up       # first boot installs Windows 11 - takes ~20-30 minutes
./manage.sh status   # shows the web viewer URL and RDP info
```

Then either:
- Open `http://localhost:8006` in a browser to watch the install / use the desktop directly, or
- RDP to `localhost:3389` once setup finishes.

**Credentials:** `Administrator` / `lab` (see [Security notes](#security-notes)).

## What gets provisioned automatically

`oem/install.bat` runs as the last step of unattended Windows setup and kicks off `oem/harden-defender.ps1`, which:

- Enables real-time, behavior, script, archive, removable-drive, and email scanning
- Sets cloud-delivered protection to **High** with full sample submission
- Enables PUA protection, Controlled Folder Access, and Network Protection
- Enables the full 15-rule Attack Surface Reduction set, all in **Block** mode
- Forces a signature update
- Enables Windows Firewall on all profiles
- Enables RDP and opens the firewall rule for it

**Not scriptable:** Tamper Protection. Microsoft deliberately blocks programmatic changes to it - if you want it on, flip it manually once in *Windows Security → Virus & threat protection settings* after first boot.

## Commands

| Command | What it does |
|---|---|
| `./manage.sh build` | Build the image |
| `./manage.sh up` | Start the box (fresh Windows install on first run) |
| `./manage.sh stop` | Stop the box, disk state kept |
| `./manage.sh status` | Show container state + connection info |
| `./manage.sh logs` | Follow install/boot logs |
| `./manage.sh snapshot` | Save current disk state for fast resets |
| `./manage.sh reset` | Wipe current disk, restore last snapshot (or reinstall if none exists) |
| `./manage.sh rebuild` | Pull the latest base image + force a fresh Windows 11 install |
| `./manage.sh purge` | Stop + remove container, image, and **all** disk state (asks for confirmation) |

### Typical loop

```bash
./manage.sh up                       # fresh install, first time only
# ...confirm Defender settings applied, desktop is how you want it...
./manage.sh snapshot                 # bank that state
# ...do your testing, break things...
./manage.sh reset                    # snap back in seconds instead of reinstalling
```

### Staying current

```bash
./manage.sh rebuild                  # pulls latest dockur/windows base + wipes disk state
./manage.sh up                       # fresh install of whatever Windows 11 build is current
```

## Project layout

```
.
├── Dockerfile                   # builds on dockurr/windows, bakes in the OEM payload
├── manage.sh                    # build / up / reset / rebuild / purge
└── oem/
    ├── install.bat               # entrypoint, runs at the end of unattended setup
    └── harden-defender.ps1       # Defender/Firewall/RDP configuration
```

## Security notes

- `Administrator:lab` is intentionally simple for fast local lab access - it is **not** safe to expose beyond an isolated host or network. Change it before bridging this container's network, port-forwarding it, or running it on a shared/cloud host.
- This box has no outbound restrictions by default. If you're testing something that shouldn't phone home, isolate the container's network accordingly (e.g. an internal-only Docker network or host firewall rules).
- Snapshots (`storage.snapshot/`) are plain file copies of the VM disk - anything sensitive you put on the box during testing lives there until you `purge`.

## Customizing

Resource allocation and install params are set as `ENV` values in the `Dockerfile` (`RAM_SIZE`, `CPU_CORES`, `DISK_SIZE`, `USERNAME`, `PASSWORD`, `LANGUAGE`) - override at `docker run` time with `-e` if you'd rather not rebuild, or edit the Dockerfile directly. Drop additional setup into `oem/` and call it from `install.bat` to extend provisioning.
