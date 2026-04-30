#!/usr/bin/python3
#
# Copyright (C) 2026 Canonical Ltd
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

# Script that translates a chisel .wall file used in core26+ to the dpkg.yaml
# with package names and versions that was used in previous core bases
# releases.

import json
import subprocess
import sys
import yaml


def main():
    if len(sys.argv) != 3:
        print(f'Usage: {sys.argv[0]} <wall_file> <output_yaml_file>')
        sys.exit(1)

    # Pull the packages information from the wall file, ignore the rest
    wall_p = sys.argv[1]
    dpkg_p = sys.argv[2]
    dpkg = {'packages': []}
    p = subprocess.run(['zstdcat', wall_p], stdout=subprocess.PIPE, check=True)
    for line in p.stdout.decode('utf-8').splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        if record.get('kind') == 'package':
            pkg_name = record.get('name')
        if 'version' in record:
            dpkg['packages'].append(pkg_name + '=' + record['version'])

    # Now save in yaml format
    with open(dpkg_p, 'w') as f:
        yaml.dump(dpkg, f, default_flow_style=False)


if __name__ == '__main__':
    sys.exit(main())
