#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# cpp-builder — one-shot builder for llama.cpp / whisper.cpp
#
# Run it from anywhere. It clones the project into your home directory, installs
# the acceleration toolkits your machine can use, builds with them, and installs
# the binaries. Re-running updates to the latest revision by default.
#
# Acceleration is auto-selected per platform:
#   macOS (Apple Silicon/Intel)  -> Metal (+ Accelerate BLAS)
#   Linux + NVIDIA GPU           -> CUDA (+ cuBLAS) [+ Vulkan]
#   Linux + AMD GPU              -> ROCm/HIP (+ hipBLAS) [+ Vulkan]
#   Linux, no GPU                -> Vulkan if usable, else CPU + OpenBLAS
#
# Missing toolkits are installed via the system package manager (Homebrew on
# macOS, apt on Debian/Ubuntu). GPU *drivers* are never installed or modified;
# a working NVIDIA/AMD driver must already be present for GPU acceleration.
#
# Usage:  build_project.sh [PROJECT] [options]
#   see --help
# =============================================================================

# ── argument parsing ────────────────────────────────────────────────────────
PROJECT_KIND="llama"     # llama | whisper
UPDATE=true              # --update is the default; --no-update disables it
CLEAN_BUILD=false
REV=""                   # git branch/tag/commit; empty => repo default branch

usage() {
    cat <<'HELP'
cpp-builder — build & install llama.cpp / whisper.cpp with GPU acceleration

USAGE
    build_project.sh [PROJECT] [OPTIONS]

PROJECT (positional, optional; default: llama.cpp)
    llama.cpp    | llama   | llamacpp      build llama.cpp
    whisper.cpp  | whisper | whispercpp    build whisper.cpp

OPTIONS
    --rev <ref>       Build a specific git revision (branch, tag, or commit).
                      Default: the repository's default branch (master/main).
    --update          Fetch the latest changes before building. THIS IS THE
                      DEFAULT — you do not need to pass it.
    --no-update       Do not fetch; build the currently checked-out revision
                      as-is. (A missing checkout is still cloned first.)
    --clean           Remove the build directory and configure from scratch.
    -h, --help        Show this help and exit.

BEHAVIOUR
    * Runs from any directory. The project is cloned to ~/<project>
      (e.g. ~/llama.cpp) and built there.
    * Installs the acceleration toolkits the machine supports, then builds:
        macOS          -> Metal (+ Accelerate)
        Linux NVIDIA   -> CUDA (+ cuBLAS)   [+ Vulkan]
        Linux AMD      -> ROCm/HIP (+ hipBLAS) [+ Vulkan]
        Linux no-GPU   -> Vulkan / CPU + OpenBLAS
      cuBLAS/hipBLAS come with CUDA/ROCm; OpenBLAS is used only as the CPU
      fallback. GPU drivers are never installed or changed.
    * CUDA/ROCm are installed from the distro package manager only (apt).
      If no clean package exists, the build proceeds without that backend and
      prints the manual install steps.
    * Everything is logged to ~/.cache/cppbuilder/logs/build-<project>-<ts>.log.

EXAMPLES
    build_project.sh                       # llama.cpp, latest, all accel
    build_project.sh whisper.cpp           # whisper.cpp, latest
    build_project.sh --rev b4589           # build a specific tag/commit
    build_project.sh --no-update           # rebuild what is already checked out
    build_project.sh llama --clean         # clean rebuild
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        llama.cpp|llama|llamacpp)          PROJECT_KIND="llama" ;;
        whisper.cpp|whisper|whispercpp)    PROJECT_KIND="whisper" ;;
        --rev)   shift; REV="${1:-}"; [[ -z "$REV" ]] && { echo "--rev needs a value" >&2; exit 2; } ;;
        --rev=*) REV="${1#*=}" ;;
        --update)    UPDATE=true ;;
        --no-update) UPDATE=false ;;
        --clean|-c)  CLEAN_BUILD=true ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; echo "Try --help." >&2; exit 2 ;;
    esac
    shift
done

# ── platform ─────────────────────────────────────────────────────────────────
case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    Linux)  PLATFORM=linux ;;
    *)      echo "Unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac

if [[ "$PROJECT_KIND" == "whisper" ]]; then
    PROJECT_NAME="whisper.cpp"
    GIT_REMOTE="https://github.com/ggml-org/whisper.cpp.git"
else
    PROJECT_NAME="llama.cpp"
    GIT_REMOTE="https://github.com/ggml-org/llama.cpp.git"
fi
PROJECT_DIR="$HOME/$PROJECT_NAME"
CPU_CORES="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

if [[ "$PLATFORM" == macos ]]; then
    INSTALL_PREFIX="$HOME/.local/lib/llamacpp/$PROJECT_NAME"
else
    INSTALL_PREFIX="/usr/local/lib/llamacpp/$PROJECT_NAME"
fi

# ── logging + failure trap (so a build never dies silently) ──────────────────
LOG_DIR="$HOME/.cache/cppbuilder/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/build-$PROJECT_NAME-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf "\n\033[1;36m[%s]\033[0m %s\n" "$PROJECT_NAME" "$1"; }
warn() { printf "\033[1;33m[%s] warn:\033[0m %s\n" "$PROJECT_NAME" "$1"; }
die()  { printf "\033[1;31m[%s] error:\033[0m %s\n" "$PROJECT_NAME" "$1" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

trap 'rc=$?; printf "\n\033[1;31m[%s] BUILD FAILED\033[0m at line %s: %s (exit %s)\n  full log: %s\n" \
      "$PROJECT_NAME" "$LINENO" "$BASH_COMMAND" "$rc" "$LOG_FILE" >&2' ERR

log "cpp-builder | $PROJECT_NAME | platform: $PLATFORM | cores: $CPU_CORES"
log "target: ${REV:-default branch} | update: $UPDATE | dir: $PROJECT_DIR"
log "log: $LOG_FILE"

# ── project-specific extras ──────────────────────────────────────────────────
EXTRA_DEPS=()          # apt packages
EXTRA_CMAKE_FLAGS=()
if [[ "$PROJECT_KIND" == "whisper" ]]; then
    EXTRA_DEPS=(libavcodec-dev libavformat-dev libavutil-dev)
    EXTRA_CMAKE_FLAGS=(-DWHISPER_FFMPEG=ON -DWHISPER_CURL=ON)
fi

###############################################################################
# GPU presence (best effort, no driver interaction)
###############################################################################
have_nvidia_gpu() { has nvidia-smi || lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -iq nvidia; }
# precise AMD vendor strings — NOT a bare 'ati', which matches "CorporATIon"
have_amd_gpu()    { lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -iqE 'advanced micro devices|\[amd/ati\]|radeon|instinct'; }

###############################################################################
# Install toolchain + acceleration toolkits (per platform)
###############################################################################
if [[ "$PLATFORM" == macos ]]; then
    # Metal ships with macOS; it just needs the Xcode command-line tools and a
    # normal build toolchain. Accelerate (Apple's BLAS) is built in too.
    if ! xcode-select -p >/dev/null 2>&1; then
        warn "Xcode Command Line Tools missing — launching the installer"
        xcode-select --install 2>/dev/null || true
        die "finish the Xcode Command Line Tools install, then re-run this script"
    fi
    if has brew; then
        for f in cmake ninja git ccache; do
            brew list "$f" >/dev/null 2>&1 || brew install "$f" </dev/null || warn "brew install $f failed"
        done
    else
        warn "Homebrew not found — ensure cmake, ninja and git are installed"
    fi

elif has apt-get && has dpkg; then
    export DEBIAN_FRONTEND=noninteractive
    BASE_DEPS=(
        pciutils build-essential cmake ninja-build git curl pkg-config ccache
        libopenblas-dev libvulkan-dev vulkan-tools glslc
        libcurl4-openssl-dev python3 python3-pip
        ${EXTRA_DEPS[@]+"${EXTRA_DEPS[@]}"}
    )
    # NVIDIA GPU but no CUDA compiler -> install the distro CUDA toolkit (cuBLAS
    # comes with it). Driver is assumed present (needed for acceleration).
    if have_nvidia_gpu && ! has nvcc; then
        log "NVIDIA GPU detected without nvcc — adding nvidia-cuda-toolkit"
        BASE_DEPS+=(nvidia-cuda-toolkit)
    fi
    # AMD GPU but no HIP compiler -> try the distro ROCm packages (best effort)
    ROCM_WANTED=false
    if have_amd_gpu && ! has hipcc && [[ ! -d /opt/rocm ]]; then
        ROCM_WANTED=true
    fi

    MISSING=()
    for pkg in "${BASE_DEPS[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
    done
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        log "Installing: ${MISSING[*]}"
        sudo apt-get install -y "${MISSING[@]}" \
            || { sudo apt-get update && sudo apt-get install -y "${MISSING[@]}"; } \
            || warn "some packages failed to install; continuing with what is present"
    else
        log "Base dependencies already satisfied"
    fi

    if [[ "$ROCM_WANTED" == true ]]; then
        log "AMD GPU detected — attempting distro ROCm/HIP packages"
        if ! sudo apt-get install -y rocm-hip-sdk hipblas rocblas 2>/dev/null; then
            warn "distro has no clean ROCm package. To enable ROCm, install it from"
            warn "AMD's repo (https://rocm.docs.amd.com), then re-run. Building without ROCm."
        fi
    fi
    hash -r
else
    warn "non-apt Linux: install cmake, ninja, git, a compiler, and any GPU"
    warn "toolkit (CUDA/ROCm) + vulkan/openblas dev packages yourself, then re-run"
fi

###############################################################################
# Clone / update to the requested revision
###############################################################################
if [[ ! -d "$PROJECT_DIR/.git" ]]; then
    log "Cloning $GIT_REMOTE -> $PROJECT_DIR"
    git clone "$GIT_REMOTE" "$PROJECT_DIR"
    JUST_CLONED=true
else
    JUST_CLONED=false
fi

if [[ "$UPDATE" == true || -n "$REV" || "$JUST_CLONED" == true ]]; then
    if [[ "$UPDATE" == true || "$JUST_CLONED" == true ]]; then
        git -C "$PROJECT_DIR" fetch --all --tags --prune || warn "git fetch failed; using local refs"
    fi
    if [[ -n "$REV" ]]; then
        TARGET="$REV"
    else
        TARGET="$(git -C "$PROJECT_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
        [[ -z "$TARGET" ]] && TARGET="master"
    fi
    log "Checking out: $TARGET"
    git -C "$PROJECT_DIR" checkout "$TARGET" || die "could not checkout '$TARGET'"
    # fast-forward only when on a branch (a tag/commit leaves a detached HEAD)
    if [[ "$UPDATE" == true ]] && git -C "$PROJECT_DIR" symbolic-ref -q HEAD >/dev/null; then
        git -C "$PROJECT_DIR" pull --ff-only || warn "pull failed; building current checkout"
    fi
else
    log "--no-update: building the current checkout as-is"
fi

cd "$PROJECT_DIR"
[[ -f CMakeLists.txt ]] || die "no CMakeLists.txt in $PROJECT_DIR (unexpected)"
log "Building revision: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

###############################################################################
# Select acceleration backends (explicit ON/OFF so a stale cache can't leak)
###############################################################################
ACCEL_FLAGS=()
ACCEL_SUMMARY=()

if [[ "$PLATFORM" == macos ]]; then
    # Metal is the accelerator on Apple; Accelerate (default) provides BLAS.
    ACCEL_FLAGS+=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
                  -DGGML_CUDA=OFF -DGGML_HIP=OFF -DGGML_VULKAN=OFF)
    ACCEL_SUMMARY+=("Metal (+Accelerate)")
else
    # one GPU compute backend (CUDA xor HIP); Vulkan stacks; OpenBLAS is CPU-only
    GPU_BACKEND="none"
    if has nvcc; then GPU_BACKEND="cuda"
    elif has hipcc || [[ -d /opt/rocm ]]; then GPU_BACKEND="hip"; fi

    if [[ "$GPU_BACKEND" == "cuda" ]]; then
        ACCEL_FLAGS+=(-DGGML_CUDA=ON -DGGML_CUDA_FA=ON -DGGML_CUDA_FA_ALL_QUANTS=ON
                      -DGGML_CUDA_CUB_3DOT2=ON -DGGML_CUDA_COMPRESSION_MODE=speed)
        [[ "$PROJECT_KIND" == "llama" ]] && ACCEL_FLAGS+=(-DGGML_CUDA_GRAPHS=ON)
        CUDA_ARCHS=""
        if has nvidia-smi; then
            CUDA_ARCHS="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
                | tr -d '. ' | grep -E '^[0-9]+$' | sort -u | paste -sd';' - || true)"
        fi
        if [[ -n "$CUDA_ARCHS" ]]; then
            ACCEL_FLAGS+=(-DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHS")
            ACCEL_SUMMARY+=("CUDA arch=$CUDA_ARCHS (+cuBLAS, FlashAttention)")
        else
            ACCEL_SUMMARY+=("CUDA default-archs (+cuBLAS, FlashAttention)")
        fi
        [[ -d /usr/local/cuda/nvvm/bin ]] && export CICC_PATH="/usr/local/cuda/nvvm/bin"
        _HOSTCC="$(command -v g++-13 2>/dev/null || true)"
        [[ -n "$_HOSTCC" ]] && ACCEL_FLAGS+=(-DCMAKE_CUDA_HOST_COMPILER="$_HOSTCC")
    else
        ACCEL_FLAGS+=(-DGGML_CUDA=OFF)
    fi

    if [[ "$GPU_BACKEND" == "hip" ]]; then
        ACCEL_FLAGS+=(-DGGML_HIP=ON)
        GPU_TARGETS=""
        has rocminfo && GPU_TARGETS="$(rocminfo 2>/dev/null | grep -oE 'gfx[0-9a-f]+' | sort -u | paste -sd';' - || true)"
        if [[ -n "$GPU_TARGETS" ]]; then
            ACCEL_FLAGS+=(-DGPU_TARGETS="$GPU_TARGETS"); ACCEL_SUMMARY+=("ROCm/HIP targets=$GPU_TARGETS (+hipBLAS)")
        else
            ACCEL_SUMMARY+=("ROCm/HIP all-GPUs (+hipBLAS)")
        fi
        [[ -e /opt/rocm/include/rocwmma/rocwmma.hpp ]] && ACCEL_FLAGS+=(-DGGML_HIP_ROCWMMA_FATTN=ON)
    else
        ACCEL_FLAGS+=(-DGGML_HIP=OFF)
    fi

    # Vulkan: cross-vendor, kept even alongside CUDA/HIP as a runtime fallback
    if has glslc && { has vulkaninfo || ldconfig -p 2>/dev/null | grep -q libvulkan; }; then
        ACCEL_FLAGS+=(-DGGML_VULKAN=ON); ACCEL_SUMMARY+=("Vulkan")
    else
        ACCEL_FLAGS+=(-DGGML_VULKAN=OFF)
        warn "no Vulkan toolchain (glslc + libvulkan) — Vulkan skipped"
    fi

    # OpenBLAS: CPU-only, so only as the fallback when there is no GPU backend
    if [[ "$GPU_BACKEND" == "none" ]] \
       && { ldconfig -p 2>/dev/null | grep -q libopenblas \
            || { has pkg-config && pkg-config --exists openblas 2>/dev/null; }; }; then
        ACCEL_FLAGS+=(-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS); ACCEL_SUMMARY+=("OpenBLAS (CPU)")
    else
        ACCEL_FLAGS+=(-DGGML_BLAS=OFF)
    fi

    if [[ "$GPU_BACKEND" == "none" ]]; then
        warn "No GPU compute backend available."
        if have_nvidia_gpu;   then warn "NVIDIA GPU present but nvcc missing — install the driver + CUDA toolkit."
        elif have_amd_gpu;    then warn "AMD GPU present but ROCm missing — install ROCm from AMD's repo."
        else                       warn "No supported GPU detected — CPU build (Vulkan/OpenBLAS if available)."
        fi
    fi
fi

###############################################################################
# Configure, build, install
###############################################################################
[[ "$CLEAN_BUILD" == true ]] && { log "Clean build: removing build/"; rm -rf build; }

BASE_FLAGS=(
    -S . -B build -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
    -DBUILD_SHARED_LIBS=OFF
    -DGGML_NATIVE=ON
    -DGGML_LTO=ON
)
has ccache && BASE_FLAGS+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)

log "Acceleration: ${ACCEL_SUMMARY[*]:-CPU only}"
log "Configuring..."
cmake "${BASE_FLAGS[@]}" \
      ${ACCEL_FLAGS[@]+"${ACCEL_FLAGS[@]}"} \
      ${EXTRA_CMAKE_FLAGS[@]+"${EXTRA_CMAKE_FLAGS[@]}"}

log "Building with $CPU_CORES cores..."
cmake --build build --config Release -j "$CPU_CORES"

log "Installing to $INSTALL_PREFIX..."
if [[ "$PLATFORM" == macos ]]; then
    cmake --build build --target install               # user-writable prefix, no sudo
else
    sudo cmake --build build --target install
fi

###############################################################################
# Expose the binaries
###############################################################################
if [[ "$PLATFORM" == macos ]]; then
    # symlink into ~/.local/bin (on PATH via setup.sh)
    mkdir -p "$HOME/.local/bin"
    if [[ -d "$INSTALL_PREFIX/bin" ]]; then
        for f in "$INSTALL_PREFIX"/bin/*; do
            [[ -f "$f" ]] && ln -sf "$f" "$HOME/.local/bin/$(basename "$f")"
        done
        log "Symlinked $(ls "$INSTALL_PREFIX"/bin | wc -l | tr -d ' ') binaries into ~/.local/bin"
    fi
else
    # Debian update-alternatives, so multiple forks can coexist and be switched
    LLAMA_TOOLS=()
    if [[ -d "$INSTALL_PREFIX/bin" ]]; then
        for f in "$INSTALL_PREFIX"/bin/llama-*; do
            [[ -f "$f" ]] && LLAMA_TOOLS+=("$(basename "$f")")
        done
    fi
    if [[ ${#LLAMA_TOOLS[@]} -gt 0 ]]; then
        _PRIORITY="$(git -C "$PROJECT_DIR" rev-list HEAD --count 2>/dev/null || echo 1)"
        if printf '%s\n' "${LLAMA_TOOLS[@]}" | grep -qx "llama-server"; then MASTER="llama-server"; else MASTER="${LLAMA_TOOLS[0]}"; fi
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
fi

trap - ERR
log "Done. $PROJECT_NAME @ $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
log "Acceleration: ${ACCEL_SUMMARY[*]:-CPU only}"
log "Installed to: $INSTALL_PREFIX  |  log: $LOG_FILE"
if [[ "$PLATFORM" == macos ]]; then
    log "Binaries symlinked into ~/.local/bin (e.g. llama-cli, llama-server)."
else
    log "Switch forks: update-alternatives --set llamacpp $INSTALL_PREFIX/bin/llama-server"
fi
