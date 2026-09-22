#!/bin/bash
# Launch an Android-x86 VM in QEMU with KVM acceleration.
#
# Why not waydroid: the Azure host kernel (6.8.0-1064-azure) ships neither the
# binder module nor binderfs, so waydroid can't run inside docker. A KVM VM
# sidesteps the kernel entirely - /dev/kvm is exposed to this container.
#
# First run boots the installer ISO; after Android is installed to the disk
# image, subsequent runs boot straight from disk (ISO becomes optional).
#
# Networking: user-mode NAT with hostfwd 5555 (adb) and 8022 (ssh-ish).
# Display: SDL window on the Plasma desktop (X11), virtio-gpu.

set -e

VM_DIR="/var/lib/android-vm"
DISK="$VM_DIR/android.img"
ISO_DIR="$VM_DIR"
ISO="$ISO_DIR/android-x86.iso"
ISO_URL="https://downloads.sourceforge.net/project/android-x86/Release%209.0/android-x86_64-9.0-r2.iso"
MEM="${ANDROID_VM_MEM:-2048}"
CPUS="${ANDROID_VM_CPUS:-2}"

mkdir -p "$VM_DIR"

# Create a 16G sparse disk on first run
if [ ! -f "$DISK" ]; then
  echo "[android-vm] creating 16G disk image (sparse)"
  qemu-img create -f qcow2 "$DISK" 16G
fi

# Download the installer ISO if missing (first run only; delete it after install)
if [ ! -f "$ISO" ]; then
  echo "[android-vm] downloading Android-x86 installer ISO (~900MB)"
  curl -fL --retry 3 -o "$ISO.part" "$ISO_URL" || {
    echo "[android-vm] automatic download failed (mirror URL changes often)."
    echo "  Manual: put an Android-x86 ISO at $ISO"
    exit 1
  }
  mv "$ISO.part" "$ISO"
fi

KVM_ARGS=()
if [ -w /dev/kvm ]; then
  KVM_ARGS=(-cpu host)
  ACCEL=kvm
else
  echo "[android-vm] WARNING: /dev/kvm not writable - running without KVM (slow)"
  KVM_ARGS=(-cpu max)
  ACCEL=tcg
fi

# After the user installs Android to the disk (installer -> "Create/Modify
# partitions" etc.), touch the marker file so later runs boot from disk.
BOOT_ARGS=()
CDROM_ARGS=(-cdrom "$ISO" -boot d)
if [ -f "$VM_DIR/.installed" ]; then
  echo "[android-vm] booting installed system from disk"
  CDROM_ARGS=()
elif [ -f "$DISK" ] && [ "$1" = "--installed" ]; then
  echo "[android-vm] --installed flag: marking install complete for next time"
  touch "$VM_DIR/.installed"
  CDROM_ARGS=()
fi

echo "[android-vm] starting QEMU: ${MEM}MB RAM, ${CPUS} vCPU, accel=$ACCEL"
exec qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  -smp "$CPUS" -m "$MEM" \
  -machine q35,accel=${ACCEL} \
  -device virtio-gpu-pci \
  -display sdl,gl=off \
  -device virtio-keyboard-pci \
  -device virtio-tablet-pci \
  -netdev user,id=net0,hostfwd=tcp::5555-:5555 \
  -device virtio-net-pci,netdev=net0 \
  -drive file="$DISK",if=virtio,format=qcow2 \
  "${CDROM_ARGS[@]}"
