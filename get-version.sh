#!/bin/bash -ex

git_date_tag() {
    tags=$(git tag --points-at HEAD || printf "")
    # We expect tags of format <date>-<sequence>. The sort commands orders them
    # first by date and then by sequence.
    while read -r tag; do
        if [[ ! "$tag" =~ ^[0-9]{8}(-[0-9]+)?$ ]]; then
            continue
        fi
        printf "%s\n" "$tag"
    done <<< "$tags" | sort --field-separator=- --key=1n,1 --key=2n,2 | tail -n1
}

tag=$(git_date_tag)
if [ -z "$tag" ]; then
    # Current date is the default if there are no date tags
    tag=$(/bin/date +%Y%m%d)
fi

printf "%s" "$tag"
