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
  base base-devel iwd linux-hardened linux-firmware-intel intel-ucode iptables ntpd-rs dnscrypt-proxy apparmor chromium tpm2-tss tpm2-tools erofs-utils \
  spotify-player mkinitcpio openssh pamixer fastfetch git unzip unrar pipewire-jack power-profiles-daemon python-gobject sof-firmware wireplumber pipewire-pulse pavucontrol \
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
systemctl mask efi.automount

mkdir /data/
rm -rf /var/*

echo 'tmpfs                      /var                      tmpfs  defaults,noexec,nosuid,nodev,mode=0755,size=256M                                                         0  0' >> /etc/fstab
echo 'tmpfs                      /tmp                      tmpfs  defaults,noexec,nosuid,nodev,mode=0755,size=256M                                                         0  0' >> /etc/fstab
echo '/dev/mapper/data           /data                     ext4   defaults,noexec,nosuid,nodev,noatime,x-systemd.device-timeout=30s                                        0  2' >> /etc/fstab
echo '/data/home                 /home                     none   bind,noexec,nosuid,nodev,x-systemd.requires-mounts-for=/data                                             0  0' >> /etc/fstab
echo '/data/var/lib/systemd/home /var/lib/systemd/home     none   bind,noexec,nosuid,nodev,x-systemd.requires-mounts-for=/data,x-systemd.requires-mounts-for=/var          0  0' >> /etc/fstab
echo '/data/var/lib/iwd          /var/lib/iwd              none   bind,noexec,nosuid,nodev,x-systemd.requires-mounts-for=/data,x-systemd.requires-mounts-for=/var          0  0' >> /etc/fstab
echo 'proc                	     /proc     	          proc   rw,nosuid,nodev,noexec,gid=26,hidepid=invisible	                                                    0  0' >> /etc/fstab

# TODO: Remove this.
echo "root:changeme" | chpasswd

echo -en "nameserver 127.0.0.1\noptions edns0 single-request-reopen" > /etc/resolv.conf
patch /etc/dnscrypt-proxy/dnscrypt-proxy.toml /etc/patch_dnscryptproxy_toml.patch

mkinitcpio -p linux-hardened || :

# passwd -l root   # TODO: Uncomment.
CHROOT

# EROFS image + dm-verity.
rm -f $OUTPUT
mkfs.erofs -L "${OS_BUILD_TAG}" -zlz4hc,12 -C65536 -Efragments,ztailpacking $OUTPUT $WORKDIR
VERITY_INFO=$(veritysetup format "$OUTPUT" "${OUTPUT}.verity")
VERITY_HASH=$(echo "$VERITY_INFO" | awk '/Root hash:/ {print $3}')
echo "EROFS image: $OUTPUT  |  Verity root hash: $VERITY_HASH"

CMDLINE="systemd.verity=1 roothash=${VERITY_HASH} systemd.verity_root_options=panic-on-corruption rd.emergency=reboot rd.shell=0 apparmor=1 security=apparmor lsm=landlock,lockdown,yama,integrity,apparmor,bpf slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 oops=panic intel_iommu=on iommu=force iommu.strict=1 iommu.passthrough=0 vsyscall=none pti=on spectre_v2=on mds=full,nosmt efi=disable_early_pci_dma spec_store_bypass_disable=on tsx=off tsx_async_abort=full,nosmt l1tf=full,force nosmt=force kvm.nx_huge_pages=force randomize_kstack_offset=on debugfs=off ipv6.disable=1 extra_latent_entropy modprobe.blacklist=thunderbolt  lockdown=confidentiality module.sig_enforce=1   i915.modeset=1 i915.enable_dpcd_backlight=3 i915.enable_guc=3 i915.force_probe=!5694 xe.force_probe=!5694 pcie_aspm.policy=powersupersave acpi.ec_no_wakeup=1 "

# Generate Unified Kernel Image
ukify build \
    --output "${WORKDIR}/boot/uki.efi" \
    --cmdline "${CMDLINE}" \
    --microcode "${WORKDIR}/boot/intel-ucode.img" \
    --linux "${WORKDIR}/boot/vmlinuz-linux-hardened" \
    --initrd "${WORKDIR}/boot/initramfs-linux-hardened.img"

rm ${WORKDIR}/boot/vmlinuz* ${WORKDIR}/boot/initramfs*

# Prepare signed bootloader, UKI and rootfs images.
mv /usr/lib/systemd/boot/efi/systemd-bootx64.efi /hardenedos/bootloader.efi
sbsign --key /tmp/sbsign/keys/db/db.key \
       --cert /tmp/sbsign/keys/db/db.pem \
       --output /hardenedos/bootloader-signed.efi /hardenedos/bootloader.efi

sbsign --key /tmp/sbsign/keys/db/db.key \
       --cert /tmp/sbsign/keys/db/db.pem \
       --output ${WORKDIR}/boot/uki-${OS_BUILD_TAG}-signed.efi ${WORKDIR}/boot/uki.efi