# syntax=docker/dockerfile:1
#
# Minimalist Windows 11 test box - Defender maxed via oem provisioning.
# RDP as lab:lab (admin) or Administrator:lab. No EDR.
#
# Base: dockurr/windows -> real Windows 11 under QEMU/KVM in the container,
# web viewer (8006) + RDP (3389). Requires a Linux host with KVM.
#
# NOTE: USERNAME="Administrator" is rejected by the answer file (reserved
# for the built-in account). We create "lab" via setup and enable the real
# built-in Administrator in oem/install.bat instead.

FROM dockurr/windows:latest

# Install parameters. manage.sh passes these with -e at `docker run`;
# the values here are fallback defaults. VERSION unset -> latest Win 11 Pro.
ENV RAM_SIZE="8G" \
    CPU_CORES="4" \
    DISK_SIZE="80G" \
    USERNAME="lab" \
    PASSWORD="lab"

# 8006 = web viewer, 3389 = RDP
EXPOSE 8006 3389/tcp 3389/udp
