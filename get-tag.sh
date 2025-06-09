#!/bin/bash -ex

# tags are returned in lexicographical order, so dates are ordered but sequence
# numbers are not (that is, we will have 20250101-11 before 20250101-2), so we
# need to look for the max seq number for the last date in the list.
tags=$(git tag --points-at HEAD || printf "")
# Current date is the default if there are no date tags
date_last=$(/bin/date +%Y%m%d)
last_tag="$date_last"
seq_last=0
while read -r tag; do
    if [[ ! "$tag" =~ ^[0-9]{8}(-[0-9]+)?$ ]]; then
        continue
    fi

    date_tag=${tag%-*}
    seq_tag=${tag#*-}
    # In case there is no sequence number, seq_tag will also have the date
    if [ "$seq_tag" = "$tag" ]; then
        seq_tag=0
    fi

    # moved to next date, reset
    if [ "$date_tag" != "$date_last" ]; then
        seq_last="$seq_tag"
        last_tag="$tag"
    fi
    date_last="$date_tag"
    if [ "$seq_tag" -gt "$seq_last" ]; then
        seq_last="$seq_tag"
        last_tag="$tag"
    fi
done <<< "$tags"

printf "$last_tag"
