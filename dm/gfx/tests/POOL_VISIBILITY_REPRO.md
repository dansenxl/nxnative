# Mapped-pool image visibility: scope-discussion reproducer

This branch contains **synthetic diagnostic tests, not a renderer fix**. It is
based on main `99330eb81c873c3aafe9fc92194c9687d77fcdbb`. No game files,
translated game shaders, private logs or device data are needed or included.
The new fixture uses the repository's MIT terms and existing test conventions.

## Run on an Apple-silicon Mac with Metal 4

```sh
make -C dm/gfx/tests GAME=010015100B514000 t_pool_visibility_repro
cd dm/gfx/tests
MTL_DEBUG_LAYER=1 DM_NVN_FAST_WAKE=0 ./t_pool_visibility_repro 0 16
MTL_DEBUG_LAYER=1 DM_NVN_FAST_WAKE=0 ./t_pool_visibility_repro 1
MTL_DEBUG_LAYER=1 DM_NVN_FAST_WAKE=0 ./t_pool_visibility_repro 2
MTL_DEBUG_LAYER=1 DM_NVN_FAST_WAKE=0 ./t_pool_visibility_repro 3
```

Repeat with `DM_NVN_FAST_WAKE=1`. The profile supplies public build constants;
its game is not loaded. Only the host's 13 built-in shader libraries are used.
The target is deliberately excluded from `make run`: modes 1–3 assert desired
visibility properties that **fail on current main**, rather than pretending the
unimplemented contract has passed. No production source or shader chain changes.

All modes render literal values into all six mips of a 37x29 RG8 texture in an
anonymous CPU_CACHED | GPU_CACHED pool. They verify actual ownership and the
literal GPU mip bytes independently, including an explicit producer-event wait
on the separate readback queue, before comparing guest storage. They finish the
producer before invalidating; no unrelated future GPU fence is awaited.

| Mode | Question | Observed on this base, both fast-wake settings |
|---|---|---|
| 0 | CPU-written/storage-backed image, the existing #604 path; 16 create/render/invalidate/finalize cycles | 480 checks pass, every mip visible |
| 1 | Same layout/rendering, image owned by the GPU, never CPU-written | GPU mips correct, 2,806 guest texel bytes differ; exit 1 |
| 2 | CPU writes after the exact GPU-completion signal while host feedback is deliberately gated | GPU mips correct, 2,806 of 7,168 newer CPU storage bytes overwritten; exit 1 |
| 3 | GPU-owned case with eight concurrent mapped-pool invalidators | GPU mips correct, 2,806 guest texel bytes differ; exit 1 |

Mode 2 is a controlled **publication-order stress test**, not proof of a valid
game-side sequence or a new real-game fault. It isolates delayed host effects
from completed GPU accesses. A proposed implementation needs an explicit CPU
ownership/order contract; comparison with a snapshot alone does not prove that
arbitrary concurrent guest writes or ABA reuse are safe.

## Validation and limits

Checked on Apple M5, macOS 27.0.1, Xcode 27.2, Metal API validation enabled:

- Current-main Mac host builds. Related existing tests pass: `t_readback` with
  fast-wake 0/1, `t_cpu_tex --metal`, `t_perf_order`, `t_tex_fit_root`,
  `t_direct_upload`, `t_dirty_retire_race`, `t_tex_layout`, `t_sparse_layout`.
- `make -C dm/gfx/tex/tests asan`: 5,344 checks pass.
- New fixture: ASan/UBSan preserves the expected outcomes, without sanitizer
  diagnostics. The real NVN HLE's fixed-stride `__DATA,swnvn` metadata requires
  the narrow `global:e_nvn*` ASan-redzone exception, in addition to the existing
  `dm/sanitizers/ignorelist.txt`; no production code is excluded. LeakSanitizer
  is disabled; no leak-free claim is made.
- TSan with fast-wake 0 preserves these outcomes without race reports. With
  fast-wake 1 it finds an **existing** `seg_ts` lazy-initialization race between
  feedback and early completion in `nvn_mtl.m:1322`. The optional fixture-only
  `DM_REPRO_PRIME_TS=1` initializes that setting before GPU work: then the same
  visibility outcomes occur without TSan reports. This control is neither a
  production fix nor a suppression; unprimed default TSan is **not PASS**.

No full game regression routes, new iPad run, IPA build, device update or
performance improvement are claimed. The downstream iPad grass result belongs
to a different host; this fixture establishes only the current-main boundaries.
This is not a merge-ready implementation of generic pool invalidation.
