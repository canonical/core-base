#!/bin/bash -ex

# Tags are expected to be <date>-<seq>_<branch>[+<variant>], for instance:
#   20260505-1_main+cloud-init
#   20260505_core22
#   20260505_core22+fips
# This commands removes the bits after '_' and takes the tag with the oldest
# date and sequence number.
tag=$(git tag --points-at HEAD | sed 's/_.*//g' | grep -E '^[0-9]{8}(-[0-9]+)?$' |
          sort --field-separator=- --key=1n,1 --key=2n,2 | tail -n1 || printf "")
if [ -z "$tag" ]; then
    # Current date is the default if there are no date tags
    tag=$(/bin/date +%Y%m%d)
fi

printf "%s" "$tag"
