#!/bin/bash

set -e
set -x

SSH_PORT=${SSH_PORT:-8022}
MON_PORT=${MON_PORT:-8888}

execute_remote(){
    sshpass -p ubuntu ssh -p "$SSH_PORT" -o ServerAliveInterval=60 -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no test@localhost "$*"
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
    cp -f "/usr/share/OVMF/OVMF_VARS_4M.fd" "${work_dir}/image/OVMF_VARS_4M.fd"
    PARAM_BIOS="-drive file=/usr/share/OVMF/OVMF_CODE_4M.fd,if=pflash,format=raw,unit=0,readonly=on -drive file=${work_dir}/image/OVMF_VARS_4M.fd,if=pflash,format=raw"
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

get_arch() {
    if os.query is-pc-amd64; then
        printf amd64
    elif os.query is-arm64; then
        printf arm64
    else
        printf "ERROR: unsupported archtecture\n"
        exit 1
    fi
}

get_core_snap_name() {
    printf -v date '%(%Y%m%d)T' -1
    echo "core26_${date}_$(get_arch).snap"
}

install_base_deps() {
    sudo apt-get update -qq

    # these should already be installed in GCE and LXD images with the google/lxd-nested 
    # backend, but in qemu local images from qemu-nested, we might not have them
    sudo apt-get install psmisc fdisk snapd mtools ovmf qemu-system-x86 sshpass whois -yqq

    # TODO: https://bugs.launchpad.net/snapd/+bug/1712808
    # There is a bug in snapd that prevents udev rules from reloading in privileged containers
    # with the following error message: 'cannot reload udev rules: exit status 1' when installing
    # snaps. However it seems that retrying the installation fixes it
    if ! sudo snap install snapcraft --channel="${SNAPCRAFT_CHANNEL:-latest/stable}" --classic; then
        echo "FIXME: snapcraft install failed, retrying"
        sudo snap install snapcraft --channel="${SNAPCRAFT_CHANNEL:-latest/stable}" --classic
    fi
    sudo snap install lxd
    sudo lxd init --auto
    sudo snap install ubuntu-image --classic --channel=latest/edge
}

download_core26_snaps() {
    # FIXME: there is no reason to select a branch when the model is
    # hard coded.
    local snap_branch="$1"

    # get the model
    curl -o ubuntu-core-dangerous.model https://raw.githubusercontent.com/snapcore/models/master/ubuntu-core-26-$(get_arch)-dangerous.model

    case "${snap_branch}" in
        edge)
            # dangerous/edge models use beta branch for the kernel
            # snap
            kernel_branch=beta
            ;;
        *)
            kernel_branch="${snap_branch}"
            ;;
    esac

    # download neccessary images
    snap download pc-kernel --channel=26/"${kernel_branch}" --basename=upstream-pc-kernel
    snap download pc --channel=26/${snap_branch} --basename=upstream-pc-gadget
    snap download snapd --channel=${snap_branch} --basename=upstream-snapd
}

# create two new users that used during testing when executing
# snapd tests, external for the external backend, and 'test'
# for the snapd test setup
create_cloud_init_cdimage_config() {
    local CONFIG_PATH=$1
    cat << 'EOF' > "$CONFIG_PATH"
#cloud-config
datasource_list: [NoCloud,None]
users:
  - name: external
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    plain_text_passwd: 'ubuntu123'
  - name: test
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    plain_text_passwd: 'ubuntu'
    uid: "12345"

EOF
}

prepare_base_cloudinit() {
    # unpack gadget
    gadgetdir=/tmp/gadget-workdir
    unsquashfs -d $gadgetdir upstream-pc-gadget.snap

    # add the cloud.conf to the gadget
    create_cloud_init_cdimage_config "${gadgetdir}/cloud.conf"

    # add extra debug params to kernel command line
    printf "systemd.journald.forward_to_console=1 console=ttyS0\n" > $gadgetdir/cmdline.extra

    # repack kernel snap
    rm upstream-pc-gadget.snap
    snap pack --filename=upstream-pc-gadget.snap "$gadgetdir"
    rm -r $gadgetdir
}

build_base_snap() {
    local project_dir="$1"
    local current_dir="$(pwd)"
    
    # run snapcraft
    (
        cd "$project_dir"
        snapcraft --verbosity verbose

        # copy the snap to the calling directory if they are not the same
        if [ "$project_dir" != "$current_dir" ]; then
            cp "$(get_core_snap_name)" "$current_dir"
        fi
    )
}

build_base_image() {
    local core_snap_name="$(get_core_snap_name)"
    ubuntu-image snap \
        -i 8G \
        --snap $core_snap_name \
        --snap upstream-snapd.snap \
        --snap upstream-pc-kernel.snap \
        --snap upstream-pc-gadget.snap \
        ubuntu-core-dangerous.model
}
