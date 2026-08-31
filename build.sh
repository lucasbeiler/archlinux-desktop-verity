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

BASE_DEVEL_WITHOUT_SUDO=$(LANG=en_US pacman -Sii base-devel | grep ^Depends | cut -d ':' -f2 | sed 's/sudo//g')
pacstrap -P -c -K $WORKDIR \
  base ${BASE_DEVEL_WITHOUT_SUDO} xdelta3 wpa_supplicant bluez bluez-utils chromium gptfdisk linux-hardened linux-firmware-intel intel-ucode iptables less ntpd-rs dnscrypt-proxy apparmor tpm2-tss tpm2-tools erofs-utils parted \
  mkinitcpio opendoas openssh pamixer fastfetch git unzip zip unrar power-profiles-daemon python-gobject sof-firmware wireplumber pipewire-pulse pavucontrol mtools dosfstools \
  bubblewrap nmap wl-clipboard slurp grim xdg-desktop-portal alacritty libnotify jq yq patchutils firecracker helix ollama tmux kubectl helm kustomize sops age checksec spotify-player \
  wayfire code waybar kanshi brightnessctl xdg-desktop-portal-wlr mako swayidle swaylock ttf-jetbrains-mono arch-repro-status rclone rsync

# Build and install roddhjav's apparmor.d profiles and GrapheneOS' hardened_malloc.
pacman -Sy --noconfirm just go git apparmor
id -u builder &>/dev/null || useradd -m builder
echo "builder ALL=(ALL) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/builder
su builder -s /bin/bash <<'EOF'
set -euo pipefail
# Declare variables.
APPARMOR_D_UPSTREAM_COMMIT=668eaca416ce46cfc8a7971d9bc7dba45833b4d5 # Update this to the commit hash last reviewed at https://github.com/roddhjav/apparmor.d
H_MALLOC_UPSTREAM_COMMIT=1976e09730897c49906dea4ce054ca937c47e0be   # Update this to the commit hash last reviewed at https://github.com/GrapheneOS/hardened_malloc

# Fetch apparmor.d.
git clone https://github.com/roddhjav/apparmor.d.git /tmp/apparmor.d
cd /tmp/apparmor.d
git checkout "$APPARMOR_D_UPSTREAM_COMMIT"

# Change some files.
p=$(find . -name dbus-system -type f)
sed -i '/@{att}@{run}\/systemd\/inhibit\/@{int}\.ref rw,/a \ \ @{att}@{run}/systemd/home/@{user}.dont-suspend rw,' "$p" # systemd-homed needs this!
sed -i '/abi <abi\/5.0>,/a \ \ /etc/tunables.conf r,' apparmor.d/abstractions/glibc # Latest glibc introduced /etc/tunables.conf
rm -rf apparmor.d/groups/filesystem/mtools apparmor.d/groups/ssh apparmor.d/profiles-g-l/git apparmor.d/groups/procps # Delete policies related to mtools, ssh, git and procps (at least for now...)

# Build apparmor.d.
GOFLAGS="-buildmode=pie -trimpath -ldflags=-linkmode=external -mod=readonly -modcacherw" \
DISTRIBUTION=arch \
GOPATH=/tmp/apparmor.d/.gopath \
just enforce
just destdir="/tmp/apparmor.d-out" install

# Fetch and build hardened_malloc.
rm -rf /tmp/hardened_malloc
git clone https://github.com/grapheneos/hardened_malloc /tmp/hardened_malloc
cd /tmp/hardened_malloc
git checkout "$H_MALLOC_UPSTREAM_COMMIT"
rm -rf out/*
make clean 
make

## Uncomment this when I get to compile Trivalent myself (because Trivalent does not have Reproducible Builds!)
# mkdir -p /tmp/trivalent
# cd /tmp/trivalent
# curl -L -O "https://repo.secureblue.dev/Packages/trivalent-151.0.7922.71-446359.x86_64.rpm"
# bsdtar -xf trivalent-151.0.7922.71-446359.x86_64.rpm
# sed -i 's/\[0-9\].so/[0-9]-arch[0-9].[0-9].so/' "etc/trivalent/trivalent.conf"
# mkdir -p usr/lib
# cp -a usr/lib64/* usr/lib/
# rm -rf usr/lib64
# rm -f *.rpm
EOF
rm -rf /tmp/apparmor.d-out/usr/bin/
cp /tmp/hardened_malloc/out/libhardened_malloc.so "${WORKDIR}/usr/lib/"
cp -a /tmp/apparmor.d-out/. "${WORKDIR}/"
# cp -a /tmp/trivalent/. "${WORKDIR}/"

# Try reinstalling Chromium from extra/testing (the maintainer usually takes too long to promote new releases to stable, and browser updates are important).
cp /etc/pacman.conf /tmp/pacman-custom.conf
sed -i '/\[extra-testing\]/,/^$/s/^#//' /tmp/pacman-custom.conf
pacstrap -C /tmp/pacman-custom.conf -c -K $WORKDIR extra-testing/chromium || echo "Error reinstalling Chromium from extra-testing/chromium. Maybe its latest version is not in extra-testing anymore."
rm /tmp/pacman-custom.conf

# Set a DNS nameserver (NOTE: it is overwritten later on to point to the dnscrypt-proxy socket, so this is temporary).
echo 'nameserver 9.9.9.9' > ${WORKDIR}/etc/resolv.conf

# Save information about how much (and which ones) of the installed packages passed Reproducible Builds tests or not.
arch-chroot $WORKDIR /bin/bash -c 'mkdir -p /usr/share/archlinux-desktop-verity/ && arch-repro-status > /usr/share/archlinux-desktop-verity/arch-repro-status-report.txt 2>&1 || :'

# Copy my system files and configuration to the rootfs.
cp -r root_files/* ${WORKDIR}/

# Finish system setup.
# arch-chroot sets up the bind mounts, so no manual proc/sys/dev setup needed.
arch-chroot $WORKDIR /bin/bash -s <<'CHROOT'
set -euo pipefail

# The system uses UTC! Set your timezone by exporting the TZ environment variable in your .bashrc.
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
locale-gen

# TODO: The wireless network interface (wlo1) should not be hardcoded like this.
systemctl daemon-reload
systemctl enable apparmor iptables wpa_supplicant-nl80211@wlo1 dnscrypt-proxy ntpd-rs systemd-networkd systemd-homed mydenyusb updater.timer firecracker-net-setup.service
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
echo '/data/var/lib/bluetooth    /var/lib/bluetooth        none   bind,noexec,nosuid,nodev,x-systemd.requires-mounts-for=/data,x-systemd.requires-mounts-for=/var          0  0' >> /etc/fstab
echo '/data/etc/wpa_supplicant   /etc/wpa_supplicant/      none   bind,noexec,nosuid,nodev,x-systemd.requires-mounts-for=/data,x-systemd.requires-mounts-for=/var          0  0' >> /etc/fstab
patch /etc/dnscrypt-proxy/dnscrypt-proxy.toml /etc/patch_dnscryptproxy_toml.patch

# Prepare AppArmor locals.
mkdir -p /etc/apparmor.d/local/
RULES='
/usr/lib/chromium/chrome-sandbox rPx,
/home/*/.config/ r,
/home/*/.config/chromium-flags.conf r,
/etc/chromium/ r,
/etc/chromium/policies/ r,
/etc/chromium/policies/managed/ r,
/etc/chromium/policies/managed/** r,
deny /etc/ld.so.preload r,
'
echo "$RULES" >> /etc/apparmor.d/local/chromium
echo "$RULES" >> /etc/apparmor.d/local/chromium-wrapper
echo "capability sys_ptrace," >> /etc/apparmor.d/local/chromium-sandbox
echo "ptrace read peer=chromium," >> /etc/apparmor.d/local/chromium-sandbox
echo "deny /etc/ld.so.preload r," >> /etc/apparmor.d/local/chromium-sandbox
echo "/etc/ca-certificates/extracted/cadir/ r,"   >> /etc/apparmor.d/local/wpa-supplicant
echo "/etc/ca-certificates/extracted/cadir/** r," >> /etc/apparmor.d/local/wpa-supplicant
echo "/etc/ssl/certs/ r," >> /etc/apparmor.d/local/wpa-supplicant
echo "/etc/ssl/certs/** r," >> /etc/apparmor.d/local/wpa-supplicant

# Compile AppArmor earlypolicy cache.
mkdir -p /etc/apparmor/earlypolicy
apparmor_parser -Q -W --features-file=/etc/linux-hardened.features -L /etc/apparmor/earlypolicy /etc/apparmor.d

# Disable the root user.
passwd -l root
CHROOT

# EROFS image + dm-verity.
rm -f $OUTPUT
rm -rf /tmp/boot_artifacts && mkdir /tmp/boot_artifacts && mv ${WORKDIR}/boot/* /tmp/boot_artifacts/
mkfs.erofs -L "${OS_BUILD_TAG}" -zlz4hc,12 -C65536 -Efragments,ztailpacking $OUTPUT $WORKDIR
VERITY_INFO=$(veritysetup format "$OUTPUT" "${OUTPUT}.verity")
VERITY_HASH=$(echo "$VERITY_INFO" | awk '/Root hash:/ {print $3}')
[ -n "$VERITY_HASH" ] || { echo "Failed to extract verity root hash"; exit 1; }
echo "EROFS image: $OUTPUT  |  Verity root hash: $VERITY_HASH"

# --- DELTA UPDATE SUPPORT -------------------------------------------------
DELTA_DIR=/tmp/delta_build
mkdir -p "$DELTA_DIR"

PREV_TAGS="$(curl -sL https://api.github.com/repos/lucasbeiler/archlinux-desktop-verity/releases \
  | grep -oE 'os-[0-9]{12}' \
  | sort -u \
  | grep -v "^os-${OS_BUILD_TAG}\$" \
  | sort \
  | tail -n3 | tr -d 'os-')"

DELTA_FILES=""
if [ -n "$PREV_TAGS" ]; then
  echo "Previous releases found for delta generation:"
  echo "$PREV_TAGS"
  for PREV_TAG_FULL in $PREV_TAGS; do
    PREV_TAG="${PREV_TAG_FULL#os-}"
    PREV_URL="https://github.com/lucasbeiler/archlinux-desktop-verity/releases/download/${PREV_TAG_FULL}"
    PREV_EROFS="${DELTA_DIR}/prev-rootfs-${PREV_TAG}.erofs"

    if curl -L -f --progress-bar -o "$PREV_EROFS" "${PREV_URL}/rootfs.erofs"; then
      DELTA_FILE="${DELTA_DIR}/rootfs-${PREV_TAG}-to-${OS_BUILD_TAG}.xdelta"
      xdelta3 -e -9 -S -s "$PREV_EROFS" "$OUTPUT" "$DELTA_FILE"
      echo "Delta generated: $(basename "$DELTA_FILE") ($(du -h "$DELTA_FILE" | cut -f1))"
      DELTA_FILES="$DELTA_FILES $DELTA_FILE"
    else
      echo "Warning: could not download rootfs for ${PREV_TAG_FULL}, skipping delta." >&2
    fi
    rm -f "$PREV_EROFS"
  done
else
  echo "No previous releases found, skipping delta generation."
fi

mkdir -p ${WORKDIR}/etc/ipe_setup/
cat > ${WORKDIR}/etc/ipe_setup/hardened.policy <<EOF
policy_name=hardened policy_version=0.0.0

DEFAULT action=DENY

op=EXECUTE  dmverity_roothash=sha256:$VERITY_HASH action=ALLOW
op=EXECUTE  boot_verified=TRUE action=ALLOW
op=KMODULE  dmverity_roothash=sha256:$VERITY_HASH action=ALLOW
op=KMODULE  boot_verified=TRUE action=ALLOW
op=FIRMWARE dmverity_roothash=sha256:$VERITY_HASH action=ALLOW
op=FIRMWARE boot_verified=TRUE action=ALLOW
EOF

openssl smime -sign \
  -in ${WORKDIR}/etc/ipe_setup/hardened.policy \
  -signer /tmp/sbsign/keys/db/db.pem \
  -inkey /tmp/sbsign/keys/db/db.key \
  -noattr -nodetach -nosmimecap \
  -outform der \
  -out ${WORKDIR}/etc/ipe_setup/hardened.policy.p7b

# Rebuild initramfs now that the signed policy exists inside $WORKDIR,
mv /tmp/boot_artifacts/* ${WORKDIR}/boot/
mkdir -p ${WORKDIR}/usr/lib/systemd/system/
cat > "${WORKDIR}/usr/lib/systemd/system/ipe-policy.service" <<'EOF'
[Unit]
Description=Load and activate hardened IPE policy in initramfs

[Service]
Type=oneshot
ExecStart=/usr/bin/sh -ec 'cat /etc/ipe_setup/hardened.policy.p7b > /sys/kernel/security/ipe/new_policy && echo 1 > /sys/kernel/security/ipe/policies/hardened/active'
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
arch-chroot $WORKDIR mkinitcpio -p linux-hardened || :

# The first mkinitcpio run's output was already moved to /tmp/boot_artifacts
# ... overwrite it with the one that actually contains the signed IPE policy.
mv ${WORKDIR}/boot/* /tmp/boot_artifacts/

CMDLINE="systemd.verity=1 roothash=${VERITY_HASH} systemd.verity_root_options=panic-on-corruption rd.emergency=reboot rd.shell=0 apparmor=1 security=apparmor lsm=landlock,lockdown,yama,integrity,apparmor,bpf,ipe ipe.enforce=1 slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 oops=panic intel_iommu=on iommu=force iommu.strict=1 iommu.passthrough=0 vsyscall=none pti=on spectre_v2=on mds=full,nosmt efi=disable_early_pci_dma spec_store_bypass_disable=on tsx=off tsx_async_abort=full,nosmt l1tf=full,force nosmt=force kvm.nx_huge_pages=force randomize_kstack_offset=on debugfs=off ipv6.disable=1 extra_latent_entropy modprobe.blacklist=thunderbolt  lockdown=confidentiality module.sig_enforce=1   i915.modeset=1 i915.enable_dpcd_backlight=3 i915.enable_guc=3 i915.force_probe=!5694 xe.force_probe=!5694 pcie_aspm.policy=powersupersave acpi.ec_no_wakeup=1 "

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

for DELTA_FILE in $DELTA_FILES; do
  [ -f "$DELTA_FILE" ] && mv "$DELTA_FILE" "/hardenedos/$(basename "$DELTA_FILE")"
done

MANIFEST="/hardenedos/SHA256SUMS-${OS_BUILD_TAG}"
(
  cd -- "$(dirname -- "$OUTPUT")" || exit 1
  sha256sum \
    "$(basename -- "$OUTPUT")" \
    "$(basename -- "${OUTPUT}.verity")" \
    bootloader-signed.efi \
    "uki-${OS_BUILD_TAG}-signed.efi" \
    $(for f in $DELTA_FILES; do [ -f "/hardenedos/$(basename "$f")" ] && basename "$f"; done)
) > "$MANIFEST"
ssh-keygen -Y sign -f /tmp/sigkeys/manifest_sigkey -n hardenedos-build "$MANIFEST"

rm -rf /tmp/* /hardenedos/bootloader.efi
