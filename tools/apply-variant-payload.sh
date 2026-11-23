#!/bin/bash
#
# Apply a build variant's payload to a rootfs that is being assembled.
#
# Usage: apply-variant-payload.sh <rootfs> <variant>
#
# Called from the Makefile "install" target (and exercised by
# hook-tests/995-variant-payload.test). <rootfs> is the rootfs the base
# snap is assembled into, <variant> the value of SNAP_BUILD_VARIANT.
# See variants/README.md for the payload layout.
#
# Runs inside the snapcraft build environment as root, with the current
# directory set to the project source tree.

set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <rootfs> <variant>" >&2
    exit 1
fi

rootfs="$1"
variant="$2"

case "$variant" in
    *[!a-z0-9-]*)
        echo "E: invalid variant name '$variant'" >&2
        exit 1
        ;;
esac

payload="$(cd "$(dirname "$0")/.." && pwd)/variants/$variant"

if [ ! -d "$payload" ]; then
    echo "I: variant '$variant' has no payload directory, nothing to apply"
    exit 0
fi

echo "I: applying variant payload from $payload"

# (a) extra files, copied verbatim into the rootfs on top of the base
# static/ files (a same-path variant file wins). Top-level hidden
# files are skipped, mirroring the base "cp -a static/*" copy.
if [ -d "$payload/static" ]; then
    for entry in "$payload"/static/*; do
        [ -e "$entry" ] || continue
        echo "I: copying $(basename "$entry") into the rootfs"
        cp -a "$entry" "$rootfs/"
    done

    # (a2) multiarch parameterization: payload paths may express the
    # Debian multiarch triplet with the @MULTIARCH@ placeholder (in
    # directory names, symlink targets and file contents). Substitute
    # the build environment's triplet, so a payload lands at the
    # build architecture's multiarch paths instead of silently
    # assuming amd64. On an amd64 build this substitutes
    # x86_64-linux-gnu, i.e. exactly the paths the placeholder was
    # written for - a functional no-op. The rootfs copy is transformed
    # in place; the payload source tree is never modified.
    placeholder='@MULTIARCH@'
    triplet="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"

    # a placeholder-named directory in the copied rootfs: if the
    # destination (e.g. the chisel-staged /usr/lib/<triplet>) already
    # exists, merge the copy into it, otherwise rename outright.
    # Deepest first, so nested placeholder directories also resolve.
    find "$rootfs" -depth -type d -name "*$placeholder*" -print0 |
        while IFS= read -r -d '' src; do
            dst="${src//$placeholder/$triplet}"
            if [ -d "$dst" ]; then
                cp -a "$src/." "$dst/"
                rm -rf "$src"
            else
                mv "$src" "$dst"
            fi
        done

    # placeholder occurrences inside copied regular files (e.g. unit
    # file environment paths); payload-relative paths are mapped onto
    # the (already renamed) rootfs locations
    find "$payload/static" -type f -exec grep -lFZ -- "$placeholder" {} + |
        while IFS= read -r -d '' src; do
            rel="${src#"$payload/static"/}"
            sed -i "s/$placeholder/$triplet/g" \
                "$rootfs/${rel//$placeholder/$triplet}"
        done

    # placeholder occurrences inside copied symlink targets
    find "$payload/static" -type l -print0 |
        while IFS= read -r -d '' src; do
            rel="${src#"$payload/static"/}"
            dst="$rootfs/${rel//$placeholder/$triplet}"
            [ -L "$dst" ] || continue
            target="$(readlink "$dst")"
            case "$target" in
                *"$placeholder"*)
                    ln -sfn "${target//$placeholder/$triplet}" "$dst"
                    ;;
            esac
        done

    # (a3) arch-specific payload files a variant cannot ship in its
    # tree: a variant's snapcraft parts may stage build-time payload
    # (ELFs resolved from archive debs per build architecture, or
    # binaries built from in-tree source) into
    # "$CRAFT_STAGE/<variant>-payload"; it is copied into the rootfs
    # here, on that variant's builds only. The staged tree already
    # carries the build architecture's real multiarch paths, so no
    # substitution is needed.
    if [ -d "${CRAFT_STAGE:-}/$variant-payload" ]; then
        echo "I: copying the staged $variant payload into the rootfs"
        cp -a "$CRAFT_STAGE/$variant-payload/." "$rootfs/"
    fi
fi

# Append a fragment to a file, keeping the file's trailing newline
# intact so appended fragments stay complete lines.
append_fragment() {
    target="$1"
    fragment="$2"
    if [ -s "$target" ] && [ -n "$(tail -c 1 "$target")" ]; then
        printf '\n' >> "$target"
    fi
    cat "$fragment" >> "$target"
}

# (b) fstab fragments appended to /etc/fstab, in glob order.
for f in "$payload"/fstab.d/*.conf; do
    [ -e "$f" ] || continue
    echo "I: appending $(basename "$f") to /etc/fstab"
    append_fragment "$rootfs/etc/fstab" "$f"
done

# (c) tmpfiles.d fragments appended to core-writable.conf, in glob
# order. Every C line added here needs a matching fstab entry (knob b)
# and template data under /usr/share/factory (knob a); the
# 993-factory-files build-time test enforces this. d/f lines may also
# target paths nested under an existing mount (e.g. skeleton entries
# inside /var/lib/snapd) without their own fstab entry.
for f in "$payload"/writable.conf.d/*.conf; do
    [ -e "$f" ] || continue
    echo "I: appending $(basename "$f") to core-writable.conf"
    append_fragment "$rootfs/usr/lib/tmpfiles.d/core-writable.conf" "$f"
done
