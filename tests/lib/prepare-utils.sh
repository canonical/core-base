#!/bin/bash

set -e
set -x 

SSH_PORT=${SSH_PORT:-8022}
MON_PORT=${MON_PORT:-8888}

execute_remote(){
    sshpass -p ubuntu ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no test@localhost "$*"
}

wait_for_ssh(){
    local service_name="$1"
    retry=400
    wait=1
    while ! execute_remote true; do
        if ! systemctl is-active "$service_name"; then
            echo "Service no longer active"
            systemctl status "${service_name}" || true
            return 1
        fi

        retry=$(( retry - 1 ))
        if [ $retry -le 0 ]; then
            echo "Timed out waiting for ssh. Aborting!"
            return 1
        fi
        sleep "$wait"
    done
}

install_core_initrd_deps() {
    local project_dir="$1"

    # needed for dracut which is a build-dep of ubuntu-core-initramfs
    # and for the version of snapd here which we want to use to pull snap-bootstrap
    # from when we build the debian package
    sudo add-apt-repository ppa:snappy-dev/image -y
    sudo apt update -qq
    sudo apt upgrade -yqq

    # these are already installed in the lxd image which speeds things up, but they
    # are missing in qemu and google images.
    sudo apt install initramfs-tools-core psmisc fdisk snapd mtools ovmf qemu-system-x86 sshpass whois openssh-server -yqq

    # use the snapd snap explicitly
    # TODO: since ubuntu-image ships it's own version of `snap prepare-image`, 
    # should we instead install beta/edge snapd here and point ubuntu-image to this
    # version of snapd?
    # TODO: https://bugs.launchpad.net/snapd/+bug/1712808
    # There is a bug in snapd that prevents udev rules from reloading in privileged containers
    # with the following error message: 'cannot reload udev rules: exit status 1' when installing
    # snaps. However it seems that retrying the installation fixes it
    if ! sudo snap install snapd; then
        echo "FIXME: snapd install failed, retrying"
        sudo snap install snapd
    fi
    sudo snap install ubuntu-image --classic
}

build_core_initrd() {
    local project_dir="$1"
    local current_dir="$(pwd)"
    
    # build the debian package of ubuntu-core-initramfs
    (
        cd "$project_dir"
        sudo apt update -qq
        sudo apt upgrade -yqq
        sudo apt -y build-dep ./

        DEB_BUILD_OPTIONS='nocheck testkeys' dpkg-buildpackage -tc -b -Zgzip

        # save our debs somewhere safe
        cp ../*.deb "$current_dir"
    )
}

inject_initramfs() {
    # extract the kernel snap, including extracting the initrd from the kernel.efi
    kerneldir="$(mktemp --tmpdir -d kernel-workdirXXXXXXXXXX)"
    trap 'rm -rf "${kerneldir}"' EXIT

    unsquashfs -f -d "${kerneldir}" upstream-pc-kernel.snap
    (
        cd "${kerneldir}"
        config="$(echo config-*)"
        kernelver="${config#config-}"
        objcopy -O binary -j .linux kernel.efi kernel.img-"${kernelver}"
        ubuntu-core-initramfs create-initrd --kerneldir modules/"${kernelver}" --kernelver "${kernelver}" --firmwaredir firmware --output ubuntu-core-initramfs.img
        ubuntu-core-initramfs create-efi --initrd ubuntu-core-initramfs.img --kernel kernel.img --output kernel.efi --kernelver "${kernelver}"
        mv "kernel.efi-${kernelver}" kernel.efi
        rm kernel.img-"${kernelver}"
        rm ubuntu-core-initramfs.img-"${kernelver}"
    )

    snap pack --filename=pc-kernel.snap "${kerneldir}"
}

nested_wait_for_snap_command(){
  retry=800
  wait=1
  while ! execute_remote command -v snap; do
      retry=$(( retry - 1 ))
      if [ $retry -le 0 ]; then
          echo "Timed out waiting for snap command to be available. Aborting!"
          exit 1
      fi
      sleep "$wait"
  done
}

cleanup_snapd_core_vm(){
    # stop the VM if it is running
    systemctl stop nested-vm
}

start_snapd_core_vm() {
    local work_dir="$1"

    # Do not enable SMP on GCE as it will cause boot issues. There is most likely
    # a bug in the combination of the kernel version used in GCE images, combined with
    # a new qemu version (v6) and OVMF
    # TODO try again to enable more cores in the future to see if it is fixed
    PARAM_MEM="-m 4096"
    PARAM_SMP="-smp 1"
    PARAM_DISPLAY="-nographic"
    PARAM_NETWORK="-net nic,model=virtio -net user,hostfwd=tcp::${SSH_PORT}-:22"
    # TODO: do we need monitor port still?
    PARAM_MONITOR="-monitor tcp:127.0.0.1:${MON_PORT},server,nowait"
    PARAM_RANDOM="-object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0"
    PARAM_CPU=""
    PARAM_TRACE="-d cpu_reset"
    PARAM_LOG="-D ${work_dir}/qemu.log"
    PARAM_SERIAL="-serial file:${work_dir}/serial.log"
    PARAM_TPM=""

    ATTR_KVM=""
    if [ "$ENABLE_KVM" = "true" ]; then
        ATTR_KVM=",accel=kvm"
        # CPU can be defined just when kvm is enabled
        PARAM_CPU="-cpu host"
    fi

    mkdir -p "${work_dir}/image/"
    cp -f "/usr/share/OVMF/OVMF_VARS.fd" "${work_dir}/image/OVMF_VARS.fd"
    PARAM_BIOS="-drive file=/usr/share/OVMF/OVMF_CODE.fd,if=pflash,format=raw,unit=0,readonly=on -drive file=${work_dir}/image/OVMF_VARS.fd,if=pflash,format=raw"
    PARAM_MACHINE="-machine q35${ATTR_KVM} -global ICH9-LPC.disable_s3=1"
    PARAM_IMAGE="-drive file=${work_dir}/pc.img,cache=none,format=raw,id=disk1,if=none -device virtio-blk-pci,drive=disk1,bootindex=1"

    SVC_NAME="nested-vm"
    if ! sudo systemd-run --service-type=simple --unit="${SVC_NAME}" -- \
                qemu-system-x86_64 \
                ${PARAM_SMP} \
                ${PARAM_CPU} \
                ${PARAM_MEM} \
                ${PARAM_TRACE} \
                ${PARAM_LOG} \
                ${PARAM_MACHINE} \
                ${PARAM_DISPLAY} \
                ${PARAM_NETWORK} \
                ${PARAM_BIOS} \
                ${PARAM_RANDOM} \
                ${PARAM_IMAGE} \
                ${PARAM_SERIAL} \
                ${PARAM_MONITOR}; then
        echo "Failed to start ${SVC_NAME}" 1>&2
        systemctl status "${SVC_NAME}" || true
        return 1
    fi

    # Wait until ssh is ready
    if ! wait_for_ssh "${SVC_NAME}"; then
        echo "===== SERIAL PORT OUTPUT ======" 1>&2
        cat "${work_dir}/serial.log" 1>&2
        echo "===== END OF SERIAL PORT OUTPUT ======" 1>&2
        return 1
    fi

    # Wait for the snap command to become ready
    nested_wait_for_snap_command
}

get_core_snap_name() {
    printf -v date '%(%Y%m%d)T' -1
    echo "core22_${date}_amd64.snap"
}

install_core22_deps() {
    sudo apt update -qq

    # these should already be installed in GCE and LXD images with the google/lxd-nested 
    # backend, but in qemu local images from qemu-nested, we might not have them
    sudo apt install psmisc fdisk snapd mtools ovmf qemu-system-x86 sshpass whois -yqq

    # TODO: https://bugs.launchpad.net/snapd/+bug/1712808
    # There is a bug in snapd that prevents udev rules from reloading in privileged containers
    # with the following error message: 'cannot reload udev rules: exit status 1' when installing
    # snaps. However it seems that retrying the installation fixes it
    if ! sudo snap install snapcraft --classic; then
        echo "FIXME: snapcraft install failed, retrying"
        sudo snap install snapcraft --classic
    fi
    sudo snap install ubuntu-image --classic
}

download_core22_snaps() {
    local snap_branch="$1"

    # get the model
    curl -o ubuntu-core-amd64-dangerous.model https://raw.githubusercontent.com/snapcore/models/master/ubuntu-core-22-amd64-dangerous.model

    # download neccessary images
    snap download pc-kernel --channel=22/${snap_branch} --basename=upstream-pc-kernel
    snap download pc --channel=22/${snap_branch} --basename=upstream-pc-gadget
    snap download snapd --channel=${snap_branch} --basename=upstream-snapd
}

# create two new users that used during testing when executing
# snapd tests, external for the external backend, and 'test'
# for the snapd test setup
create_cloud_init_cdimage_config() {
    local CONFIG_PATH=$1
    cat << 'EOF' > "$CONFIG_PATH"
#cloud-config
datasource_list: [NoCloud]
users:
  - name: external
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    plain_text_passwd: 'ubuntu'
  - name: test
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    plain_text_passwd: 'ubuntu'
    uid: "12345"

EOF
}

prepare_core22_cloudinit() {
    # unpack gadget
    gadgetdir=/tmp/gadget-workdir
    unsquashfs -d $gadgetdir upstream-pc-gadget.snap

    # add the cloud.conf to the gadget
    create_cloud_init_cdimage_config "${gadgetdir}/cloud.conf"

    # repack kernel snap
    rm upstream-pc-gadget.snap
    snap pack --filename=upstream-pc-gadget.snap "$gadgetdir"
    rm -r $gadgetdir
}

build_core22_snap() {
    local project_dir="$1"
    local current_dir="$(pwd)"
    
    # run snapcraft
    (
        cd "$project_dir"
        sudo snapcraft --destructive-mode

        # copy the snap to the calling directory if they are not the same
        if [ "$project_dir" != "$current_dir" ]; then
            cp "$(get_core_snap_name)" "$current_dir"
        fi
    )
}

build_core22_image() {
    local core_snap_name="$(get_core_snap_name)"
    ubuntu-image snap \
        -i 8G \
        --snap $core_snap_name \
        --snap upstream-snapd.snap \
        --snap pc-kernel.snap \
        --snap upstream-pc-gadget.snap \
        ubuntu-core-amd64-dangerous.model
}
