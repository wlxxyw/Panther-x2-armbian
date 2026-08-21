set -euo pipefail

validation="${GITHUB_WORKSPACE}/pantherx2-validation.txt"
exec > >(tee "${validation}") 2>&1

require_file() {
  local path="$1"
  local label="$2"
  if [[ ! -s "${path}" ]]; then
    echo "::error title=Missing firmware file::${label}: ${path}"
    return 1
  fi
  echo "OK file: ${label}"
}

require_line() {
  local path="$1"
  local expression="$2"
  local label="$3"
  if ! grep -Eq "${expression}" "${path}"; then
    echo "::error title=Firmware content mismatch::${label}"
    return 1
  fi
  echo "OK value: ${label}"
}

require_absent() {
  local path="$1"
  local label="$2"
  if [[ -e "${path}" || -L "${path}" ]]; then
    echo "::error title=Unexpected firmware file::${label}: ${path}"
    return 1
  fi
  echo "OK absent: ${label}"
}

expect_fdt_status() {
  local dtb="$1"
  local node="$2"
  local expected="$3"
  local actual
  actual="$(sudo fdtget -t s "${dtb}" "${node}" status 2>/dev/null || true)"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "::error title=DTB status mismatch::${node}: expected=${expected}, actual=${actual:-<missing>}"
    return 1
  fi
  echo "OK DTB status: ${node}=${actual}"
}

expect_fdt_hex() {
  local dtb="$1"
  local node="$2"
  local property="$3"
  local expected="$4"
  local actual
  actual="$(sudo fdtget -t x "${dtb}" "${node}" "${property}" 2>/dev/null || true)"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "::error title=DTB property mismatch::${node}/${property}: expected=${expected}, actual=${actual:-<missing>}"
    return 1
  fi
  echo "OK DTB property: ${node}/${property}=${actual}"
}

expect_fdt_string() {
  local dtb="$1"
  local node="$2"
  local property="$3"
  local expected="$4"
  local actual
  actual="$(sudo fdtget -t s "${dtb}" "${node}" "${property}" 2>/dev/null || true)"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "::error title=DTB property mismatch::${node}/${property}: expected=${expected}, actual=${actual:-<missing>}"
    return 1
  fi
  echo "OK DTB property: ${node}/${property}=${actual}"
}
backup_kernel(){
  local kernel_uname="$1"
  local platform="$2"
  local kernel_save_path="$3"

  if [[ -e "${kernel_save_path}" && ! -d "${kernel_save_path}" ]]; then
    echo "kernel_save_path exists but is not directory, remove: ${kernel_save_path}"
    rm -f "${kernel_save_path}"
  fi

  if [[ ! -d "${kernel_save_path}" ]]; then
    echo "create kernel_save_path: ${kernel_save_path}"
    mkdir -p "${kernel_save_path}"
  fi

  local kernel_tmp_path="$(mktemp -d)"
  cd ${kernel_tmp_path} || return 1
  echo "Backup kernel: ${kernel_uname}"
  #
  # backup boot
  #
  cp -rf "${mount_dir}/boot/"*-"${kernel_uname}" . || true
  # config-${kernel_uname} 已验证 不做处理， 补全其他文件
  if [[ -f "${mount_dir}/boot/initrd.img" && ! -f "initrd.img-${kernel_uname}" ]]; then
    cp -f "${mount_dir}/boot/initrd.img" "initrd.img-${kernel_uname}"
  fi
  if [[ -f "${mount_dir}/boot/uInitrd" && ! -f "uInitrd-${kernel_uname}" ]]; then
    cp -f "${mount_dir}/boot/uInitrd" "uInitrd-${kernel_uname}"
  fi
  if [[ -f "${mount_dir}/boot/System.map" && ! -f "System.map-${kernel_uname}" ]]; then
    cp -f "${mount_dir}/boot/System.map" "System.map-${kernel_uname}"
  fi
  if [[ -f "${mount_dir}/boot/Image" && ! -f "vmlinuz-${kernel_uname}" ]]; then
    cp -f "${mount_dir}/boot/Image" "vmlinuz-${kernel_uname}"
  fi
  tar -czf "${kernel_save_path}/boot-${kernel_uname}.tar.gz" .
  rm -rf *
  
  #
  # backup dtb
  #
  if [[ -d "${mount_dir}/boot/dtb/${platform}" ]]; then
    cp -rf "${mount_dir}/boot/dtb/${platform}/"* .
    tar -czf "${kernel_save_path}/dtb-${platform}-${kernel_uname}.tar.gz" .
    rm -rf *
  else
    echo "::error miss /boot/dtb/${platform}"
    return 1
  fi

  #
  # backup modules
  #
  if [[ -d "${mount_dir}/usr/lib/modules/${kernel_uname}" ]]; then
    cp -rf "${mount_dir}/usr/lib/modules/${kernel_uname}" .
    tar -czf "${kernel_save_path}/modules-${kernel_uname}.tar.gz" .
    rm -rf *
  else
    echo "::error miss /usr/lib/modules/${kernel_uname}"
    return 1
  fi

  #
  # checksum
  #
  cd "${kernel_save_path}"
  rm -rf "${kernel_tmp_path}"
  sha256sum *.tar.gz > sha256sums

  tar -czf "${kernel_save_path}/${kernel_uname}.tar.gz" sha256sums *.tar.gz
  find "${kernel_save_path}" -maxdepth 1  -type f  ! -name "${kernel_uname}.tar.gz"  -delete
  echo "Kernel backup done"
}

image="$(find /builder/build/output/images -maxdepth 1 -type f -name '*.img' -print -quit)"
if [[ -z "${image}" ]]; then
  echo '::error title=Missing firmware image::No .img file was generated'
  exit 1
fi

echo "Image: $(basename "${image}")"
sudo fdisk -l "${image}"

mount_dir="$(mktemp -d)"
loopdev=""
cleanup() {
  if mountpoint -q "${mount_dir}/boot"; then
    sudo umount "${mount_dir}/boot" || true
  fi
  if mountpoint -q "${mount_dir}"; then
    sudo umount "${mount_dir}" || true
  fi
  if [[ -n "${loopdev}" ]]; then
    sudo losetup --detach "${loopdev}" || true
  fi
  rmdir "${mount_dir}" || true
}
trap cleanup EXIT

loopdev="$(sudo losetup --find --partscan --show "${image}")"
for _ in {1..20}; do
  [[ -b "${loopdev}p1" && -b "${loopdev}p2" ]] && break
  sleep 1
done
if [[ ! -b "${loopdev}p1" || ! -b "${loopdev}p2" ]]; then
  echo "::error title=Partition discovery failed::Expected ${loopdev}p1 and ${loopdev}p2"
  lsblk "${loopdev}" || true
  exit 1
fi

sudo mount -o ro "${loopdev}p2" "${mount_dir}"
if [[ ! -d "${mount_dir}/boot" ]]; then
  echo '::error title=Root filesystem invalid::Missing /boot mount point'
  exit 1
fi
sudo mount -o ro "${loopdev}p1" "${mount_dir}/boot"

os_release="${mount_dir}/etc/os-release"
armbian_release="${mount_dir}/etc/armbian-release"
env_file="${mount_dir}/boot/armbianEnv.txt"
kernel_config="${mount_dir}/boot/config-6.1.115-vendor-rk35xx"
dtb="${mount_dir}/boot/dtb/rockchip/rk3566-panther-x2.dtb"

require_file "${os_release}" '/etc/os-release'
require_file "${armbian_release}" '/etc/armbian-release'
require_file "${mount_dir}/boot/Image" '/boot/Image'
require_file "${env_file}" '/boot/armbianEnv.txt'
require_file "${kernel_config}" 'kernel configuration'
require_file "${dtb}" 'Panther X2 DTB'
require_absent "${mount_dir}/etc/apt/sources.list.d/armbian.list" 'invalid Armbian APT source'
require_absent "${mount_dir}/etc/apt/sources.list.d/armbian.sources" 'invalid Armbian Deb822 APT source'

require_line "${os_release}" '^VERSION_ID="13"$' 'Debian version is 13'
require_line "${os_release}" '^VERSION_CODENAME=trixie$' 'Debian codename is Trixie'
require_line "${armbian_release}" '^BOARD=panther-x2-vendor$' 'Armbian board is Panther X2'
require_line "${armbian_release}" '^KERNEL_TARGET=vendor$' 'Kernel target is vendor'
require_line "${env_file}" '^fdtfile=rockchip/rk3566-panther-x2\.dtb$' 'Boot DTB is Panther X2'
require_line "${env_file}" '^extraargs=cma=256M$' 'CMA is 256 MiB'

require_line "${kernel_config}" '^CONFIG_ROCKCHIP_MULTI_RGA=y$' 'RGA driver enabled'
require_line "${kernel_config}" '^CONFIG_IEP=y$' 'IEP driver enabled'
require_line "${kernel_config}" '^CONFIG_ROCKCHIP_MPP_SERVICE=y$' 'MPP service enabled'
require_line "${kernel_config}" '^CONFIG_ROCKCHIP_MPP_RKVDEC2=y$' 'RKVDEC2 enabled'
require_line "${kernel_config}" '^CONFIG_ROCKCHIP_MPP_RKVENC=y$' 'RKVENC enabled'
require_line "${kernel_config}" '^CONFIG_ROCKCHIP_RKNPU=y$' 'RKNPU enabled'
require_line "${kernel_config}" '^CONFIG_MEDIA_USB_SUPPORT=y$' 'USB media support enabled'
require_line "${kernel_config}" '^CONFIG_USB_VIDEO_CLASS=y$' 'UVC camera driver enabled'
require_line "${kernel_config}" '^CONFIG_USB_XHCI_HCD=y$' 'XHCI host driver enabled'
require_line "${kernel_config}" '^CONFIG_USB_DWC3=y$' 'DWC3 controller driver enabled'

while IFS= read -r node; do
  expect_fdt_status "${dtb}" "${node}" okay
done <<'NODES'
/mpp-srv
/npu@fde40000
/bus-npu
/iommu@fde4b000
/vdpu@fdea0400
/iommu@fdea0800
/rk_rga@fdeb0000
/jpegd@fded0000
/iommu@fded0480
/vepu@fdee0000
/iommu@fdee0800
/iep@fdef0000
/iommu@fdef0800
/rkvenc@fdf40000
/iommu@fdf40f00
/rkvdec@fdf80200
/iommu@fdf80800
/usbdrd
/usbdrd/usb@fcc00000
/usb2-phy@fe8a0000
/usb2-phy@fe8a0000/otg-port
NODES

expect_fdt_status "${dtb}" /video-codec@fdea0400 disabled
expect_fdt_string "${dtb}" /usbdrd/usb@fcc00000 dr_mode host
expect_fdt_string "${dtb}" /usbdrd/usb@fcc00000 maximum-speed high-speed
expect_fdt_hex "${dtb}" /npu@fde40000 rknpu-supply 149
expect_fdt_string "${dtb}" /npu@fde40000 interrupt-names npu_irq
expect_fdt_hex "${dtb}" /bus-npu bus-supply 6b
expect_fdt_hex "${dtb}" /bus-npu pvtm-supply 5

grep -E '^(PRETTY_NAME|VERSION_ID|VERSION_CODENAME)=' "${os_release}"
grep -E '^(BOARD|BOARD_NAME|BOARDFAMILY|KERNEL_TARGET|VERSION)=' "${armbian_release}"
echo "Kernel config: $(basename "${kernel_config}")"
echo 'VPU/NPU/RGA/IEP image validation: passed'

backup_kernel "6.1.115-vendor-rk35xx" "rockchip" "/builder/build/output/kernel"
