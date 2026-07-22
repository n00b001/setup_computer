# cpp-builder — `build_project.sh`

A one-shot builder for [`llama.cpp`](https://github.com/ggml-org/llama.cpp) and [`whisper.cpp`](https://github.com/ggml-org/whisper.cpp) that **clones, installs the right acceleration toolkits, builds, and exposes the binaries** — from any directory, on macOS or Linux.

For the project overview, see the [README](../README.md).

---

## Quick start

```bash
# llama.cpp, latest revision, auto-selected GPU acceleration
bash cpp-builder/build_project.sh

# whisper.cpp (with FFmpeg + curl support enabled automatically)
bash cpp-builder/build_project.sh whisper

# build a specific tag/commit/branch
bash cpp-builder/build_project.sh --rev b4589

# rebuild whatever is already checked out, no fetch
bash cpp-builder/build_project.sh --no-update

# wipe build/ and reconfigure from scratch
bash cpp-builder/build_project.sh llama --clean
```

Run `build_project.sh --help` for the full reference.

---

## What it does

1. **Detects the platform** and the available GPU compute backend.
2. **Installs toolchain + acceleration packages** through the system package manager (Homebrew on macOS, apt on Debian/Ubuntu).
3. **Clones** the project to `~/llama.cpp` (or `~/whisper.cpp`) — or **updates** it to the latest revision (`--update` is the default).
4. **Configures** with CMake/Ninja, turning **on** the right backend and **off** every other (explicit flags so a stale CMake cache can't leak an old choice).
5. **Builds** with all cores (`nproc` / `hw.ncpu`) and **installs** the binaries.
6. **Exposes** them on PATH — symlinks on macOS, `update-alternatives` on Linux.

Everything is tee'd to a timestamped log at `~/.cache/cppbuilder/logs/build-<project>-<ts>.log`, and a failure trap prints the failing line and the log path instead of dying silently.

---

## Acceleration matrix

Acceleration is chosen automatically from what the machine actually has. GPU **drivers are never installed or touched** — a working NVIDIA/AMD driver must already be present for GPU acceleration.

| Platform | Backend | BLAS | Extra | Also |
|:--|:--|:--|:--|:--|
| **macOS** (Apple Silicon / Intel) | Metal | Accelerate (built-in) | embeds the Metal kernel library | — |
| **Linux + NVIDIA** | CUDA | cuBLAS | FlashAttention, FA all-quants, graphs (llama), speed compression | + Vulkan |
| **Linux + AMD** | ROCm / HIP | hipBLAS | ROCWMMA FlashAttention when present | + Vulkan |
| **Linux, no GPU** | — | — | — | Vulkan if usable, else CPU + OpenBLAS |

Details the script works out for you:

- **CUDA** — queries `nvidia-smi` for the GPU's compute capability and pins `CMAKE_CUDA_ARCHITECTURES` exactly (no wasted SASS for other archs). Picks `g++-13` as the CUDA host compiler when available, and sets `CICC_PATH` if `nvvm/bin` exists.
- **ROCm** — reads `rocminfo` for the concrete `gfx*` targets and passes `GPU_TARGETS`. Enables `ROCWMMA_FATTN` when the header is present.
- **Vulkan** — kept **even alongside CUDA/HIP** as a runtime fallback; enabled only when both `glslc` and `libvulkan` are present.
- **OpenBLAS** — CPU-only, so used **only** as the no-GPU fallback (never piled on top of a GPU build).
- **Toolkits** — installed from the distro package manager only. If no clean package exists (common for ROCm), the build proceeds without that backend and prints the manual install steps.

If a GPU is physically present but its compiler is missing, the script tells you precisely what to install (`nvcc` → CUDA toolkit; `hipcc` → ROCm from AMD's repo).

---

## Where things land

| | macOS | Linux |
|:--|:--|:--|
| Install prefix | `~/.local/lib/llamacpp/<project>` | `/usr/local/lib/llamacpp/<project>` |
| Exposed via | symlinks into `~/.local/bin` (e.g. `llama-cli`, `llama-server`) | `update-alternatives` master group `llamacpp` |
| Needs sudo? | No (user-writable prefix) | Yes (for `/usr/local` install + alternatives) |

The Linux `update-alternatives` design lets **multiple forks coexist**: each build is registered with a priority derived from the commit count, and you switch the active fork with:

```bash
sudo update-alternatives --set llamacpp /usr/local/lib/llamacpp/llama.cpp/bin/llama-server
```

The master alternative is `llama-server` (or the first tool found); every other `llama-*` binary is registered as a `--slave` so they all point at the same fork.

---

## whisper.cpp specifics

Building `whisper` adds two things automatically:

- **apt deps** — `libavcodec-dev libavformat-dev libavutil-dev` (FFmpeg backends).
- **CMake flags** — `-DWHISPER_FFMPEG=ON -DWHISPER_CURL=ON`.

Otherwise the flow, acceleration selection, and install paths are identical to `llama.cpp`.

---

## Common flags

| Flag | Effect |
|:--|:--|
| `llama` / `whisper` (positional) | Which project to build. Default: `llama`. |
| `--rev <ref>` | Build a specific branch, tag, or commit. Default: the repo's default branch. |
| `--update` | Fetch latest before building. **This is the default.** |
| `--no-update` | Build the current checkout as-is (still clones if missing). |
| `--clean` / `-c` | Remove `build/` and reconfigure from scratch. |
| `-h` / `--help` | Show the help text. |

Other build defaults baked in: `CMAKE_BUILD_TYPE=Release`, static libs (`BUILD_SHARED_LIBS=OFF`), `GGML_NATIVE=ON`, LTO on, and `ccache` as the compiler launcher when present (so incremental rebuilds are fast).
