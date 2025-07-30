#!/bin/bash -exu

# Limit what branch can be to avoid weird regex in the call to sed
branch=$(git rev-parse --abbrev-ref HEAD | grep -E '^[a-z0-9/-]+$' || printf "")
tag=
if [ -n "$branch" ]; then
    tag=$(git tag --points-at HEAD | sed -nE "s#^([0-9]{8}(-[0-9]+)?)_$branch\$#\\1#p" |
              sort --field-separator=- --key=1n,1 --key=2n,2 | tail -n1 || printf "")
fi
if [ -z "$tag" ]; then
    # Current date is the default if there are no date tags
    tag=$(/bin/date +%Y%m%d)
fi

printf "%s" "$tag"
