#!/bin/bash

set -e
set -x 

apt update -qq

# these should already be installed in GCE and LXD images with the google/lxd-nested 
# backend, but in qemu local images from qemu-nested, we might not have them
apt install snapd ovmf qemu-system-x86 sshpass whois -yqq

snap install snapcraft --classic
snap install ubuntu-image --classic

# get the model
curl -o ubuntu-core-amd64-dangerous.model https://raw.githubusercontent.com/snapcore/models/master/ubuntu-core-$UC_VERSION-amd64-dangerous.model

# download neccessary images
snap download pc-kernel --channel=$UC_VERSION/$SNAP_BRANCH --basename=upstream-pc-kernel
snap download pc --channel=$UC_VERSION/$SNAP_BRANCH --basename=upstream-pc-gadget
snap download snapd --channel=$SNAP_BRANCH --basename=upstream-snapd

# create test user for spread to use
groupadd --gid 12345 test
adduser --uid 12345 --gid 12345 --disabled-password --gecos '' test

if getent group systemd-journal >/dev/null; then
    usermod -G systemd-journal -a test
    id test | MATCH systemd-journal
fi

echo 'test ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# next repack / modify the snaps we use in the image, we do this for a few 
# reasons:
# 1. we need an automated way to get a user on the system to ssh into regardless
#    of grade, so we add a systemd service to the snapd snap which will create 
#    our user we can ssh into the VM with (if we only wanted to test dangerous,
#    we could use cloud-init).

# first re-pack snapd snap with special systemd service which runs during run 
# mode to create a user for us to inspect the system state

snapddir=/tmp/snapd-workdir
unsquashfs -d $snapddir upstream-snapd.snap

# inject systemd service to setup users and other tweaks for us
# these are copied from upstream snapd prepare.sh, slightly modified to not 
# extract snapd spread data from ubuntu-seed as we don't need all that here
cat > "$snapddir/lib/systemd/system/snapd.spread-tests-run-mode-tweaks.service" <<'EOF'
[Unit]
Description=Tweaks to run mode for spread tests
Before=snapd.service
Documentation=man:snap(1)
[Service]
Type=oneshot
ExecStart=/usr/lib/snapd/snapd.spread-tests-run-mode-tweaks.sh
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
EOF

cat > "$snapddir/usr/lib/snapd/snapd.spread-tests-run-mode-tweaks.sh" <<'EOF'
#!/bin/sh
set -e
# Print to kmsg and console
# $1: string to print
print_system()
{
    printf "%s spread-tests-run-mode-tweaks.sh: %s\n" "$(date -Iseconds --utc)" "$1" |
        tee -a /dev/kmsg /dev/console /run/mnt/ubuntu-seed/spread-tests-run-mode-tweaks-log.txt || true
}
# ensure we don't enable ssh in install mode or spread will get confused
if ! grep 'snapd_recovery_mode=run' /proc/cmdline; then
    print_system "not in run mode - script not running"
    exit 0
fi
if [ -e /root/spread-setup-done ]; then
    print_system "already ran, not running again"
    exit 0
fi
print_system "in run mode, not run yet, extracting overlay data"
# extract data from previous stage
(cd / && tar xf /run/mnt/ubuntu-seed/run-mode-overlay-data.tar.gz)
cp -r /root/test-var/lib/extrausers /var/lib
# user db - it's complicated
for f in group gshadow passwd shadow; do
    # now bind mount read-only those passwd files on boot
    cat >/etc/systemd/system/etc-"$f".mount <<EOF2
[Unit]
Description=Mount root/test-etc/$f over system etc/$f
Before=ssh.service
[Mount]
What=/root/test-etc/$f
Where=/etc/$f
Type=none
Options=bind,ro
[Install]
WantedBy=multi-user.target
EOF2
    systemctl enable etc-"$f".mount
    systemctl start etc-"$f".mount
done
mkdir -p /home/test
chown 12345:12345 /home/test
mkdir -p /home/ubuntu
chown 1000:1000 /home/ubuntu
mkdir -p /etc/sudoers.d/
echo 'test ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/99-test-user
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/99-ubuntu-user
# TODO: do we need this for our nested VM? We don't login as root to the nested
#       VM...
sed -i 's/\#\?\(PermitRootLogin\|PasswordAuthentication\)\>.*/\1 yes/' /etc/ssh/sshd_config
echo "MaxAuthTries 120" >> /etc/ssh/sshd_config
grep '^PermitRootLogin yes' /etc/ssh/sshd_config
systemctl reload ssh
print_system "done setting up ssh for spread test user"
touch /root/spread-setup-done
EOF
chmod 0755 "$snapddir/usr/lib/snapd/snapd.spread-tests-run-mode-tweaks.sh"

snap pack --filename=snapd.snap "$snapddir"
rm -r $snapddir

# run snapcraft
(
    cd "$SETUPDIR"
    snapcraft --destructive-mode
)

# finally build the uc image
printf -v date '%(%Y%m%d)T' -1
ubuntu-image snap \
    -i 8G \
    --snap core${UC_VERSION}_${date}_amd64.snap \
    --snap snapd.snap \
    --snap upstream-pc-kernel.snap \
    --snap upstream-pc-gadget.snap \
    ubuntu-core-amd64-dangerous.model

# setup some data we will inject into ubuntu-seed partition of the image above
# that snapd.spread-tests-run-mode-tweaks.service will ingest

# this sets up some /etc/passwd and group magic that ensures the test and ubuntu
# users are working, mostly copied from snapd spread magic
mkdir -p /root/test-etc
# NOTE that we don't use the real extrausers db on the host VM here because that
# could be used to actually login to the L1 VM, which we don't want to allow, so
# put it in a fake dir that login() doesn't actually look at for the host L1 VM.
mkdir -p /root/test-var/lib/extrausers
touch /root/test-var/lib/extrausers/sub{uid,gid}
for f in group gshadow passwd shadow; do
    # don't include the ubuntu user here, we manually add that later on
    grep -v "^root:" /etc/"$f" | grep -v "^ubuntu:" /etc/"$f" > /root/test-etc/"$f"
    grep "^root:" /etc/"$f" >> /root/test-etc/"$f"
    chgrp --reference /etc/"$f" /root/test-etc/"$f"
    # append test user for testing
    grep "^test:" /etc/"$f" >> /root/test-var/lib/extrausers/"$f"
    # check test was copied
    MATCH "^test:" < /root/test-var/lib/extrausers/"$f"
done

# TODO: could we just do this in the script above with adduser --extrausers and
# echo ubuntu:ubuntu | chpasswd ?
# dynamically create the ubuntu user in our fake extrausers with password of 
# ubuntu
#shellcheck disable=SC2016
echo 'ubuntu:$6$5jPdGxhc$8DgCHDdjj9IQxefS9atknQq4JVVYqy6KiPV/p4fDf5NUI6dqKTAf0vUZNx8FUru/pNgOQMwSMzS5pFj3hp4pw.:18492:0:99999:7:::' >> /root/test-var/lib/extrausers/shadow
#shellcheck disable=SC2016
echo 'ubuntu:$6$5jPdGxhc$8DgCHDdjj9IQxefS9atknQq4JVVYqy6KiPV/p4fDf5NUI6dqKTAf0vUZNx8FUru/pNgOQMwSMzS5pFj3hp4pw.:18492:0:99999:7:::' >> /root/test-etc/shadow
echo 'ubuntu:!::' >> /root/test-var/lib/extrausers/gshadow
# use gid of 1001 in case sometimes the lxd group sneaks into the extrausers image somehow...
echo "ubuntu:x:1000:1001:Ubuntu:/home/ubuntu:/bin/bash" >> /root/test-var/lib/extrausers/passwd
echo "ubuntu:x:1000:1001:Ubuntu:/home/ubuntu:/bin/bash" >> /root/test-etc/passwd
echo "ubuntu:x:1001:" >> /root/test-var/lib/extrausers/group

# add the test user to the systemd-journal group if it isn't already
sed -r -i -e 's/^systemd-journal:x:([0-9]+):$/systemd-journal:x:\1:test/' /root/test-etc/group

# mount fresh image and add all our SPREAD_PROJECT data
# for the lxd backend this step is a bit different as the device mapper kernel module
# is not supported by lxd containers. We thus have to do some manual setup of the image
# partition mount.
if [ "${SPREAD_BACKEND}" = "lxd-nested" ]; then
    devloop=$(losetup -f)
    partoffset=$(fdisk -lu pc.img | awk '/EFI System$/ {print $2}')
    losetup $devloop pc.img -o $(($partoffset * 512))
    mkdir /mnt/p2
    mount $devloop /mnt/p2

    # add the data that snapd.spread-tests-run-mode-tweaks.service reads to the 
    # mounted partition
    tar -c -z \
        -f /mnt/p2/run-mode-overlay-data.tar.gz \
        /root/test-etc /root/test-var/lib/extrausers

    umount /mnt/p2
    losetup -d $devloop
else
    kpartx -avs pc.img
    # losetup --list --noheadings returns:
    # /dev/loop1   0 0  1  1 /var/lib/snapd/snaps/ohmygiraffe_3.snap                0     512
    # /dev/loop57  0 0  1  1 /var/lib/snapd/snaps/http_25.snap                      0     512
    # /dev/loop19  0 0  1  1 /var/lib/snapd/snaps/test-snapd-netplan-apply_75.snap  0     512
    devloop=$(losetup --list --noheadings | grep pc.img | awk '{print $1}')
    dev=$(basename "$devloop")

    # mount it so we can use it now
    mkdir -p /mnt
    mount "/dev/mapper/${dev}p2" /mnt

    # add the data that snapd.spread-tests-run-mode-tweaks.service reads to the 
    # mounted partition
    tar -c -z \
        -f /mnt/run-mode-overlay-data.tar.gz \
        /root/test-etc /root/test-var/lib/extrausers

    # tear down the mounts
    umount /mnt
    kpartx -d pc.img
fi

# the image is now ready to be booted
