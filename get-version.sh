#!/bin/bash -ex

tag=$(git tag --points-at HEAD | grep -E '^[0-9]{8}(-[0-9]+)?$' |
          sort --field-separator=- --key=1n,1 --key=2n,2 | tail -n1 || printf "")
if [ -z "$tag" ]; then
    # Current date is the default if there are no date tags
    tag=$(/bin/date +%Y%m%d)
fi

printf "%s" "$tag"
