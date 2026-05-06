#!/usr/bin/env bash
set -euo pipefail
: "${OS_BUILD_TAG:?OS_BUILD_TAG must be set}"

WORKDIR=/hardenedos/rootfs
OUTPUT=/hardenedos/rootfs.erofs

# Require root.
if [ "$EUID" -ne 0 ]; then echo "Be root!"; exit 1; fi

# Clean up previous work.
umount -R ${WORKDIR} 2>/dev/null || :
rm -rf $WORKDIR && mkdir -p $WORKDIR

# for pseudofs in proc sys dev; do mkdir -p ${WORKDIR}/${pseudofs}; mount -o bind /${pseudofs} ${WORKDIR}/${pseudofs}; done

BASE_DEVEL_WITHOUT_SUDO=$(LANG=en_US pacman -Sii base-devel | grep ^Depends | cut -d ':' -f2 | sed 's/sudo//g')
pacstrap -c -K $WORKDIR \
  base ${BASE_DEVEL_WITHOUT_SUDO} wpa_supplicant eza chromium gptfdisk linux-hardened linux-firmware-intel intel-ucode iptables less ntpd-rs dnscrypt-proxy apparmor tpm2-tss tpm2-tools erofs-utils \
  mkinitcpio opendoas openssh pamixer fastfetch git unzip unrar pipewire-jack power-profiles-daemon python-gobject sof-firmware wireplumber pipewire-pulse pavucontrol mtools dosfstools \
  bubblewrap-suid nmap flameshot slurp grim xdg-desktop-portal alacritty tmux yazi libnotify vulkan-validation-layers vulkan-icd-loader vulkan-headers vulkan-tools \
  jq yq patchutils helix helm kubectl nvim code checksec docker docker-compose age sops fluxcd kustomize opentofu pulumi azure-cli aws-cli spotify-player gurk \
  sway kanshi brightnessctl xdg-desktop-portal-wlr waybar mako swayidle swaylock swaybg fuzzel yazi adobe-source-code-pro-fonts ttf-jetbrains-mono otf-font-awesome
#   plasma-desktop systemsettings xdg-desktop-portal-kde kpipewire plasma-pa kscreen code adobe-source-code-pro-fonts ttf-jetbrains-mono

# Install Chromium from extra/testing (the maintainer takes too long to promote it to stable)
cp /etc/pacman.conf /tmp/pacman-custom.conf
sed -i '/\[extra-testing\]/,/^$/s/^#//' /tmp/pacman-custom.conf
pacstrap -C /tmp/pacman-custom.conf -c -K $WORKDIR extra-testing/chromium || echo "Error reinstalling Chromium from extra-testing/chromium. Maybe its latest version is not in extra-testing anymore."
rm /tmp/pacman-custom.conf

cp -r root_files/* ${WORKDIR}/

# arch-chroot sets up the bind mounts; no manual proc/sys/dev setup needed.
arch-chroot $WORKDIR /bin/bash -s <<'CHROOT'
set -euo pipefail

ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
locale-gen

systemctl daemon-reload
systemctl enable apparmor iptables wpa_supplicant-nl80211@wlo1 dnscrypt-proxy ntpd-rs systemd-networkd systemd-homed mydenyusb
systemctl disable systemd-timesyncd.service
systemctl mask efi.automount

mkdir /data/
rm -rf /var/*

echo 'proc                       /proc                     proc   rw,nosuid,nodev,noexec,gid=26,hidepid=invisible                                                          0  0' >> /etc/fstab
echo 'tmpfs                      /var                      tmpfs  defaults,noexec,nosuid,nodev,mode=0755,size=2G                                                           0  0' >> /etc/fstab
echo 'tmpfs                      /tmp                      tmpfs  defaults,noexec,nosuid,nodev,mode=0755,size=4G                                                           0  0' >> /etc/fstab
echo '/dev/mapper/data           /data                     ext4   defaults,noexec,nosuid,nodev,noatime,x-systemd.device-timeout=30s                                        0  2' >> /etc/fstab
echo '/data/home                 /home                     none   bind,noexec,nosuid,nodev,x-systemd.requires-mounts-for=/data                                             0  0' >> /etc/fstab
echo '/data/var/lib/systemd/home /var/lib/systemd/home     none   bind,noexec,nosuid,nodev,x-systemd.requires-mounts-for=/data,x-systemd.requires-mounts-for=/var          0  0' >> /etc/fstab
echo '/data/var/lib/docker       /var/lib/docker           none   bind,noexec,nosuid,nodev,x-systemd.requires-mounts-for=/data,x-systemd.requires-mounts-for=/var          0  0' >> /etc/fstab
echo '/data/var/lib/containerd   /var/lib/containerd       none   bind,noexec,nosuid,nodev,x-systemd.requires-mounts-for=/data,x-systemd.requires-mounts-for=/var          0  0' >> /etc/fstab
echo '/data/etc/wpa_supplicant   /etc/wpa_supplicant/      none   bind,noexec,nosuid,nodev,x-systemd.requires-mounts-for=/data,x-systemd.requires-mounts-for=/var          0  0' >> /etc/fstab

patch /etc/dnscrypt-proxy/dnscrypt-proxy.toml /etc/patch_dnscryptproxy_toml.patch
chmod +s /usr/local/bin/allow_new_usb_tmp

mkinitcpio -p linux-hardened || :

passwd -l root
CHROOT

rm -f ${WORKDIR}/etc/resolv.conf
echo -en "nameserver 127.0.0.1\noptions edns0 single-request-reopen" > ${WORKDIR}/etc/resolv.conf

# EROFS image + dm-verity.
rm -f $OUTPUT
rm -rf /tmp/boot_artifacts && mkdir /tmp/boot_artifacts && mv ${WORKDIR}/boot/* /tmp/boot_artifacts/
mkfs.erofs -L "${OS_BUILD_TAG}" -zlz4hc,12 -C65536 -Efragments,ztailpacking $OUTPUT $WORKDIR
VERITY_INFO=$(veritysetup format "$OUTPUT" "${OUTPUT}.verity")
VERITY_HASH=$(echo "$VERITY_INFO" | awk '/Root hash:/ {print $3}')
[ -n "$VERITY_HASH" ] || { echo "Failed to extract verity root hash"; exit 1; }
echo "EROFS image: $OUTPUT  |  Verity root hash: $VERITY_HASH"

CMDLINE="systemd.verity=1 roothash=${VERITY_HASH} systemd.verity_root_options=panic-on-corruption rd.emergency=reboot rd.shell=0 apparmor=1 security=apparmor lsm=landlock,lockdown,yama,integrity,apparmor,bpf slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 oops=panic intel_iommu=on iommu=force iommu.strict=1 iommu.passthrough=0 vsyscall=none pti=on spectre_v2=on mds=full,nosmt efi=disable_early_pci_dma spec_store_bypass_disable=on tsx=off tsx_async_abort=full,nosmt l1tf=full,force nosmt=force kvm.nx_huge_pages=force randomize_kstack_offset=on debugfs=off ipv6.disable=1 extra_latent_entropy modprobe.blacklist=thunderbolt  lockdown=confidentiality module.sig_enforce=1   i915.modeset=1 i915.enable_dpcd_backlight=3 i915.enable_guc=3 i915.force_probe=!5694 xe.force_probe=!5694 pcie_aspm.policy=powersupersave acpi.ec_no_wakeup=1 "

# Generate Unified Kernel Image
ukify build \
    --output "/tmp/boot_artifacts/uki.efi" \
    --cmdline "${CMDLINE}" \
    --microcode "/tmp/boot_artifacts/intel-ucode.img" \
    --linux "/tmp/boot_artifacts/vmlinuz-linux-hardened" \
    --initrd "/tmp/boot_artifacts/initramfs-linux-hardened.img"

# Prepare signed bootloader, UKI and rootfs images.
mv ${WORKDIR}/usr/lib/systemd/boot/efi/systemd-bootx64.efi /hardenedos/bootloader.efi
sbsign --key /tmp/sbsign/keys/db/db.key \
       --cert /tmp/sbsign/keys/db/db.pem \
       --output /hardenedos/bootloader-signed.efi /hardenedos/bootloader.efi

sbsign --key /tmp/sbsign/keys/db/db.key \
       --cert /tmp/sbsign/keys/db/db.pem \
       --output /hardenedos/uki-${OS_BUILD_TAG}-signed.efi /tmp/boot_artifacts/uki.efi


MANIFEST="/hardenedos/SHA256SUMS-${OS_BUILD_TAG}"
sha256sum "$OUTPUT" "${OUTPUT}.verity" /hardenedos/bootloader-signed.efi "/hardenedos/uki-${OS_BUILD_TAG}-signed.efi" | sed 's|/hardenedos/||g' > "$MANIFEST"
ssh-keygen -Y sign -f /tmp/sigkeys/manifest_sigkey -n hardenedos-build "$MANIFEST"

rm -rf /tmp/* /hardenedos/bootloader.efi