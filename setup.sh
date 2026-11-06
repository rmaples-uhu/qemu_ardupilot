#!/usr/bin/env bash
set -euo pipefail
umask 077

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state="$root/.vm"
image_name=jammy-server-cloudimg-amd64.img
image_url=https://cloud-images.ubuntu.com/jammy/current

if [[ $# -gt 1 || ${1:-} == --help ]]; then
    echo "Usage: $0 [trusted-ubuntu-22.04-amd64-cloud-image.qcow2]"
    exit "$(( $# > 1 ))"
fi
for tool in qemu-img cloud-localds; do
    command -v "$tool" >/dev/null || { echo "Missing command: $tool" >&2; exit 1; }
done
if [[ -e "$state/root.qcow2" ]]; then
    echo "VM already exists in $state; refusing to overwrite it." >&2
    exit 1
fi
mkdir -p "$state"
work=$(mktemp -d "$state/setup.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

if [[ $# == 1 ]]; then
    cp --reflink=auto -- "$1" "$work/$image_name"
else
    curl --fail --location --retry 3 "$image_url/$image_name" -o "$work/$image_name"
    curl --fail --location --retry 3 "$image_url/SHA256SUMS" -o "$work/SHA256SUMS"
    (cd "$work" && sha256sum --check --ignore-missing SHA256SUMS)
fi
qemu-img check -f qcow2 "$work/$image_name"
mv -- "$work/$image_name" "$state/base.qcow2"
qemu-img create -f qcow2 -F qcow2 -b "$state/base.qcow2" "$work/root.qcow2" 20G
printf 'instance-id: qemu-ardupilot\nlocal-hostname: qemu-ardupilot\n' > "$work/meta-data"
cloud-localds "$work/seed.img" "$root/cloud-init.yaml" "$work/meta-data"
mv -- "$work/seed.img" "$state/seed.img"
mv -- "$work/root.qcow2" "$state/root.qcow2"
echo "VM prepared. Run $root/run.sh to boot and build ArduPilot."
