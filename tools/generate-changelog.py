#!/usr/bin/python3
#
# Copyright (C) 2024 Canonical Ltd
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Script is originally copied and modified from
# https://github.com/snapcore/system-snaps-cicd-tools/blob/0148d51ac8d1668f8ebe142d91673a65e520aa53/workflows/changelog-from-manifest.py

# Script that compares two manifest.yaml files and creates a paragraph
# that includes the changes for all deb files. These changes are
# obtained from the debian changelog for the different packages.

import argparse
import debian.changelog
import debian.debian_support
import gzip
import os
import requests
import sys
import yaml
from collections import namedtuple

# the packages here have for some weird reason "legit"
# reasons for not having a working changelog, thus we
# allow download for the packages mentioned here.
# keep the list short to not increase the time it takes
# to generate changelogs
pkg_allowed_list = [
    'distro-info-data', # is removed during hook
]

# Returns a dictionary from package name to version, using
# the packages section.
# manifest_p: path to manifest to load
def packages_from_manifest(manifest_p):
    with open(manifest_p) as manifest:
        manifest_y = yaml.safe_load(manifest)

        pkg_dict = {}
        for pkg in manifest_y['packages']:
            # package_name=version
            pkg_data = pkg.split('=')
            pkg_dict[pkg_data[0]] = pkg_data[1]
        return pkg_dict

def package_name(pkg):
    t = pkg.split(':')
    return t[0]

def get_changelog_from_file(docs_d, pkg):
    chl_deb_path = docs_d + '/' + package_name(pkg) + '/changelog.Debian.gz'
    chl_path = docs_d + '/' + package_name(pkg) + '/changelog.gz'
    if os.path.exists(chl_deb_path):
        with gzip.open(chl_deb_path) as chl_fh:
            return chl_fh.read().decode('utf-8')
    elif os.path.exists(chl_path):
        with gzip.open(chl_deb_path) as chl_fh:
            return chl_fh.read().decode('utf-8')
    else:
        raise FileNotFoundError("no supported changelog found for package " + pkg)

def get_changelog_from_url(pkg, new_v):
    url = 'https://changelogs.ubuntu.com/changelogs/binary/'
    
    print(f"failed to resolve changelog for {pkg} locally, downloading from official repo")
    safe_name = package_name(pkg)
    if safe_name not in pkg_allowed_list:
        raise Exception(f"{pkg} has not been whitelisted for changelog retrieval")
    
    if safe_name.startswith('lib'):
        url += safe_name[0:4]
    else:
        url += safe_name[0]
    url += '/' + safe_name + '/' + new_v + '/changelog'
    changelog_r = requests.get(url)
    if changelog_r.status_code != requests.codes.ok:
        raise Exception('No changelog found in ' + url + ' - status:' +
                        str(changelog_r.status_code))

    return changelog_r.text


# Gets difference in changelog between old and new versions
# Returns source package and the differences
def get_changes_for_version(docs_d, pkg, old_v, new_v, indent):
    # Try our best to resolve the changelog locally, if it does
    # not exist locally, then the package must be in the whitelisted
    # list of packages, when we try to resolve it from URL as backup.
    try:
        changelog = get_changelog_from_file(docs_d, pkg)
    except Exception:
        changelog = get_changelog_from_url(pkg, new_v)

    source_pkg = changelog[0:changelog.find(' ')]

    chl = debian.changelog.Changelog(changelog)
    old_deb_v = debian.debian_support.Version(old_v)
    for version in chl.get_versions():
        vc = debian.debian_support.version_compare(old_deb_v, version)
        if vc >= 0:
            break

    # Get the changelog chunk since the version older or equal to old_v
    change_chunk = ''
    old_change_start = f"{source_pkg} ({version})"
    found_version = False
    for line in changelog.splitlines():
        if line.startswith(old_change_start):
            found_version = True
            break
        if line == '':
            change_chunk += '\n'
        else:
            change_chunk += indent + line + '\n'

    if not found_version:
        raise EOFError(f"{old_change_start} was not found in the changelog, aborting")

    return source_pkg, change_chunk


# Returns the changes related to primed packages between two manifests
# old_manifest_p: path to old manifest
# new_manifest_p: path to newer manifest
# docs_d: directory with docs from debian packages
def compare_manifests(old_manifest_p, new_manifest_p, docs_d):
    old_packages = packages_from_manifest(old_manifest_p)
    new_packages = packages_from_manifest(new_manifest_p)
    changes = ''

    src_pkgs = {}
    SrcPkgData = namedtuple('SrcPkgData', 'old_v new_v changes debs')
    for pkg, new_v in sorted(new_packages.items()):
        try:
            old_v = old_packages[pkg]
            if old_v != new_v:
                src, pkg_change = get_changes_for_version(docs_d, pkg, old_v,
                                                          new_v, '  ')
                if src not in src_pkgs:
                    src_pkgs[src] = SrcPkgData(old_v, new_v, pkg_change, [pkg])
                else:
                    src_pkgs[src].debs.append(pkg)
        except KeyError:
            changes += pkg + ' (' + new_v + '): new primed package\n\n'

    for src_pkg, pkg_data in sorted(src_pkgs.items()):
        changes += ', '.join(pkg_data.debs)
        changes += ' (built from ' + src_pkg + ') updated from '
        changes += pkg_data.old_v + ' to ' + pkg_data.new_v + ':\n\n'
        changes += pkg_data.changes

    for pkg, old_v in sorted(old_packages.items()):
        if pkg not in new_packages:
            changes += pkg + ': not primed anymore\n\n'

    return changes


def main():
    parser = argparse.ArgumentParser(description="Manifest changelog generator")

    parser.add_argument('old', metavar='old-manifest', help='Path to the manifest of the previous snap')
    parser.add_argument('new', metavar='new-manifest', help='Path to the manifest of the new snap')
    parser.add_argument('docs', metavar='docs-dir', help='Path to the usr/share/doc directory in the rootfs of the new snap')
    parser.add_argument('out', help='Optionally a path to where the changelog should be written')
    args = parser.parse_args()

    old_manifest = args.old
    new_manifest = args.new
    docs_dir = args.docs

    changes = '[ Changes in primed packages ]\n\n'
    pkg_changes = compare_manifests(old_manifest, new_manifest, docs_dir)
    if pkg_changes != '':
        changes += pkg_changes
    else:
        changes += 'No changes for primed packages\n\n'
    with open(args.out, "w") as f:
        f.write(changes)
    return 0


if __name__ == '__main__':
    sys.exit(main())
