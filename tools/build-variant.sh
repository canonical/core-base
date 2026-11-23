#!/bin/bash
#
# Build a named variant of the core26 base snap and pack it as
# core26-<variant>_<version>_<arch>.snap.
#
# Usage: tools/build-variant.sh <variant>
#
# Selection works like the Launchpad recipes do: a "build-env" file
# with SNAP_BUILD_VARIANT=<variant> is written into the project root
# and removed again after the build (see variants/README.md).
#
# The snap name cannot be changed inside the build: snapcraft.yaml's
# project name is static (changing it would swap snapcraft's
# project-keyed LXD build instance and lose the incremental build
# state). The packed snap is therefore packed a second time from the
# build instance's prime directory with meta/snap.yaml's name patched,
# as real root inside the LXD container, so file ownership and the /dev
# device nodes survive the round trip. Requires the snapcraft LXD
# provider (the default for this project).
#
# Run from the project root as the user that normally runs snapcraft;
# any http_proxy for the build environment must be set by the caller.
# The per-repo build lock ("flock", as used by the local go-build
# wrappers) is not taken here; don't run concurrent builds of the same
# project.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <variant>" >&2
    exit 1
fi
variant="$1"
case "$variant" in
    *[!a-z0-9-]*)
        echo "E: invalid variant name '$variant'" >&2
        exit 1
        ;;
esac

command -v lxc >/dev/null || {
    echo "E: lxc is required for the snap renaming step" >&2
    exit 1
}

# print a field's value from meta/snap.yaml of a packed snap (quotes stripped)
meta_field() {
    unsquashfs -cat "$1" meta/snap.yaml 2>/dev/null |
        awk -v field="$2" '$1 == field":" {print $2}' |
        tr -d "'"
}

project=$(awk '/^name:/ {print $2; exit}' snapcraft.yaml)
arch=$(dpkg --print-architecture)

if [ -e build-env ]; then
    echo "E: build-env already exists in the project root, refusing to overwrite" >&2
    exit 1
fi

# The packed snap's file name is <project>_<version>[_+<variant>]_<arch>.snap:
# on a fresh build the version already carries the "+<variant>" suffix
# (set by the build-env part), but on incremental builds craft-parts
# re-applies the project_vars snapshots recorded in the OTHER parts'
# cached step states, which clobber the freshly set version (see the
# ActionType.SKIP handling in craft-parts' executor). Find what was
# just packed by mtime: the newest <project>_*_<arch>.snap written
# after this script started (a repack overwrites the same file name).
start_epoch=$(date +%s)

printf 'SNAP_BUILD_VARIANT=%s\n' "$variant" > build-env
trap 'rm -f build-env' EXIT

echo "I: building the $variant variant of $project"
snapcraft pack

shopt -s nullglob
src=
for candidate in "${project}"_*_"${arch}".snap; do
    [ "$(stat -c %Y "$candidate")" -lt "$start_epoch" ] && continue
    if [ -z "$src" ] || [ "$candidate" -nt "$src" ]; then
        src=$candidate
    fi
done
shopt -u nullglob
if [ -z "$src" ]; then
    echo "E: no ${project}_*_${arch}.snap written by this build found" >&2
    exit 1
fi
src_version=$(meta_field "$src" version)
echo "I: packed $src (version $src_version)"

# locate the snapcraft LXD build instance for this project: the one
# whose prime directory holds the version we just packed. Every
# candidate is inspected for the match; stopped ones are started
# temporarily for the exec calls below (an already-running candidate
# is left alone), and every instance this script started is stopped
# again on every exit path, success or failure.
instance=
started=
restore_instances() {
    local i
    for i in $started; do
        lxc stop "$i" --project snapcraft >/dev/null 2>&1 || true
    done
    rm -f build-env
}
trap restore_instances EXIT

for candidate in $(lxc list --project snapcraft --format csv -c n \
        | grep "^snapcraft-${project}-${arch}-" || true); do
    if [ "$(lxc list --project snapcraft --format csv -c s "$candidate")" \
            != RUNNING ]; then
        lxc start "$candidate" --project snapcraft >/dev/null || {
            echo "E: failed to start candidate build instance $candidate" >&2
            exit 1
        }
        started="$started $candidate"
    fi
    prime_version=$(lxc exec "$candidate" --project snapcraft -- \
        cat /root/prime/meta/snap.yaml 2>/dev/null |
        awk -v field=version '$1 == field":" {print $2}' | tr -d "'" || true)
    if [ "$prime_version" = "$src_version" ]; then
        if [ -n "$instance" ]; then
            echo "E: multiple snapcraft instances hold a matching prime;" \
                "remove stale ones (lxc list --project snapcraft) and retry" >&2
            exit 1
        fi
        instance=$candidate
    fi
done
if [ -z "$instance" ]; then
    echo "E: no snapcraft LXD instance with a prime for version" \
        "$src_version found, cannot pack the renamed snap" >&2
    exit 1
fi
echo "I: renaming via snapcraft build instance $instance"

# Patch the snap name and the version suffix in the instance's prime
# directory and pack it again as real root, so file ownership and the
# /dev device nodes survive. The version gets its "+<variant>" suffix
# here if the build lost it to the cached-state quirk described above
# (on fresh builds it is already suffixed and this is a no-op). The
# prime metadata is restored afterwards; snapcraft regenerates it on
# the next pack anyway.
new_name="${project}-${variant}"
lxc exec "$instance" --project snapcraft -- bash -s <<REMOTE
set -eu
# after a cold start, wait until snapd has mounted its own squashfs:
# "snap pack" needs mksquashfs from the snapd snap
for i in \$(seq 60); do
    if /snap/snapd/current/usr/bin/mksquashfs -version >/dev/null 2>&1; then
        break
    fi
    [ "\$i" -lt 60 ] || {
        echo "E: snapd snap not mounted in the build instance" >&2
        exit 1
    }
    sleep 1
done
# the metadata backup lives OUTSIDE the prime directory so it can never
# end up packed into the snap
cleanup() {
    if [ -e /root/meta-snap.yaml.orig ]; then
        mv /root/meta-snap.yaml.orig /root/prime/meta/snap.yaml
    fi
}
trap cleanup EXIT
cp /root/prime/meta/snap.yaml /root/meta-snap.yaml.orig
sed -i "s/^name: ${project}\$/name: ${new_name}/" /root/prime/meta/snap.yaml
if ! grep -q "^version: '.*+${variant}'\$" /root/prime/meta/snap.yaml; then
    sed -i "s/^version: '${src_version}'\$/version: '${src_version}+${variant}'/" \
        /root/prime/meta/snap.yaml
fi
grep -E '^(name|version):' /root/prime/meta/snap.yaml
cd /tmp
rm -f renamed.snap
snap pack /root/prime --filename=renamed.snap
REMOTE

lxc file pull "${instance}/tmp/renamed.snap" . --project snapcraft
lxc exec "$instance" --project snapcraft -- rm -f /tmp/renamed.snap

# the packed metadata is the source of truth for the final file name
out="${new_name}_$(meta_field renamed.snap version)_${arch}.snap"
if [ -e "$out" ]; then
    echo "E: output snap $out already exists, refusing to overwrite" >&2
    exit 1
fi
mv renamed.snap "$out"

echo "I: verifying $out"
if [ "$(meta_field "$out" name)" != "$new_name" ]; then
    echo "E: $out does not carry the patched snap name" >&2
    exit 1
fi
case "$(meta_field "$out" version)" in
    *+"${variant}") ;;
    *)
        echo "E: $out does not carry the +${variant} version suffix" >&2
        exit 1
        ;;
esac

echo "I: done: $out"
