#!/usr/bin/env bash
# Boot smoke test: install an image to a qcow2 with bootc-image-builder, boot it
# headless in QEMU/KVM and run checks.sh in it over SSH.
#
# Usage (as root, the image must be in root's podman storage):
#   tests/smoke/run.sh <image-ref>
#
# The test disk gets a `smoke` user with a throwaway SSH key, sshd enabled and
# journal warnings forwarded to the serial console through the kernel command
# line. None of this is in the image that is published.
#
# Env:
#   BIB_IMAGE     bootc-image-builder image (default from image-template.env)
#   WORK_DIR      output directory (default: output/smoke)
#   BOOT_TIMEOUT  seconds to wait for SSH (default 900)
#   VM_MEMORY     MiB (default 6144), VM_CPUS (default 2), SSH_PORT (default 2222)
#   KERNEL_ARGS   extra kernel arguments for the test disk, e.g. to inject a
#                 failing unit through a systemd.extra-unit.* credential

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <image-ref>" >&2
  exit 2
fi
IMAGE_REF="$1"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "${script_dir}/../.." && pwd)

if [[ -z "${BIB_IMAGE:-}" ]]; then
  BIB_IMAGE=$(sed -n 's/^BIB_IMAGE="\(.*\)"$/\1/p' "${repo_dir}/image-template.env")
fi
WORK_DIR="${WORK_DIR:-${repo_dir}/output/smoke}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"
VM_MEMORY="${VM_MEMORY:-6144}"
VM_CPUS="${VM_CPUS:-2}"
SSH_PORT="${SSH_PORT:-2222}"
KERNEL_ARGS="${KERNEL_ARGS:-}"

# Image reference without digest or tag, as used as key in policy.json.
POLICY_REF="${IMAGE_REF%@*}"
if [[ "${POLICY_REF##*/}" == *:* ]]; then
  POLICY_REF="${POLICY_REF%:*}"
fi

ovmf_code=""
ovmf_vars=""
for pair in \
  "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd" \
  "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"; do
  if [[ -f "${pair%%:*}" && -f "${pair##*:}" ]]; then
    ovmf_code="${pair%%:*}"
    ovmf_vars="${pair##*:}"
    break
  fi
done
if [[ -z "${ovmf_code}" ]]; then
  echo "No OVMF (UEFI) firmware found, install ovmf / edk2-ovmf." >&2
  exit 1
fi

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/bib"

echo "::group::Build qcow2 from ${IMAGE_REF}"
ssh-keygen -q -t ed25519 -N "" -C "dino-smoke-test" -f "${WORK_DIR}/id_ed25519"
{
  cat "${repo_dir}/disk_config/disk.toml"
  cat <<EOF

[[customizations.user]]
name = "smoke"
key = "$(cat "${WORK_DIR}/id_ed25519.pub")"
groups = ["wheel"]

[customizations.kernel]
append = "console=ttyS0 systemd.wants=sshd.service systemd.journald.forward_to_console=1 systemd.journald.max_level_console=warning${KERNEL_ARGS:+ ${KERNEL_ARGS}}"
EOF
} >"${WORK_DIR}/config.toml"

podman run \
  --rm \
  --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  --security-opt apparmor=unconfined \
  -v "${WORK_DIR}/config.toml:/config.toml:ro" \
  -v "${WORK_DIR}/bib:/output" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  "${BIB_IMAGE}" \
  --type qcow2 \
  --rootfs btrfs \
  --use-librepo=True \
  "${IMAGE_REF}"
echo "::endgroup::"

disk="${WORK_DIR}/bib/qcow2/disk.qcow2"
cp "${ovmf_vars}" "${WORK_DIR}/OVMF_VARS.fd"

qemu_pid=""
swtpm_pid=""
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
  for pid in "${qemu_pid}" "${swtpm_pid}"; do
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" || true
    fi
  done
}
trap cleanup EXIT

# Software TPM: DINO uses the TPM as Himmelblau's HSM (hsm_type = tpm), and
# himmelblaud (ordered before sshd and user logins) fails without one.
mkdir -p "${WORK_DIR}/tpm"
swtpm socket \
  --tpm2 \
  --tpmstate "dir=${WORK_DIR}/tpm" \
  --ctrl "type=unixio,path=${WORK_DIR}/tpm/swtpm.sock" \
  --pid "file=${WORK_DIR}/tpm/swtpm.pid" \
  --log "file=${WORK_DIR}/swtpm.log" \
  --daemon
swtpm_pid=$(<"${WORK_DIR}/tpm/swtpm.pid")

echo "Booting VM (serial log: ${WORK_DIR}/serial.log)"
qemu-system-x86_64 \
  -name dino-smoke \
  -machine q35,accel=kvm \
  -cpu host \
  -smp "${VM_CPUS}" \
  -m "${VM_MEMORY}" \
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=${ovmf_code}" \
  -drive "if=pflash,format=raw,unit=1,file=${WORK_DIR}/OVMF_VARS.fd" \
  -drive "file=${disk},if=virtio,format=qcow2" \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  -chardev "socket,id=chrtpm,path=${WORK_DIR}/tpm/swtpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-crb,tpmdev=tpm0 \
  -display none \
  -serial "file:${WORK_DIR}/serial.log" \
  -monitor "unix:${WORK_DIR}/monitor.sock,server,nowait" \
  -pidfile "${WORK_DIR}/qemu.pid" \
  -daemonize
qemu_pid=$(<"${WORK_DIR}/qemu.pid")

ssh_opts=(
  -i "${WORK_DIR}/id_ed25519"
  -p "${SSH_PORT}"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=5
)
# Screenshot of the VM console, to see where a boot got stuck.
screendump() {
  python3 - "${WORK_DIR}/monitor.sock" "${WORK_DIR}/screen.ppm" <<'PY' || true
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(f"screendump {sys.argv[2]}\n".encode())
time.sleep(2)
PY
}
vm_ssh() {
  # shellcheck disable=SC2029 # the commands are meant to run in the VM
  ssh "${ssh_opts[@]}" smoke@127.0.0.1 "$@"
}

boot_start=${SECONDS}
deadline=$((SECONDS + BOOT_TIMEOUT))
until vm_ssh true 2>/dev/null; do
  if ! kill -0 "${qemu_pid}" 2>/dev/null; then
    echo "QEMU exited before SSH came up. Last serial output:" >&2
    tail -n 100 "${WORK_DIR}/serial.log" >&2 || true
    exit 1
  fi
  if [[ ${SECONDS} -ge ${deadline} ]]; then
    echo "SSH did not come up within ${BOOT_TIMEOUT}s. Last serial output:" >&2
    tail -n 100 "${WORK_DIR}/serial.log" >&2 || true
    screendump
    exit 1
  fi
  sleep 10
done
echo "SSH is up $((SECONDS - boot_start))s after starting the VM."

allowed=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' \
  "${script_dir}/allowed-failed-units.txt" | awk '{print $1}' || true)

status=0
{
  printf 'ALLOWED_FAILED_UNITS=%q\n' "${allowed}"
  printf 'POLICY_REF=%q\n' "${POLICY_REF}"
  cat "${script_dir}/checks.sh"
} | vm_ssh bash -s || status=$?

# Keep the journal for debugging, whatever the result.
vm_ssh journalctl --boot --no-pager >"${WORK_DIR}/journal.log" 2>&1 || true

exit "${status}"
