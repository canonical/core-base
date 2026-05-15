#!/usr/bin/python3
#
# Copyright (C) 2026 Canonical Ltd
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3 as
# published by the Free Software Foundation.

"""Prune stale file entries from a chisel manifest.wall after rootfs hooks.

The hooks can remove files that were originally pulled in by chisel slices.
This keeps manifest.wall aligned with what is actually shipped in the rootfs.
"""

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
from compression import zstd
from datetime import datetime, timezone


PATH_KEYS_BY_KIND = {
    'content': ('path',),
    'symlink': ('path',),
    'hardlink': ('path',),
    'directory': ('path',),
    'path': ('path',),
}

PYTHON_PATH_PREFIXES = (
    '/usr/lib/python',
    '/usr/lib/python3',
    '/usr/share/python3',
    '/usr/bin/python',
)

PYTHON_PATH_EXACT = (
    '/usr/bin/py3clean',
    '/usr/bin/py3compile',
    '/usr/bin/py3versions',
)


def _manifest_path(rootfs: str) -> pathlib.Path:
    """Return the canonical location of chisel's compressed manifest in rootfs."""
    # Chisel always writes the compressed wall manifest at this fixed location.
    return pathlib.Path(rootfs) / 'var/lib/chisel/manifest.wall'


def _extract_record_path(record: dict) -> str | None:
    """Extract an absolute filesystem path from a manifest record when available."""
    # Only records describing filesystem objects can be validated against rootfs.
    kind = record.get('kind')
    if kind is None:
        # This happens for the header, ignore entries that are not actual records.
        return None

    if not isinstance(kind, str):
        raise ValueError(f'manifest record "kind" is not a string: {record}')

    keys = PATH_KEYS_BY_KIND.get(kind)
    if not keys:
        print(f'Unknown manifest record kind: {kind}', file=sys.stderr)
        return None

    for key in keys:
        value = record.get(key)
        if not isinstance(value, str):
            raise ValueError(f'manifest record "{kind}" path key "{key}" is not a string or missing: {record}')
        if not value.startswith('/'):
            raise ValueError(f'manifest record "{kind}" path key "{key}" is not an absolute path: {record}')
        return value
    return None


def _record_slices(record: dict) -> set[str]:
    """Return the set of slices referenced by a manifest record."""
    # File-backed records can reference a single slice or a list of slices.
    slices: set[str] = set()

    if 'slice' in record:
        slice_name = record.get('slice')
        if not isinstance(slice_name, str):
            raise ValueError(f'manifest record "slice" is not a string: {record}')
        slices.add(slice_name)
    elif 'slices' in record:
        many = record.get('slices')
        if not isinstance(many, list):
            raise ValueError(f'manifest record "slices" is not a list: {record}')
        for item in many:
            if not isinstance(item, str):
                raise ValueError(f'manifest record "slices" contains a non-string item: {record}')
            slices.add(item)

    return slices


def _slice_to_package(slice_name: str) -> str:
    """Map a chisel slice name to its package name prefix."""
    # Chisel slice names are <debian-package>_<slice>; package names have no '_'.
    if '_' not in slice_name:
        raise ValueError(f'manifest record slice name does not contain "_": {slice_name}')
    return slice_name.rsplit('_', 1)[0]


def _is_python_package(package_name: str) -> bool:
    """Return True when a package is part of python3 runtime or stdlib."""
    return package_name.startswith('python3') or package_name.startswith('libpython3')


def _is_python_slice(slice_name: str) -> bool:
    """Return True when a slice belongs to a python-related package."""
    package_name = _slice_to_package(slice_name)
    return _is_python_package(package_name)


def _is_python_path(path: str) -> bool:
    """Return True when a filesystem path is part of the hidden python surface."""
    if path in PYTHON_PATH_EXACT:
        return True
    return path.startswith(PYTHON_PATH_PREFIXES)


def _record_targets_python(record: dict, record_path: str | None) -> bool:
    """Return True when a manifest record should be excluded by python policy."""
    if record_path is not None and _is_python_path(record_path):
        return True

    if any(_is_python_slice(slice_name) for slice_name in _record_slices(record)):
        return True

    return False


def _is_header_record(record: dict) -> bool:
    """Return True when a manifest record is the jsonwall header line."""
    return 'jsonwall' in record and 'schema' in record and 'count' in record


# Manifest are of jsonwall schema:
# https://documentation.ubuntu.com/chisel/latest/reference/manifest/#manifest-format
def _decompress_lines(wall_path: pathlib.Path) -> list[str]:
    """Read manifest.wall and return decoded JSON-lines records as text lines."""
    # manifest.wall is a zstd-compressed JSON-lines stream.
    with zstd.open(wall_path) as f:
        file_content = f.read()
    return file_content.decode('utf-8').split('\n')


def _compress_lines(lines: list[str], wall_path: pathlib.Path) -> None:
    """Write JSON-lines back to manifest.wall using atomic zstd replacement."""

    tmp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix='manifest.wall.', suffix='.tmp', dir=str(wall_path.parent), delete=False
        ) as tmp_file:
            tmp_path = pathlib.Path(tmp_file.name)
                
            # Keep JSON-lines format (newline-terminated records) when writing back.
            payload = ('\n'.join(lines) + '\n').encode('utf-8')
            with zstd.open(tmp_path, "w") as f:
                f.write(payload)
        
        shutil.copymode(wall_path, tmp_path)
        try:
            original_stat = wall_path.stat()
            os.chown(tmp_path, original_stat.st_uid, original_stat.st_gid)
        except PermissionError:
            # Non-root runs may not be able to set owner/group explicitly.
            pass
        # Atomic replacement avoids leaving a partially-written manifest behind.
        os.replace(tmp_path, wall_path)
    finally:
        if tmp_path and tmp_path.exists():
            tmp_path.unlink()


def _write_report(
    rootfs: str,
    wall_path: pathlib.Path,
    total: int,
    dropped: int,
    dropped_entries: list[dict],
) -> pathlib.Path:
    """Writes a JSON report with all dropped manifest records and counts."""
    # Report is stored next to chisel metadata in the rootfs.
    report_path = pathlib.Path(rootfs) / 'var/lib/chisel/manifest-refresh-report.json'
    report_path.parent.mkdir(parents=True, exist_ok=True)

    payload = {
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'manifest_path': str(wall_path.relative_to(rootfs)),
        'total_records_seen': total,
        'dropped_records': dropped,
        'removed_entries': dropped_entries,
    }

    with open(report_path, 'w', encoding='utf-8') as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write('\n')
    return report_path


# The refresh function does the following;
# It goes through the entire manifest.wall and checks each file entry against the rootfs.
# If the file exists in the rootfs, it is kept in the manifest, otherwise it is dropped.
# If not, it is dropped from the manifest, and optionally recorded in a report of removed entries.
# Afterwards it goes through all the slice and package entries, and drops those that are no longer 
# referenced by any surviving file entry.
def refresh(
    rootfs: str,
    write_report: bool = False,
    exclude_python: bool = False,
) -> tuple[int, int, pathlib.Path | None]:
    """Refresh manifest.wall against rootfs and optional policy-based exclusions."""
    wall_path = _manifest_path(rootfs)
    if not wall_path.exists():
        return (0, 0, None)

    initial_pass_kept: list[tuple[dict, str]] = []
    removed_entries: list[dict] = []
    dropped = 0
    total = 0
    surviving_slices: set[str] = set()

    # The initial pass checks file-backed records against the rootfs
    for line in _decompress_lines(wall_path):
        if not line.strip():
            continue
        
        total += 1
        record = json.loads(line)
        record_path = _extract_record_path(record)

        if exclude_python and _record_targets_python(record, record_path):
            # Intentionally hide python runtime details from the exported manifest.
            # This is a policy choice to avoid exposing the python runtime.
            removed_entries.append(record)
            dropped += 1
            continue
        
        # If the record is not a path entry, then we keep it for now and
        # do additional filtering in second pass.
        if record_path is None:
            initial_pass_kept.append((record, line))
            continue

        fs_path = pathlib.Path(rootfs) / record_path.lstrip('/')
        if os.path.lexists(fs_path):
            initial_pass_kept.append((record, line))
            surviving_slices.update(_record_slices(record))
        else:
            # Drop manifest entries whose paths were removed by post-cut hooks.
            removed_entries.append(record)
            dropped += 1

    # Get the list of packages in the manifest
    surviving_packages = {
        package_name
        for package_name in (_slice_to_package(slice_name) for slice_name in surviving_slices)
        if package_name is not None
    }

    # Second pass removes slices and packages
    kept_records: list[tuple[dict, str]] = []
    for record, line in initial_pass_kept:
        if exclude_python and record.get('kind') == 'slice' and _is_python_slice(
            record.get('name', '')
        ):
            removed_entries.append(record)
            dropped += 1
            continue

        if exclude_python and record.get('kind') == 'package' and _is_python_package(
            record.get('name', '')
        ):
            removed_entries.append(record)
            dropped += 1
            continue

        if record.get('kind') == 'slice' and record.get('name') not in surviving_slices:
            removed_entries.append(record)
            dropped += 1
            continue

        if record.get('kind') == 'package' and record.get('name') not in surviving_packages:
            removed_entries.append(record)
            dropped += 1
            continue

        kept_records.append((record, line))

    # Update the header record with the new count if it has changed
    expected_count = len(kept_records)
    kept_lines: list[str] = []
    for record, line in kept_records:
        if _is_header_record(record):
            if record.get('count') != expected_count:
                header_record = dict(record)
                header_record['count'] = expected_count
                line = json.dumps(header_record, separators=(',', ':'))
        kept_lines.append(line)

    # If no entries were dropped, then let us not
    # rewrite the manifest, and rather leave it in place
    if dropped > 0:
        _compress_lines(kept_lines, wall_path)
    
    # still generate the report if requested
    report_path = None
    if write_report:
        report_path = _write_report(
            rootfs=rootfs,
            wall_path=wall_path,
            total=total,
            dropped=dropped,
            dropped_entries=removed_entries,
        )
    return (total, dropped, report_path)


def main() -> int:
    """Parse CLI arguments and execute manifest reconciliation."""
    parser = argparse.ArgumentParser(description="Refreshes the chisel manifest")

    parser.add_argument('rootfs', help='Path to the root of the filesystem to reconcile against')
    parser.add_argument(
        "--write-report",
        action="store_true",
        help='Write a report of removed manifest entries',
    )
    parser.add_argument(
        "--exclude-python",
        action="store_true",
        help='Hide python runtime paths/slices/packages from the refreshed manifest',
    )
    args = parser.parse_args()

    total, dropped, report_path = refresh(
        rootfs=args.rootfs,
        write_report=args.write_report,
        exclude_python=args.exclude_python,
    )
    if total == 0:
        print('No chisel manifest changes needed: manifest.wall is missing or empty')
        return 0

    print(f'Reconciled chisel manifest: dropped {dropped} stale entries')
    if report_path is not None:
        print(f'Wrote report of removals: {report_path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
