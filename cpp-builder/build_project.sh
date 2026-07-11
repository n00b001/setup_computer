#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Generic GGML project builder
# Builds llama.cpp / whisper.cpp (or a fork) with every hardware-acceleration
# backend the current machine actually supports — auto-detected at runtime:
#   - CUDA        (+ cuBLAS, FlashAttention)   when nvcc is present
#   - ROCm / HIP  (+ hipBLAS/rocBLAS)          when hipcc / rocminfo is present
#   - Vulkan                                   when glslc + libvulkan are present
#   - OpenBLAS    (CPU BLAS)                    when libopenblas is present
# A backend whose toolchain is missing is skipped with a log line — the build
# degrades to whatever the box has (down to CPU-only) instead of aborting.
#
# Run from inside the project directory:
#   ./build_project.sh [--update|-u] [--clean|-c]
#
# Everything is teed to logs/build-<timestamp>.log and an ERR trap names the
# exact failing command, so a failure is never silent.
# =============================================================================

UPDATE=false
CLEAN_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --update|-u) UPDATE=true ;;
        --clean|-c)  CLEAN_BUILD=true ;;
        -h|--help)   echo "Usage: $0 [--update|-u] [--clean|-c]"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; echo "Usage: $0 [--update|-u] [--clean|-c]" >&2; exit 2 ;;
    esac
done

PROJECT_DIR="$(pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
BUILD_TYPE="Release"
CPU_CORES="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# Each fork installs to its own directory, managed by update-alternatives.
# Switch forks: update-alternatives --set llamacpp /usr/local/lib/llamacpp/<project>
INSTALL_PREFIX="/usr/local/lib/llamacpp/$PROJECT_NAME"

# ── logging: tee all output to a timestamped file, and an ERR trap that names
#    the failing command + line. This is why a build can no longer exit
#    "silently with code 1" — the reason is always printed and logged. ──
LOG_DIR="$PROJECT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf "\n\033[1;36m[%s]\033[0m %s\n" "$PROJECT_NAME" "$1"; }
warn() { printf "\033[1;33m[%s] warn:\033[0m %s\n" "$PROJECT_NAME" "$1"; }
die()  { printf "\033[1;31m[%s] error:\033[0m %s\n" "$PROJECT_NAME" "$1" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

trap 'rc=$?; printf "\n\033[1;31m[%s] BUILD FAILED\033[0m at line %s: %s (exit %s)\n  full log: %s\n" \
      "$PROJECT_NAME" "$LINENO" "$BASH_COMMAND" "$rc" "$LOG_FILE" >&2' ERR

log "Build started $(date '+%Y-%m-%d %H:%M:%S')  |  cores: $CPU_CORES  |  log: $LOG_FILE"

###############################################################################
# Detect project -> git remote, extra deps, project-specific cmake flags
###############################################################################

PROJECT_KIND=""          # llama | whisper
EXTRA_DEPS=()
EXTRA_CMAKE_FLAGS=()

pick_llama() {
    PROJECT_KIND="llama"
    GIT_REMOTE="https://github.com/ggml-org/llama.cpp.git"
    EXTRA_DEPS=(libcurl4-openssl-dev)
    EXTRA_CMAKE_FLAGS=()
}
pick_whisper() {
    PROJECT_KIND="whisper"
    GIT_REMOTE="https://github.com/ggml-org/whisper.cpp.git"
    EXTRA_DEPS=(libcurl4-openssl-dev libavcodec-dev libavformat-dev libavutil-dev)
    EXTRA_CMAKE_FLAGS=(-DWHISPER_FFMPEG=ON -DWHISPER_CURL=ON)
}

case "$PROJECT_NAME" in
    whisper.cpp|whisper-cpp*|whisper.cpp-*)               pick_whisper ;;
    llama.cpp|llama-cpp*|llama.cpp-*|llamacpp*|llama.cpp*) pick_llama ;;
    *)
        warn "Unknown project '$PROJECT_NAME' — is it a fork of llama.cpp or whisper.cpp?"
        if [[ -t 0 ]]; then
            printf "  [l]lama.cpp / [w]hisper.cpp (default: llama.cpp): "
            read -r choice || choice="l"
        else
            choice="l"
            warn "no terminal on stdin; defaulting to llama.cpp"
        fi
        case "${choice:-l}" in
            [wW]*) pick_whisper ;;
            *)     pick_llama ;;
        esac
        log "Treating '$PROJECT_NAME' as a fork of $PROJECT_KIND.cpp"
        ;;
esac

###############################################################################
# Detect hardware acceleration backends  (never fatal — missing = skipped)
###############################################################################

ACCEL_FLAGS=()
ACCEL_SUMMARY=()

# Pick ONE GPU compute backend: CUDA and HIP are mutually exclusive in a single
# ggml build (a box is NVIDIA *or* AMD). Vulkan and BLAS stack on top of either.
GPU_BACKEND="none"
if has nvcc; then
    GPU_BACKEND="cuda"
elif has hipcc || has rocminfo || [[ -d /opt/rocm ]]; then
    GPU_BACKEND="hip"
fi

# ---- CUDA (NVIDIA): provides cuBLAS + FlashAttention kernels ----
if [[ "$GPU_BACKEND" == "cuda" ]]; then
    ACCEL_FLAGS+=(
        -DGGML_CUDA=ON
        -DGGML_CUDA_FA=ON
        -DGGML_CUDA_FA_ALL_QUANTS=ON
        -DGGML_CUDA_CUB_3DOT2=ON
        -DGGML_CUDA_COMPRESSION_MODE=speed
    )
    [[ "$PROJECT_KIND" == "llama" ]] && ACCEL_FLAGS+=(-DGGML_CUDA_GRAPHS=ON)

    # Auto-detect the compute capability of the installed GPU(s) instead of
    # hardcoding one arch. "8.9" -> "89"; multiple GPUs -> "86;89".
    CUDA_ARCHS=""
    if has nvidia-smi; then
        # || true: a failing/empty pipeline must not trip set -e in this assignment
        CUDA_ARCHS="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
            | tr -d '. ' | grep -E '^[0-9]+$' | sort -u | paste -sd';' - || true)"
    fi
    if [[ -n "$CUDA_ARCHS" ]]; then
        ACCEL_FLAGS+=(-DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHS")
        ACCEL_SUMMARY+=("CUDA arch=$CUDA_ARCHS (+cuBLAS, FlashAttention)")
    else
        # no nvidia-smi to probe (e.g. headless build host): let ggml/cmake
        # choose its default arch set rather than guessing wrong.
        ACCEL_SUMMARY+=("CUDA default-archs (+cuBLAS, FlashAttention)")
    fi

    # mixed-toolkit installs: point at the alternatives-managed nvvm
    [[ -d /usr/local/cuda/nvvm/bin ]] && export CICC_PATH="/usr/local/cuda/nvvm/bin"
    # CUDA <= 13.x supports GCC 13 as host compiler; prefer it when installed
    _CUDA_HOST_COMPILER="$(command -v g++-13 2>/dev/null || true)"
    [[ -n "$_CUDA_HOST_COMPILER" ]] && ACCEL_FLAGS+=(-DCMAKE_CUDA_HOST_COMPILER="$_CUDA_HOST_COMPILER")
else
    warn "no nvcc on PATH — CUDA/cuBLAS backend skipped"
fi

# ---- ROCm / HIP (AMD): provides hipBLAS/rocBLAS ----
if [[ "$GPU_BACKEND" == "hip" ]]; then
    ACCEL_FLAGS+=(-DGGML_HIP=ON)
    GPU_TARGETS=""
    if has rocminfo; then
        GPU_TARGETS="$(rocminfo 2>/dev/null | grep -oE 'gfx[0-9a-f]+' | sort -u | paste -sd';' - || true)"
    fi
    if [[ -n "$GPU_TARGETS" ]]; then
        ACCEL_FLAGS+=(-DGPU_TARGETS="$GPU_TARGETS")
        ACCEL_SUMMARY+=("ROCm/HIP targets=$GPU_TARGETS (+hipBLAS)")
    else
        # omitting GPU_TARGETS builds for all GPUs currently in the system
        ACCEL_SUMMARY+=("ROCm/HIP all-GPUs (+hipBLAS)")
    fi
    # rocWMMA FlashAttention for RDNA3+/CDNA when its headers are installed
    if [[ -e /opt/rocm/include/rocwmma/rocwmma.hpp ]]; then
        ACCEL_FLAGS+=(-DGGML_HIP_ROCWMMA_FATTN=ON)
    fi
elif [[ "$GPU_BACKEND" != "cuda" ]]; then
    warn "no ROCm/hipcc found — ROCm/HIP backend skipped"
fi

# ---- Vulkan: stacks on top of the GPU backend when its toolchain is present ----
if has glslc && { has vulkaninfo || ldconfig -p 2>/dev/null | grep -q libvulkan; }; then
    ACCEL_FLAGS+=(-DGGML_VULKAN=ON)
    ACCEL_SUMMARY+=("Vulkan")
else
    warn "no Vulkan toolchain (glslc + libvulkan) — Vulkan backend skipped"
fi

# ---- OpenBLAS: CPU BLAS acceleration, always safe to add when present ----
# (grouped so precedence is "ldconfig-hit OR pkgconfig-hit", not (A||B)&&C)
if ldconfig -p 2>/dev/null | grep -q libopenblas \
   || { has pkg-config && pkg-config --exists openblas 2>/dev/null; }; then
    ACCEL_FLAGS+=(-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS)
    ACCEL_SUMMARY+=("OpenBLAS (CPU)")
fi

if [[ "$GPU_BACKEND" == "none" ]]; then
    warn "No GPU compute backend detected (no CUDA, no ROCm)."
    warn "Building CPU-only (plus OpenBLAS/Vulkan if available). Install the CUDA"
    warn "or ROCm toolkit and re-run to get GPU acceleration."
fi

###############################################################################
# Dependencies (apt/Debian; other distros: ensure the build tools yourself)
###############################################################################

DEPS=(
    pciutils build-essential cmake ninja-build git curl pkg-config
    libopenblas-dev ccache libvulkan-dev vulkan-tools glslc
    python3 python3-pip
    ${EXTRA_DEPS[@]+"${EXTRA_DEPS[@]}"}
)

if has apt-get && has dpkg; then
    MISSING=()
    for pkg in "${DEPS[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
    done
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        log "Installing missing packages: ${MISSING[*]}"
        if ! sudo apt-get install -y "${MISSING[@]}"; then
            warn "apt install failed; refreshing package lists and retrying"
            sudo apt-get update
            sudo apt-get install -y "${MISSING[@]}" || die "could not install: ${MISSING[*]}"
        fi
    else
        log "All apt dependencies satisfied"
    fi
else
    warn "non-apt system: skipping dependency install — ensure cmake, ninja, git,"
    warn "curl, pkg-config, ccache and a compiler toolchain are already installed"
fi

###############################################################################
# Clone / Update
###############################################################################

if [[ "$UPDATE" == true ]]; then
    if [[ -d "$PROJECT_DIR/.git" ]]; then
        log "Updating existing checkout"
        DEFAULT_BRANCH="$(git -C "$PROJECT_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
        DEFAULT_BRANCH="${DEFAULT_BRANCH:-master}"
        git -C "$PROJECT_DIR" checkout "$DEFAULT_BRANCH" || warn "could not checkout $DEFAULT_BRANCH"
        git -C "$PROJECT_DIR" pull --ff-only || warn "git pull failed; building current checkout"
    else
        log "Cloning $GIT_REMOTE into $PROJECT_DIR"
        # clone into a non-empty dir: clone to temp then move .git + files in
        _tmp="$(mktemp -d)"
        git clone "$GIT_REMOTE" "$_tmp/src"
        shopt -s dotglob
        mv "$_tmp/src"/* "$PROJECT_DIR"/ 2>/dev/null || cp -a "$_tmp/src"/. "$PROJECT_DIR"/
        shopt -u dotglob
        rm -rf "$_tmp"
    fi
else
    log "Skipping git update (pass --update to fetch latest)"
fi

if [[ ! -f "$PROJECT_DIR/CMakeLists.txt" ]]; then
    die "no CMakeLists.txt in $PROJECT_DIR — run with --update to clone $GIT_REMOTE, or run inside a llama.cpp/whisper.cpp checkout"
fi

###############################################################################
# Configure
###############################################################################

cd "$PROJECT_DIR"

BASE_FLAGS=(
    -S . -B build -G Ninja
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
    -DBUILD_SHARED_LIBS=OFF
    -DGGML_NATIVE=ON
    -DGGML_LTO=ON
)
if has ccache; then
    BASE_FLAGS+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

log "Acceleration: ${ACCEL_SUMMARY[*]:-CPU only}"
log "Configuring (cmake)…"
cmake "${BASE_FLAGS[@]}" \
      ${ACCEL_FLAGS[@]+"${ACCEL_FLAGS[@]}"} \
      ${EXTRA_CMAKE_FLAGS[@]+"${EXTRA_CMAKE_FLAGS[@]}"}

###############################################################################
# Build & Install
###############################################################################

log "Building with $CPU_CORES cores…"
if [[ "$CLEAN_BUILD" == true ]]; then
    cmake --build build --config Release --clean-first -j "$CPU_CORES"
else
    cmake --build build --config Release -j "$CPU_CORES"
fi

log "Installing to $INSTALL_PREFIX (sudo)…"
sudo cmake --build build --target install

###############################################################################
# Register update-alternatives for llama tools (llama.cpp only)
###############################################################################

LLAMA_TOOLS=()
if [[ -d "$INSTALL_PREFIX/bin" ]]; then
    for f in "$INSTALL_PREFIX"/bin/llama-*; do
        [[ -f "$f" ]] && LLAMA_TOOLS+=("$(basename "$f")")
    done
fi

if [[ ${#LLAMA_TOOLS[@]} -gt 0 ]]; then
    _PRIORITY="$(git -C "$PROJECT_DIR" rev-list HEAD --count 2>/dev/null || echo 1)"

    if printf '%s\n' "${LLAMA_TOOLS[@]}" | grep -qx "llama-server"; then
        MASTER="llama-server"
    else
        MASTER="${LLAMA_TOOLS[0]}"
    fi

    _SLAVE_ARGS=()
    for tool in "${LLAMA_TOOLS[@]}"; do
        [[ "$tool" == "$MASTER" ]] && continue
        _SLAVE_ARGS+=(--slave "/usr/bin/$tool" "llamacpp-$tool" "$INSTALL_PREFIX/bin/$tool")
    done

    sudo update-alternatives --install "/usr/bin/$MASTER" llamacpp \
        "$INSTALL_PREFIX/bin/$MASTER" "$_PRIORITY" \
        ${_SLAVE_ARGS[@]+"${_SLAVE_ARGS[@]}"}

    log "Registered 'llamacpp' alternatives (${#LLAMA_TOOLS[@]} tools, master: $MASTER)"
fi

# success: disable the failure trap so the closing lines stay clean
trap - ERR

log "Done. Installed to: $INSTALL_PREFIX/"
log "Enabled backends: ${ACCEL_SUMMARY[*]:-CPU only}"
log "Log saved to: $LOG_FILE"
if [[ ${#LLAMA_TOOLS[@]} -gt 0 ]]; then
    log "Switch forks:  update-alternatives --set llamacpp $INSTALL_PREFIX/bin/$MASTER"
    log "List options:  update-alternatives --display llamacpp"
fi
log "Runtime env you may want:"
log "  GGML_CUDA_ENABLE_UNIFIED_MEMORY=1  # spill to system RAM when VRAM is full (CUDA)"
