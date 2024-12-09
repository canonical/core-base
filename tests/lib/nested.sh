#!/bin/bash

WORK_DIR="${WORK_DIR:-/tmp/work-dir}"
SSH_PORT=${SSH_PORT:-8022}
MON_PORT=${MON_PORT:-8888}
IMAGE_FILE="${WORK_DIR}/ubuntu-core-24.img"

execute_remote(){
    sshpass -p ubuntu ssh -p "$SSH_PORT" -o ServerAliveInterval=60 -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@localhost "$*"
}

wait_for_ssh(){
    local service_name="$1"
    retry=1800
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
  retry=400
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

cleanup_nested_core_vm(){
    # stop the VM if it is running
    systemctl stop nested-vm-*

    if [ "${ENABLE_TPM:-false}" = "true" ]; then
        if [ -d "/tmp/qtpm" ]; then
            rm -rf /tmp/qtpm
        fi

        # remove the swtpm
        # TODO: we could just remove/reset the swtpm instead of removing the snap 
        # wholesale
        snap remove test-snapd-swtpm
    fi

    # delete the image file
    rm -rf "${IMAGE_FILE}"
}

print_nested_status(){
    SVC_NAME="nested-vm-$(systemd-escape "${SPREAD_JOB:-unknown}")"
    systemctl status "${SVC_NAME}" || true
    journalctl -u "${SVC_NAME}" || true
}

nested_is_secure_boot_enabled() {
    if [ -n "$ENABLE_SECURE_BOOT" ]; then
        [ "$ENABLE_SECURE_BOOT" = true ]
    else
        case "${SPREAD_SYSTEM:-}" in
            ubuntu-1*)
                return 1
                ;;
            ubuntu-2*)
                # secure boot enabled by default on 20.04 and later
                return 0
                ;;
            *)
                echo "unsupported system"
                exit 1
                ;;
        esac
    fi
}

start_nested_core_vm_unit(){
    # copy the image file to create a new one to use
    # TODO: maybe create a snapshot qcow image instead?
    mkdir -p "${WORK_DIR}"
    cp "${SETUPDIR}/pc.img" "${IMAGE_FILE}"

    # use only 2G of RAM for qemu-nested
    # the caller can override PARAM_MEM
    local PARAM_MEM PARAM_SMP
    if [ "$SPREAD_BACKEND" = "google-nested" ] || [ "$SPREAD_BACKEND" = "google-nested-arm" ]; then
        PARAM_MEM="-m ${NESTED_MEM:-4096}"
        PARAM_SMP="-smp ${NESTED_CPUS:-2}"
    elif [ "$SPREAD_BACKEND" = "google-nested-dev" ]; then
        PARAM_MEM="-m ${NESTED_MEM:-8192}"
        PARAM_SMP="-smp ${NESTED_CPUS:-4}"
    elif [ "$SPREAD_BACKEND" = "qemu-nested" ]; then
        PARAM_MEM="-m ${NESTED_MEM:-2048}"
        PARAM_SMP="-smp ${NESTED_CPUS:-1}"
    else
        echo "unknown spread backend $SPREAD_BACKEND"
        exit 1
    fi

    PARAM_DISPLAY="-nographic"
    PARAM_NETWORK="-net nic,model=virtio -net user,hostfwd=tcp::${SSH_PORT}-:22"
    # TODO: do we need monitor port still?
    PARAM_MONITOR="-monitor tcp:127.0.0.1:${MON_PORT},server=on,wait=off"
    PARAM_RANDOM="-object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0"
    PARAM_CPU=""
    PARAM_TRACE="-d cpu_reset"
    PARAM_LOG="-D ${WORK_DIR}/qemu.log"
    PARAM_TPM=""
    
    # Open port 7777 on the host so that failures in the nested VM (e.g. to
    # create users) can be debugged interactively via
    # "telnet localhost 7777". Also keeps the logs
    PARAM_SERIAL="-chardev socket,telnet=on,host=localhost,server=on,port=7777,wait=off,id=char0,logfile=${WORK_DIR}/serial.log,logappend=on -serial chardev:char0"

    local OVMF_CODE OVMF_VARS
    OVMF_CODE=""
    OVMF_VARS=""

    # for core22+
    wget -q https://storage.googleapis.com/snapd-spread-tests/dependencies/OVMF_CODE.secboot.fd
    mv OVMF_CODE.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd
    wget -q https://storage.googleapis.com/snapd-spread-tests/dependencies/OVMF_VARS.snakeoil.fd
    mv OVMF_VARS.snakeoil.fd /usr/share/OVMF/OVMF_VARS.snakeoil.fd
    wget -q https://storage.googleapis.com/snapd-spread-tests/dependencies/OVMF_VARS.ms.fd
    mv OVMF_VARS.ms.fd /usr/share/OVMF/OVMF_VARS.ms.fd

    # In this case the kernel.efi is unsigned and signed with snaleoil certs
    if [ "${ENABLE_OVMF_SNAKEOIL:-false}" = "true" ]; then
        OVMF_VARS=".snakeoil"
    else
        OVMF_VARS=".ms"
    fi

    if nested_is_secure_boot_enabled; then
        OVMF_CODE=".secboot"
    fi

    mkdir -p "${WORK_DIR}/image/"
    if os.query is-pc-amd64; then
        ATTR_KVM=""
        if [ "$ENABLE_KVM" = "true" ]; then
            ATTR_KVM=",accel=kvm"
            # CPU can be defined just when kvm is enabled
            PARAM_CPU="-cpu host"
        fi
        
        QEMU_BIN=qemu-system-x86_64
        PARAM_MACHINE="-machine q35${ATTR_KVM} -global ICH9-LPC.disable_s3=1"
        PARAM_BIOS="-drive file=/usr/share/OVMF/OVMF_CODE${OVMF_CODE}.fd,if=pflash,format=raw,unit=0,readonly=on -drive file=${WORK_DIR}/image/OVMF_VARS${OVMF_VARS}.fd,if=pflash,format=raw"
        TPM_DEVICE=tpm-tis
        cp -f "/usr/share/OVMF/OVMF_VARS${OVMF_VARS}.fd" "${WORK_DIR}/image/OVMF_VARS${OVMF_VARS}.fd"
    elif os.query is-arm64; then
        # Assume arm64
        # Unfortunately gce does not offer kvm enabled arm64 VMs
        PARAM_CPU="-cpu cortex-a57"
        QEMU_BIN=qemu-system-aarch64
        PARAM_MACHINE="-machine virt"
        PARAM_BIOS="-drive file=/usr/share/AAVMF/AAVMF_CODE.fd,if=pflash,format=raw,unit=0,readonly=on -drive file=${WORK_DIR}/image/AAVMF_VARS.fd,if=pflash,format=raw"
        TPM_DEVICE=tpm-tis-device
        cp -f "/usr/share/AAVMF/AAVMF_VARS.fd" "${WORK_DIR}/image/AAVMF_VARS.fd"
    else
        printf "ERROR: unsupported archtecture\n"
        exit 1
    fi

    # Unfortunately the test-snapd-swtpm snap does not work correctly in lxd container. It's not possible
    # for the socket to come up due to being containerized.
    if [ "${ENABLE_TPM:-false}" = "true" ]; then
        TPMSOCK_PATH="/var/snap/test-snapd-swtpm/current/swtpm-sock"
        if [ "${SPREAD_BACKEND}" = "lxd-nested" ]; then
            mkdir -p /tmp/qtpm
            swtpm socket --tpmstate dir=/tmp/qtpm --ctrl type=unixio,path=/tmp/qtpm/sock --tpm2 -d -t
            TPMSOCK_PATH="/tmp/qtpm/sock"
        else
            if snap list test-snapd-swtpm >/dev/null; then
                if [ -z "$TPM_NO_RESTART" ]; then
                    # reset the tpm state
                    snap stop test-snapd-swtpm > /dev/null
                    rm /var/snap/test-snapd-swtpm/current/tpm2-00.permall || true
                    snap start test-snapd-swtpm > /dev/null
                fi
            else
                snap install test-snapd-swtpm --edge
            fi
            
            # wait for the tpm sock file to exist
            retry -n 10 --wait 1 test -S /var/snap/test-snapd-swtpm/current/swtpm-sock
            PARAM_TPM="-chardev socket,id=chrtpm,path=/var/snap/test-snapd-swtpm/current/swtpm-sock -tpmdev emulator,id=tpm0,chardev=chrtpm"
            if os.query is-arm; then
                PARAM_TPM="$PARAM_TPM -device tpm-tis-device,tpmdev=tpm0"
            else
                PARAM_TPM="$PARAM_TPM -device tpm-tis,tpmdev=tpm0"
            fi
            snap install test-snapd-swtpm --beta
            retry=60
            while ! test -S /var/snap/test-snapd-swtpm/current/swtpm-sock; do
                retry=$(( retry - 1 ))
                if [ $retry -le 0 ]; then
                    echo "Timed out waiting for the swtpm socket. Aborting!"
                    return 1
                fi
                sleep 1
            done
        fi
    fi

    PARAM_IMAGE="-drive file=${IMAGE_FILE},cache=none,format=raw,id=disk1,if=none -device virtio-blk-pci,drive=disk1,bootindex=1"

    SVC_NAME="nested-vm-$(systemd-escape "${SPREAD_JOB:-unknown}")"
    # shellcheck disable=SC2086
    if ! systemd-run --service-type=simple --unit="${SVC_NAME}" -- \
         "$QEMU_BIN" \
                ${PARAM_SMP} \
                ${PARAM_CPU} \
                ${PARAM_MEM} \
                ${PARAM_TRACE} \
                ${PARAM_LOG} \
                ${PARAM_MACHINE} \
                ${PARAM_DISPLAY} \
                ${PARAM_NETWORK} \
                ${PARAM_BIOS} \
                ${PARAM_TPM} \
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
        return 1
    fi
}
