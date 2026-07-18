#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENGINE_DIR=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
WORKSPACE=${WORKSPACE:-/workspace}
VULKAN_BUILD_ROOT=${VULKAN_BUILD_ROOT:-/out/vulkan}
BUILD_JOBS=${BUILD_JOBS:-$(nproc)}
TOOLCHAIN_FILE=${TOOLCHAIN_FILE:-${WORKSPACE}/external/qemu/android/build/cmake/toolchain-linux-aarch64.cmake}

HEADERS_SOURCE=${WORKSPACE}/external/vulkan-headers
LOADER_SOURCE=${WORKSPACE}/external/vulkan-loader
SWIFTSHADER_SOURCE=${WORKSPACE}/external/swiftshader
HEADERS_BUILD=${VULKAN_BUILD_ROOT}/headers-build
HEADERS_INSTALL=${VULKAN_BUILD_ROOT}/headers-install
LOADER_BUILD=${VULKAN_BUILD_ROOT}/loader-build
LOADER_INSTALL=${VULKAN_BUILD_ROOT}/loader-install
SWIFTSHADER_BUILD=${VULKAN_BUILD_ROOT}/swiftshader-build
PROBE_OUTPUT=${VULKAN_BUILD_ROOT}/vulkan-smoke

for required in \
  "${HEADERS_SOURCE}/CMakeLists.txt" \
  "${LOADER_SOURCE}/CMakeLists.txt" \
  "${SWIFTSHADER_SOURCE}/CMakeLists.txt" \
  "${TOOLCHAIN_FILE}" \
  "${ENGINE_DIR}/probes/vulkan-smoke.c"; do
  [[ -f "${required}" ]] || {
    printf 'build-vulkan: required input is missing: %s\n' "${required}" >&2
    exit 1
  }
done

cmake \
  -S "${HEADERS_SOURCE}" \
  -B "${HEADERS_BUILD}" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${HEADERS_INSTALL}" \
  -DVULKAN_HEADERS_ENABLE_INSTALL=ON \
  -DVULKAN_HEADERS_ENABLE_MODULE=OFF \
  -DVULKAN_HEADERS_ENABLE_TESTS=OFF
cmake --build "${HEADERS_BUILD}" --target install --parallel "${BUILD_JOBS}"

cmake \
  -S "${LOADER_SOURCE}" \
  -B "${LOADER_BUILD}" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
  -DCMAKE_INSTALL_PREFIX="${LOADER_INSTALL}" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_PREFIX_PATH="${HEADERS_INSTALL}" \
  -DVulkanHeaders_DIR="${HEADERS_INSTALL}/share/cmake/VulkanHeaders" \
  -DBUILD_TESTS=OFF \
  -DBUILD_WERROR=OFF \
  -DBUILD_WSI_DIRECTFB_SUPPORT=OFF \
  -DBUILD_WSI_WAYLAND_SUPPORT=OFF \
  -DBUILD_WSI_XCB_SUPPORT=OFF \
  -DBUILD_WSI_XLIB_SUPPORT=OFF \
  -DBUILD_WSI_XLIB_XRANDR_SUPPORT=OFF \
  -DLOADER_CODEGEN=OFF
cmake --build "${LOADER_BUILD}" --target vulkan --parallel "${BUILD_JOBS}"
cmake --install "${LOADER_BUILD}"

cmake \
  -S "${SWIFTSHADER_SOURCE}" \
  -B "${SWIFTSHADER_BUILD}" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}" \
  -DREACTOR_BACKEND=LLVM \
  -DSWIFTSHADER_LLVM_VERSION=10.0 \
  -DSWIFTSHADER_BUILD_BENCHMARKS=OFF \
  -DSWIFTSHADER_BUILD_PVR=OFF \
  -DSWIFTSHADER_BUILD_TESTS=OFF \
  -DSWIFTSHADER_BUILD_WSI_D2D=OFF \
  -DSWIFTSHADER_BUILD_WSI_DIRECTFB=OFF \
  -DSWIFTSHADER_BUILD_WSI_WAYLAND=OFF \
  -DSWIFTSHADER_BUILD_WSI_XCB=OFF \
  -DSWIFTSHADER_WARNINGS_AS_ERRORS=OFF
cmake --build "${SWIFTSHADER_BUILD}" --target vk_swiftshader \
  --parallel "${BUILD_JOBS}"

aarch64-linux-gnu-gcc \
  -std=c11 \
  -O2 \
  -DNDEBUG \
  -fPIE \
  -pie \
  -Wall \
  -Wextra \
  -Werror \
  -Wl,--build-id=sha1 \
  -Wl,--enable-new-dtags \
  -Wl,-rpath,'$ORIGIN/lib64/vulkan' \
  -Wl,-z,now \
  -Wl,-z,relro \
  -I"${HEADERS_INSTALL}/include" \
  -L"${LOADER_INSTALL}/lib" \
  "${ENGINE_DIR}/probes/vulkan-smoke.c" \
  -lvulkan \
  -o "${PROBE_OUTPUT}"
