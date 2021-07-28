#!/bin/sh -e

TEST_IMPORT=1
# shellcheck disable=SC1091
. static/usr/lib/core/handle-writable-paths

rootmnt="$(mktemp -d)"
trap 'rm -rf "$rootmnt"' EXIT

# test: no _writable_defaults does not break
mkdir -p "$rootmnt/writeable/system-data/"
handle_writable_defaults "$rootmnt"
echo "Testing no _writable_defaults does not break anything"

# test: empty _writable_defaults does not break
mkdir -p "$rootmnt/writable/system-data/_writable_defaults"
handle_writable_defaults "$rootmnt"
echo "Testing empty _writable_defaults does not break anything"
set -x
test -e "$rootmnt/writable/system-data/_writable_defaults/.done"
# 3 because: "system-data", "system-data/_writable_defaults", "s-d/_w_d/.done"
test "$(find "$rootmnt/writable/system-data/" | wc -l)" = 3
set +x
# cleanup
rm -f "$rootmnt/writable/system-data/_writable_defaults/.done"

# test: file/dir/symlinks in _writable_defaults
mkdir -p "$rootmnt/writable/system-data/_writable_defaults/some-dir"
touch "$rootmnt/writable/system-data/_writable_defaults/some-dir/some-file"
touch "$rootmnt/writable/system-data/_writable_defaults/other-file"
ln -s "other-file" "$rootmnt/writable/system-data/_writable_defaults/some-link"
ln -s "no-file" "$rootmnt/writable/system-data/_writable_defaults/broken-link"

handle_writable_defaults "$rootmnt"
# ensure we have the .done file
echo "Testing files/dirs/symlinks in _writable_defaults work"
set -x
test -e "$rootmnt/writable/system-data/_writable_defaults/.done"
test -d "$rootmnt/writable/system-data/some-dir"
test -e "$rootmnt/writable/system-data/some-dir/some-file"
test -e "$rootmnt/writable/system-data/other-file"
test -L "$rootmnt/writable/system-data/some-link"
test -L "$rootmnt/writable/system-data/broken-link"
set +x
# cleanup
rm -f "$rootmnt/writable/system-data/_writable_defaults/.done"
