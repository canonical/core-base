#!/bin/bash

set -eu

tmpdir=$(mktemp -d --tmpdir core-base.XXXXXXXXXX)
cleanup() {
    rm -rf "${tmpdir}"
}
trap cleanup EXIT

unsquashfs -d "${tmpdir}/skeleton" -ef extract.list core22.snap
mv "${tmpdir}/skeleton/usr/lib/ubuntu-core-initramfs" .
