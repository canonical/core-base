#!/bin/sh

set -eu

modeenv=/run/mnt/data/system-data/var/lib/snapd/modeenv
mode="$(/usr/libexec/core/get-mode mode "${modeenv}")" || mode="unknown"

case "${mode}" in
    install|recover|factory-reset)
        save_dir=/run/mnt/ubuntu-data/system-data/var/log/debug
        ;;
    *)
        save_dir=/run/mnt/data/system-data/var/log/debug
        ;;
esac

next_num=1
for boot in "${save_dir}"/boot*; do
    if [ -d "${boot}" ]; then
        base="$(basename "${boot}")"
        num="${base#boot}"
        if [ "${num}" -ge "${next_num}" ]; then
            next_num="$((${num}+1))"
        fi
    fi
done
next_dir="${save_dir}/boot${next_num}"
mkdir -p "${next_dir}"
mv /run/log/base/*.svg "${next_dir}/"

for initrd_file in /run/log/*.svg; do
    if [ -f "${initrd_file}" ]; then
        base="$(basename "${initrd_file}")"
        mv "${initrd_file}" "${next_dir}/initrd-${base}"
    fi
done
