#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state="$root/.vm"

usage() {
    echo "Usage: $0 [--tcp PORT | --serial /dev/ttyUSB0]"
    echo "Default: --tcp 10110 (localhost only); serial input is 9600 baud, 8N1."
}
if [[ ${1:-} == --help && $# == 1 ]]; then
    usage
    exit 0
fi
if [[ $# == 0 ]]; then
    set -- --tcp 10110
fi
if [[ $# != 2 ]]; then
    usage >&2
    exit 1
fi
case "$1" in
    --tcp)
        if [[ ! $2 =~ ^[0-9]{1,5}$ ]] || (( 10#$2 < 1024 || 10#$2 > 65535 || 10#$2 == 5760 )); then
            echo "NMEA TCP port must be 1024-65535 and different from MAVLink port 5760." >&2
            exit 1
        fi
        backend="socket,id=nmea,host=127.0.0.1,port=$((10#$2)),server=on,wait=off"
        ;;
    --serial)
        if [[ $2 != /dev/* || $2 == *,* || ! -c $2 || ! -r $2 || ! -w $2 ]]; then
            echo "Serial input must be a readable/writable character device under /dev (no commas)." >&2
            exit 1
        fi
        backend="serial,id=nmea,path=$2"
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
command -v qemu-system-x86_64 >/dev/null || { echo "Missing command: qemu-system-x86_64" >&2; exit 1; }
if [[ ! -f "$state/root.qcow2" || ! -f "$state/seed.img" ]]; then
    echo "Run $root/setup.sh first." >&2
    exit 1
fi
acceleration=(-accel tcg -cpu max)
if [[ $(uname -m) == x86_64 && -r /dev/kvm && -w /dev/kvm ]]; then
    acceleration=(-accel kvm -cpu host)
fi
exec qemu-system-x86_64 \
    "${acceleration[@]}" -m 4096 -smp 2 \
    -display none -serial mon:stdio \
    -drive "file=$state/root.qcow2,format=qcow2,if=virtio" \
    -drive "file=$state/seed.img,format=raw,if=virtio,readonly=on" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5760-:5760 \
    -device virtio-net-pci,netdev=net0 \
    -chardev "$backend" -device isa-serial,chardev=nmea,index=1
