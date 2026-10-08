#!/usr/bin/env bash
set -euo pipefail

PIXEL5_MODE="${PIXEL5_MODE:-baseline}"
case "$PIXEL5_MODE" in baseline|next) ;; *) printf 'Invalid build mode\n' >&2; exit 2;; esac
PIXEL5_ROOT="$(pwd)"
PIXEL5_ARTIFACTS="$PIXEL5_ROOT/pixel5-artifacts"
PIXEL5_SRC="$PIXEL5_ROOT/pixel5-source"
mkdir -p "$PIXEL5_ARTIFACTS" "$PIXEL5_SRC"
exec > >(tee "$PIXEL5_ARTIFACTS/build.log") 2>&1

printf 'mode=%s\nbranch=%s\nstock_kernel_commit=%s\nLTO=%s\n' \
  "$PIXEL5_MODE" android-msm-redbull-4.19-android14 7b0944645172 full \
  > "$PIXEL5_ARTIFACTS/build-info.txt"

git config --global user.name 'Pixel 5 Build'
git config --global user.email 'pixel5-build@users.noreply.github.com'
curl --fail --location --retry 3 https://storage.googleapis.com/git-repo-downloads/repo \
  --output "$PIXEL5_ROOT/repo"
chmod +x "$PIXEL5_ROOT/repo"
cd "$PIXEL5_SRC"
"$PIXEL5_ROOT/repo" init -u https://android.googlesource.com/kernel/manifest \
  -b android-msm-redbull-4.19-android14 --no-clone-bundle
"$PIXEL5_ROOT/repo" sync -c -j4 --no-tags --fail-fast --no-clone-bundle

git -C private/msm-google checkout --detach 7b0944645172
"$PIXEL5_ROOT/repo" manifest -r -o "$PIXEL5_ARTIFACTS/manifest.lock.xml"
git -C private/msm-google rev-parse HEAD >> "$PIXEL5_ARTIFACTS/build-info.txt"

# The supplied stock kernel has CONFIG_LTO_CLANG=y and THINLTO disabled.
# Google's development wrapper selects thin LTO; keep the stock full-LTO mode.
python3 - <<'LTO_PY'
from pathlib import Path
p=Path('private/msm-google/build_redbull-gki.sh')
s=p.read_text()
if s.count('LTO=thin') != 1:
    raise SystemExit('Unexpected LTO wrapper; review source before building')
p.write_text(s.replace('LTO=thin', 'LTO=full'))
LTO_PY

if [ "$PIXEL5_MODE" = next ]; then
  cd private/msm-google
  git clone --depth 1 --branch v1.1.1 \
    https://github.com/KernelSU-Next/KernelSU-Next.git KernelSU-Next
  git -C KernelSU-Next rev-parse HEAD >> "$PIXEL5_ARTIFACTS/build-info.txt"
  ln -s ../KernelSU-Next/kernel drivers/kernelsu
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
  printf '\nsource "drivers/kernelsu/Kconfig"\n' >> drivers/Kconfig
  patch --batch --fuzz=0 -p1 < "$PIXEL5_ROOT/tools/pixel5-clean/ksun_hooks_4.19.patch"
  scripts/config --file arch/arm64/configs/redbull-gki_defconfig \
    -e KSU -d KSU_KPROBES_HOOK -d KSU_DEBUG
  # Retain the production update_config step; the intentional KSU config
  # additions cannot pass a comparison against the unmodified defconfig.
  python3 - <<'CONFIG_PY'
from pathlib import Path
p=Path('build.config.redbull.vintf')
s=p.read_text()
expected='POST_DEFCONFIG_CMDS="check_defconfig && update_config"'
if expected not in s:
    raise SystemExit('Unexpected defconfig check; review source before building')
p.write_text(s.replace(expected, 'POST_DEFCONFIG_CMDS="update_config"'))
CONFIG_PY
  cd "$PIXEL5_SRC"
fi

export OUT_DIR="$PIXEL5_ROOT/pixel5-kernel-out"
export DIST_DIR="$PIXEL5_ROOT/pixel5-kernel-dist"
BUILD_AOSP_KERNEL=1 bash ./build_redbull-gki.sh -j"$(nproc)"

python3 - "$PIXEL5_MODE" "$OUT_DIR" "$DIST_DIR" "$PIXEL5_ARTIFACTS" <<'VERIFY_PY'
from pathlib import Path
import sys, shutil, hashlib
mode,out,dist,art=sys.argv[1],Path(sys.argv[2]),Path(sys.argv[3]),Path(sys.argv[4])
configs=list(out.glob('**/private/msm-google/.config'))
if len(configs) != 1:
    raise SystemExit(f'Expected one msm-google .config, found {configs}')
config=configs[0].read_text()
for flag in ['CONFIG_LTO_CLANG=y','CONFIG_CFI_CLANG=y','CONFIG_MODVERSIONS=y']:
    if flag not in config.splitlines():
        raise SystemExit(f'Missing required stock setting: {flag}')
if 'CONFIG_THINLTO=y' in config.splitlines():
    raise SystemExit('ThinLTO enabled unexpectedly')
if mode == 'baseline':
    if 'CONFIG_KSU=y' in config.splitlines() or 'CONFIG_KSU=m' in config.splitlines():
        raise SystemExit('Baseline unexpectedly contains KernelSU')
else:
    if 'CONFIG_KSU=y' not in config.splitlines():
        raise SystemExit('KernelSU was not compiled in')
    if 'CONFIG_KSU_KPROBES_HOOK=y' in config.splitlines():
        raise SystemExit('Do not combine the manual hooks with kprobe hooks')
    if 'CONFIG_KSU_SUSFS=y' in config.splitlines():
        raise SystemExit('SUSFS is not part of the clean test build')
kernel=dist/'Image.lz4'
if not kernel.is_file() or kernel.stat().st_size < 1000000:
    raise SystemExit('No compiled Image.lz4; do not use a prebuilt or boot.img instead')
shutil.copy2(kernel,art/'Image.lz4')
shutil.copy2(configs[0],art/'kernel.config')
for name in ['System.map','Module.symvers','vmlinux.symvers','abi_symbollist.raw']:
    p=dist/name
    if not p.is_file(): p=configs[0].parent/name
    if p.is_file(): shutil.copy2(p,art/name)
with (art/'SHA256SUMS.txt').open('w') as f:
    for p in sorted(art.iterdir()):
        if p.is_file() and p.name not in ['build.log','SHA256SUMS.txt']:
            f.write(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n')
print('Verified compiled kernel, CFI, full LTO, and build mode.')
VERIFY_PY
