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
from datetime import datetime
import debian.changelog
import debian.debian_support
import gzip
import os
import subprocess
import re
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
    'dpkg',    # is removed during hook
    'openssl'  # contains a symlink which is broken currently
]

# List of packages with no valid changelog. We only have gnutls-bin for the
# moment. It does not have a valid changelog as
# /usr/share/doc/gnutls-bin/changelog.Debian.gz is a symlink to
# ../libgnutls-dane0/changelog.Debian.gz which is in turn a symlink to
# ../libgnutls30/changelog.Debian.gz. However, libgnutls-dane0 is not in the
# base (removed by 400-trim-pkcs-11.chroot) so the chain is broken. This is ok
# as anyway we will get the changes from libgnutls30.
pkg_no_changelog = ['gnutls-bin']


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
        with gzip.open(chl_path) as chl_fh:
            return chl_fh.read().decode('utf-8')
    else:
        raise FileNotFoundError("no supported changelog found for package " + pkg)


def get_changelog_from_url(pkg, new_v, on_lp):
    url = 'https://changelogs.ubuntu.com/changelogs/binary/'

    print(f"failed to resolve changelog for {pkg} locally, downloading from official repo")
    safe_name = package_name(pkg)
    if not on_lp and safe_name not in pkg_allowed_list:
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


# Exception thrown for packages with no local or remote changelog
class PackageNoChangelog(Exception):
    pass


# Exception thrown for packages for which we do not find a previous change
class NoOldChange(Exception):
    pass


# Gets difference in changelog between old and new versions
# Returns source package and the differences
def get_changes_for_version(docs_d, pkg, old_v, new_v, indent, on_lp):
    # Try our best to resolve the changelog locally, if it does
    # not exist locally, then the package must be in the whitelisted
    # list of packages, when we try to resolve it from URL as backup.
    try:
        changelog = get_changelog_from_file(docs_d, pkg)
    except Exception:
        if re.match(r'.*\+esm[0-9]*$', new_v) or package_name(pkg) in pkg_no_changelog:
            raise PackageNoChangelog('package ' + pkg + ' does not have changelog')
        changelog = get_changelog_from_url(pkg, new_v, on_lp)

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
        # It can happen if a binary package changes the source package it came
        # from, for instance this has been seen for libatomic1 that was built
        # from gcc-15 to gcc-16.
        raise NoOldChange(f"{old_change_start} for {pkg} was not found in the changelog")

    return source_pkg, change_chunk


# Returns the changes related to primed packages between two manifests
# old_manifest_p: path to old manifest
# new_manifest_p: path to newer manifest
# docs_d: directory with docs from debian packages
def compare_manifests(old_manifest_p, new_manifest_p, docs_d, on_lp):
    old_packages = packages_from_manifest(old_manifest_p)
    new_packages = packages_from_manifest(new_manifest_p)
    changes = ''

    src_pkgs = {}
    SrcPkgData = namedtuple('SrcPkgData', 'old_v new_v changes debs')
    for pkg, new_v in sorted(new_packages.items()):
        try:
            old_v = old_packages[pkg]
            if old_v != new_v:
                try:
                    src, pkg_change = get_changes_for_version(docs_d, pkg, old_v,
                                                              new_v, '  ', on_lp)
                    if src not in src_pkgs:
                        src_pkgs[src] = SrcPkgData(old_v, new_v, pkg_change, [pkg])
                    else:
                        src_pkgs[src].debs.append(pkg)
                except PackageNoChangelog as e:
                    print(e)
                except NoOldChange as e:
                    print(e)
                    changes += pkg + ' (' + new_v + '): new primed package\n\n'
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


def find_commit_in_changelog(clog_p) -> str:
    if clog_p == "" or not os.path.exists(clog_p):
        print(f"No previous changelog existed at {clog_p}, skipping changelog generation for local repo")
        return ""

    # expect commit in the first line
    with open(clog_p, "r") as f:
        line = f.readline().strip()
        if "commit" in line:
            tokens = line.split("/")
            return tokens[-1]
        return ""


def read_commit_hash() -> str:
    return subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode('ascii').strip()


def remove_suffix(input_string, suffix):
    if suffix and input_string.endswith(suffix):
        return input_string[:-len(suffix)]
    return input_string


def read_remote_git_url() -> str:
    remote_url = subprocess.check_output(['git', 'remote', 'get-url', 'origin']).decode('ascii').strip()
    if remote_url.startswith("git@github.com:"):
        remote_url = remote_url.replace("git@github.com:", "https://github.com/")
    return remove_suffix(remote_url, ".git")


def log_between_commits(name, start, end):
    try:
        return subprocess.check_output(['git', 'shortlog', '--pretty=short', f'{start}..{end}']).decode()
    except Exception:
        # if there is no path from start..end then this might fail, however this
        # should only happen if the branch has diverged so much that the previous
        # release commit does not exist in the current fork. In this case let us
        # notify that we could not generate the changelog
        print(f"Failed to run 'git log' for the current repo starting at commit {start}, has branch diverged to much?")
        return f'No detected changes for the {name} snap\n\n'


def main():
    parser = argparse.ArgumentParser(description="Manifest changelog generator")

    parser.add_argument('old', metavar='previous-snap-root', help='Path to the root of the previous snap directory')
    parser.add_argument('new', metavar='new-snap-root', help='Path to the root of the new snap directory')
    parser.add_argument('name', help='The name of the snap')
    parser.add_argument("--launchpad", action="store_true", help='Indicate we are building on LP, ignoring the whitelist')
    args = parser.parse_args()

    old_changelog = os.path.join(args.old, "usr", "share", "doc", "ChangeLog")
    new_changelog = os.path.join(args.new, "usr", "share", "doc", "ChangeLog")
    old_manifest = os.path.join(args.old, "usr", "share", "snappy", "dpkg.yaml")
    new_manifest = os.path.join(args.new, "usr", "share", "snappy", "dpkg.yaml")
    docs_dir = os.path.join(args.new, "usr", "share", "doc")

    # get previous commit for the base, however important to note here that
    # the previous changelog might not exist (i.e before this was introduced)
    # and thus this might be empty.
    pcommit = find_commit_in_changelog(old_changelog)
    ccommit = read_commit_hash()

    # add a header that helps us audit where the current build is
    # sourced from.
    now = datetime.now()
    changes = f"{now.strftime("%d/%m/%Y")}, commit {read_remote_git_url()}/tree/{ccommit}\n\n"
    changes += f'[ Changes in the {args.name} snap ]\n\n'

    # Is there a previous commit? Then we get a log between them
    # if pcommit != ccommit.
    if pcommit != "" and pcommit != ccommit:
        changes += log_between_commits(args.name, pcommit, ccommit)
    else:
        changes += f'No detected changes for the {args.name} snap\n\n'

    changes += '[ Changes in primed packages ]\n\n'
    pkg_changes = compare_manifests(old_manifest, new_manifest, docs_dir, args.launchpad)
    if pkg_changes != '':
        changes += pkg_changes
    else:
        changes += 'No changes for primed packages\n\n'

    # append the old changelog changes
    if old_changelog != "" and os.path.exists(old_changelog):
        with open(old_changelog, "r") as f:
            changes += f.read()

    with open(new_changelog, "w") as f:
        f.write(changes)
    return 0


if __name__ == '__main__':
    sys.exit(main())
