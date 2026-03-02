#!/usr/bin/env bash
set -euo pipefail

# Architecture and mirror.
ARCH=$(uname -m)
WORKDIR=/hardenedos/rootfs
OUTPUT=/hardenedos/rootfs.erofs

# Require root.
if [ "$EUID" -ne 0 ]; then echo "Be root!"; exit 1; fi

# Clean up previous work.
umount -R ${WORKDIR} 2>/dev/null || :
rm -rf $WORKDIR && mkdir -p $WORKDIR

# for pseudofs in proc sys dev; do mkdir -p ${WORKDIR}/${pseudofs}; mount -o bind /${pseudofs} ${WORKDIR}/${pseudofs}; done

pacstrap -c -K $WORKDIR \
  base base-devel iwd linux-hardened linux-firmware-intel iptables ntpd-rs dnscrypt-proxy apparmor chromium tpm2-tss tpm2-tools erofs-utils \
  spotify-player dracut openssh pamixer fastfetch git unzip unrar pipewire-jack power-profiles-daemon python-gobject sof-firmware wireplumber pipewire-pulse pavucontrol \
  bubblewrap-suid nmap arch-repro-status flameshot slurp grim xdg-desktop-portal alacritty libnotify vulkan-validation-layers vulkan-icd-loader vulkan-headers vulkan-tools \
  sway kanshi xdg-desktop-portal-wlr swayidle swaylock swaybg fuzzel yazi
  # plasma-desktop systemsettings xdg-desktop-portal-kde kpipewire plasma-pa kscreen 

cp -r root_files/* ${WORKDIR}/

# arch-chroot sets up the bind mounts; no manual proc/sys/dev setup needed.
arch-chroot $WORKDIR /bin/bash -s <<'CHROOT'
set -euo pipefail

ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
echo "computer" > /etc/hostname
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# TODO: Make Flatpak's sandbox a bit stronger using overrides and AppArmor.
# flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
# flatpak --system install -y flathub com.spotify.Client
# flatpak --system install -y flathub org.signal.Signal
# flatpak --system install -y flathub org.gnome.Fractal

systemctl daemon-reload
systemctl enable apparmor iptables iwd dnscrypt-proxy ntpd-rs systemd-homed mydenyusb da-lockout-clear-tpm
systemctl disable systemd-timesyncd.service

dracut -f --uefi --regenerate-all

# passwd -l root   # TODO: Uncomment.
CHROOT

# EROFS image + dm-verity.
rm -f $OUTPUT
mkfs.erofs -L "${OS_BUILD_TAG}" -zlz4hc,12 -C65536 -Efragments,ztailpacking $OUTPUT $WORKDIR
VERITY_INFO=$(veritysetup format "$OUTPUT" "${OUTPUT}.verity")
VERITY_HASH=$(echo "$VERITY_INFO" | awk '/Root hash:/ {print $3}')
echo "$VERITY_HASH" | tee ${WORKDIR}/verityhash
echo "EROFS image: $OUTPUT  |  Verity root hash: $VERITY_HASH"

sbsign --key  /tmp/sbsign/keys/db/db.key \
       --cert /tmp/sbsign/keys/db/db.pem \
       --output /hardenedos/bootloader-signed.efi \
       $WORKDIR/usr/lib/systemd/boot/efi/systemd-bootx64.efi

sbsign --key  /tmp/sbsign/keys/db/db.key \
       --cert /tmp/sbsign/keys/db/db.pem \
       --output ${WORKDIR}/boot/uki-${OS_BUILD_TAG}-signed.efi \
       ${WORKDIR}/boot/EFI/Linux/linux*hardened*.efi

echo "Done. Signed UKI: ${WORKDIR}/boot/uki-${OS_BUILD_TAG}-signed.efi"