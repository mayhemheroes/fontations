#!/usr/bin/env bash
#
# fontations/mayhem/build.sh — build googlefonts/fontations' cargo-fuzz targets as sanitized
# libFuzzer binaries, replicating OSS-Fuzz's Rust path
# (oss-fuzz/projects/fontations/build.sh, which runs a single `cargo fuzz build` from the
# workspace root and ships every produced `fuzz_*` binary).
#
# fontations is a pure-Rust font-parsing workspace (read-fonts / skrifa / write-fonts /
# incremental-font-transfer + the int-set collections). The `fuzz` crate is a member of the
# top-level workspace (Cargo.toml `members = [.., "fuzz", ..]`), so `cargo fuzz build` is run
# from the WORKSPACE ROOT ($SRC), not from inside fuzz/. The fuzzed library crates have no
# system-library dependency, so cargo-fuzz needs nothing beyond the Rust toolchain.
#
# cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is exactly what OSS-Fuzz's
#     `compile` sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
#
# Targets (fuzz/Cargo.toml [[bin]] entries) — all 11 are built by a single `cargo fuzz build`,
# matching OSS-Fuzz, and each produced binary is copied to /mayhem/<target>:
#   font-parsing (consume a real sfnt via select_font):
#     fuzz_basic_metadata fuzz_name fuzz_skrifa_charmap fuzz_skrifa_outline fuzz_skrifa_color
#   structured / byte-stream:
#     fuzz_int_set fuzz_range_set fuzz_sparse_bit_set_decode fuzz_sparse_bit_set_encode
#     fuzz_ift_patch_group
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even
# though the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# RUST_DEBUG_FLAGS threads DWARF < 4 symbols (SPEC §6.2 item 10): debuginfo=2 for line tables,
# -Z dwarf-version=3 for Rust user CUs, and -Clinker= wires in the cc-wrapper that prepends
# the DWARF3 anchor object as the FIRST object in every link — so the -m1 readelf check in
# verify-repo sees DWARF v3 even though the precompiled ASan runtime CUs remain DWARF v5.
# See the DWARF<4 RUN block in the Dockerfile for the full rationale.
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=2 -Zdwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

TRIPLE="x86_64-unknown-linux-gnu"

# Every [[bin]] in fuzz/Cargo.toml. `cargo fuzz build` with no target name builds them all.
FUZZ_TARGETS=(
  fuzz_basic_metadata
  fuzz_name
  fuzz_skrifa_charmap
  fuzz_skrifa_outline
  fuzz_skrifa_color
  fuzz_int_set
  fuzz_range_set
  fuzz_sparse_bit_set_decode
  fuzz_sparse_bit_set_encode
  fuzz_ift_patch_group
)

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
# Thread RUST_DEBUG_FLAGS for DWARF < 4 symbols (-Zdwarf-version=3 + cc-wrapper anchor).
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_DEBUG_FLAGS -Zsanitizer=address -Cforce-frame-pointers"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

# Single `cargo fuzz build` for the whole crate (matches OSS-Fuzz). Use the image's DEFAULT
# toolchain (Dockerfile pins it to the required nightly); a `+toolchain` override would make
# rustup try to install a different channel into the read-only shared /opt/rust. `-O` (release
# w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's build.sh (catches overflow/debug asserts
# during fuzzing). cargo-fuzz 0.12 doesn't accept --jobs; parallelism is via CARGO_BUILD_JOBS.
echo "--- cargo fuzz build (all targets) ---"
cargo fuzz build -O --debug-assertions

# `fuzz` is a workspace member, so cargo-fuzz emits binaries under the WORKSPACE-ROOT target dir
# ($SRC/target/<triple>/release), not fuzz/target — exactly the path OSS-Fuzz's build.sh uses
# (RELEASE_DIR=target/x86_64-unknown-linux-gnu/release, relative to the workspace root). Resolve
# it from cargo metadata so we're robust to layout changes, falling back to the conventional path.
TARGET_DIR="$(cargo metadata --no-deps --format-version 1 2>/dev/null \
  | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
[ -n "$TARGET_DIR" ] || TARGET_DIR="$SRC/target"
RELEASE_DIR="$TARGET_DIR/$TRIPLE/release"
echo "RELEASE_DIR=$RELEASE_DIR"

for t in "${FUZZ_TARGETS[@]}"; do
  bin="$RELEASE_DIR/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    echo "--- contents of $RELEASE_DIR ---" >&2
    ls -la "$RELEASE_DIR" 2>&1 >&2 || true
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la "${FUZZ_TARGETS[@]/#//mayhem/}" 2>&1 || true
