#!/bin/bash

set -eu

CHISEL_DEBS="$1"
INSTALL_ROOT="$2"

mkdir -p "$INSTALL_ROOT/usr/share/snappy"

echo "package-repositories:" >> "$INSTALL_ROOT/usr/share/snappy/dpkg.yaml"
echo "packages:" >> "$INSTALL_ROOT/usr/share/snappy/dpkg.yaml"

for f in "$CHISEL_DEBS"/*; do
    is_deb="$(file "$f" | grep "Debian binary package" | cat)"
    if [ -z "$is_deb" ]; then
        continue
    fi
    deb_info="$(dpkg-deb -f "$f")"
    deb_name="$(echo "$deb_info" | awk -F: -v key="Package" '$1==key {print $2}' | tr -d ' ')" 
    deb_ver="$(echo "$deb_info" | awk -F: -v key="Version" '$1==key {print $2}' | tr -d ' ')"

    # echo to dpkg.list
    echo "$deb_info" >> "$INSTALL_ROOT/usr/share/snappy/dpkg.list"
    echo "" >> "$INSTALL_ROOT/usr/share/snappy/dpkg.list"

    # echo to dpkg.yaml
    echo "- $deb_name=$deb_ver" >> "$INSTALL_ROOT/usr/share/snappy/dpkg.yaml"
done
