#!/bin/bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

cc_bin=${CC:-cc}

"$cc_bin" -static -Os -o "$repo_root/guest_init" "$repo_root/guest_init.c"
"$cc_bin" -static -Os -o "$tmpdir/rootfs-init" "$repo_root/assets/guest/rootfs_init.c"

mkdir -p "$tmpdir/dev"
mkdir -p "$tmpdir/mnt/container/bin" \
	"$tmpdir/mnt/container/dev" \
	"$tmpdir/mnt/container/etc" \
	"$tmpdir/mnt/container/proc" \
	"$tmpdir/mnt/container/root" \
	"$tmpdir/mnt/container/sbin" \
	"$tmpdir/mnt/container/sys" \
	"$tmpdir/mnt/container/tmp" \
	"$tmpdir/mnt/container/usr/bin" \
	"$tmpdir/mnt/container/var/log"
cp "$repo_root/guest_init" "$tmpdir/init"
cp "$tmpdir/rootfs-init" "$tmpdir/mnt/container/init"

ln -sf /init "$tmpdir/mnt/container/sbin/init"
ln -sf /init "$tmpdir/mnt/container/bin/sh"
ln -sf /init "$tmpdir/mnt/container/usr/bin/env"

cat > "$tmpdir/mnt/container/etc/os-release" <<'EOF'
NAME="Catenary Guest Rootfs"
ID=catenary-demo
PRETTY_NAME="Catenary Embedded Guest Rootfs"
VERSION_ID="0.1"
HOME_URL="https://github.com/"
EOF

fakeroot sh -c '
set -e
mknod -m 600 "$1/dev/console" c 5 1
mknod -m 666 "$1/dev/null" c 1 3
cd "$1"
find . | cpio -o -H newc --quiet | gzip -9 > "$2"
' sh "$tmpdir" "$repo_root/assets/guest/initramfs.cpio.gz"

echo "rebuilt $repo_root/assets/guest/initramfs.cpio.gz"