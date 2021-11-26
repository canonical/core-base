#!/bin/bash

# Author: Maciej Borzecki
# Modified by Ian Johnson <ian.johnson@canonical.com>

set -e

if [[ -n "$D" ]]; then
    set -x
fi

##HELP: Usage: repack-kernel <command> <opts>
##HELP:
##HELP: Handle extraction of the kernel snap to a workspace directory, and later
##HELP: repacking it back to a snap.
##HELP:
##HELP: Commands:
##HELP:    setup                          - setup system dependencies
##HELP:    extract <snap-file> <target>   - extract under <target> workspace tree
##HELP:    prepare <target>               - prepare initramfs & kernel for repacking
##HELP:    pack <target>                  - pack the kernel
##HELP:    cull-firmware <target>         - remove unnecessary firmware
##HELP:    cull-modules                   - remove unnecessary mofules
##HELP:

setup_deps() {
    if [[ "$UID" != "0" ]]; then
        echo "run as root (only this command)"
        exit 1
    fi

    # carries ubuntu-core-initframfs
    add-apt-repository ppa:snappy-dev/image -y
    apt install ubuntu-core-initramfs -y
}

get_kver() {
    kerneldir="$1"
    (
        cd "$kerneldir"
        #shellcheck disable=SC2010
        ls "config"-* | grep -Po 'config-\K.*'
    )
}

extract_kernel() {
    local snap_file="$1"
    local target="$2"

    if [[ -z "$target" ]] || [[ -z "$snap_file" ]]; then
        echo "usage: prepare <target-dir> <kernel-snap>"
        exit 1
    fi

    target=$(realpath "$target")

    mkdir -p "$target" "$target/work" "$target/backup"

    # kernel snap is huge, unpacking to current dir
    unsquashfs -d "$target/kernel" "$snap_file"

    kver="$(get_kver "$target/kernel")"

    # repack initrd magic, beware
    # assumptions: initrd is compressed with LZ4, cpio block size 512, microcode
    # at the beginning of initrd image
    (
        cd "$target/kernel"

        # XXX: ideally we should unpack the initrd, replace snap-boostrap and
        # repack it using ubuntu-core-initramfs --skeleton=<unpacked> this does not
        # work and the rebuilt kernel.efi panics unable to start init, but we
        # still need the unpacked initrd to get the right kernel modules
        objcopy -j .initrd -O binary kernel.efi "$target/work/initrd"

        # copy out the kernel image for create-efi command
        objcopy -j .linux -O binary kernel.efi "$target/work/vmlinuz-$kver"

        cp -a kernel.efi "$target/backup/"
    )

    (
        cd "$target/work"
        # this works on 20.04 but not on 18.04
        unmkinitramfs initrd unpacked-initrd
    )

    # copy the unpacked initrd to use as the target skeleton
    cp -ar "$target/work/unpacked-initrd" "$target/skeleton"

    echo "prepared workspace at $target"
    echo "  kernel:              $target/kernel ($kver)"
    echo "  kernel.efi backup:   $target/backup/kernel.efi"
    echo "  temporary artifacts: $target/work"
    echo "  initramfs skeleton:  $target/skeleton"

}

prepare_kernel() {
    local target="$1"

    if [[ -z "$target" ]]; then
        echo "usage: repack <extract-tree>"
        exit 1
    fi

    target=$(realpath "$target")
    kver="$(get_kver "$target/kernel")"

    (
        # all the skeleton edits go to a local copy of distro directory
        skeletondir="$target/skeleton"

        cd "$target/work"
        # XXX: need to be careful to build an initrd using the right kernel
        # modules from the unpacked initrd, rather than the host which may be
        # running a different kernel
        (
            # accommodate assumptions about tree layout, use the unpacked initrd
            # to pick up the right modules
            cd unpacked-initrd/main
            ubuntu-core-initramfs create-initrd \
                                  --kernelver "$kver" \
                                  --skeleton "$skeletondir" \
                                  --feature main \
                                  --kerneldir "lib/modules/$kver" \
                                  --output "$target/work/repacked-initrd"
        )

        # assumes all files are named <name>-$kver
        ubuntu-core-initramfs create-efi \
                              --kernelver "$kver" \
                              --initrd repacked-initrd \
                              --kernel vmlinuz \
                              --output repacked-kernel.efi

        cp "repacked-kernel.efi-$kver" "$target/kernel/kernel.efi"

        # XXX: needed?
        chmod +x "$target/kernel/kernel.efi"
    )
}

cull_firmware() {
    local target="$1"

    if [[ -z "$target" ]]; then
        echo "usage: cull-firmware <extract-tree>"
        exit 1
    fi
    (
        # XXX: drop ~450MB+ of firmware which should not be needed in under qemu
        # or the cloud system
        cd "$target/kernel"
        rm -rf firmware/*
    )
}

cull_modules() {
    local target="$1"

    if [[ -z "$target" ]]; then
        echo "usage: cull-modules <extract-tree>"
        exit 1
    fi

    target=$(realpath "$target")
    kver="$(get_kver "$target/kernel")"

    (
        cd "$target/kernel"
        # drop unnecessary modules
        awk '{print $1}' <  /proc/modules  | sort > "$target/work/current-modules"
        #shellcheck disable=SC2044
        for m in $(find modules/ -name '*.ko'); do
            noko=$(basename "$m"); noko="${noko%.ko}"
            if echo "$noko" | grep -f "$target/work/current-modules" -q ; then
                echo "keeping $m - $noko"
            else
                rm -f "$m"
            fi
        done

        # depmod assumes that /lib/modules/$kver is under basepath
        mkdir -p fake/lib
        ln -s "$PWD/modules" fake/lib/modules
        depmod -b "$PWD/fake" -A -v "$kver"
        rm -rf fake
    )
}

pack() {
    local target="$1"

    if [[ -z "$target" ]]; then
        echo "usage: pack <extract-tree> <opts to snap pack>"
        exit 1
    fi
    snap pack "${@:2}" "$target/kernel" 
}

show_help() {
    grep '^##HELP:' "$0" | sed -e 's/##HELP: \?//'
}


opt="$1"
shift || true

if [[ -z "$opt" ]] || [[ "$opt" == "--help" ]]; then
    show_help
    exit 1
fi

case "$opt" in
    setup)
        setup_deps
        ;;
    extract)
        extract_kernel "$@"
        ;;
    prepare)
        prepare_kernel "$@"
        ;;
    cull-modules)
        cull_modules "$@"
        ;;
    cull-firmware)
        cull_firmware "$@"
        ;;
    pack)
        pack "$@"
        ;;
esac
