#!/bin/sh

set -eu

# This marker file is created by:
# snap set system users.lockout=true
! [ -f /etc/writable/account-locked.enable ]
