// SPDX-License-Identifier: MIT
// Synthetic current-main characterization. No game files or shaders required.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
module_t *g_mod; int g_nmod;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static unsigned checks, failures;
#define CHECK(c, s) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL: %s\n", s); } } while (0)
static void checkpoint(dispatch_semaphore_t s) {
    CHECK(!dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 10000000000ll)), "bounded checkpoint");
    if (failures) exit(2);
}
static unsigned mismatches(const tex_t *t, unsigned levels) {
    unsigned bad = 0;
    for (unsigned l = 0; l < levels; l++) {
        size_t w = MAX(t->d.width >> l, 1u), h = MAX(t->d.height >> l, 1u), row = w * 2;
        uint8_t *linear = malloc(row * h);
        CHECK(linear != NULL, "linear allocation"); if (!linear) exit(2);
        CHECK(!nvn_deswizzle(&t->d, l, 0, t->mem, linear, row), "CPU layout decode");
        for (size_t i = 0; i < row * h; i++) bad += linear[i] != (i % 2 ? 128 + l : 64 + l);
        free(linear);
    }
    return bad;
}
static void verify_gpu(const tex_t *t, uint64_t fence) {
    id owner = tex_get(t->serial);
    id<MTLTexture> image = [owner isKindOfClass:[NvPkg class]] ? ((NvPkg *)owner)->tex : owner;
    CHECK(image != nil, "retained GPU image exists");
    size_t rows[6], offsets[6], bytes = 0;
    for (unsigned l = 0; l < 6; l++) {
        rows[l] = ((MAX(t->d.width >> l, 1u) * 2) + 255) & ~255ul;
        offsets[l] = bytes; bytes += rows[l] * MAX(t->d.height >> l, 1u);
    }
    id<MTLBuffer> read = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    [cb encodeWaitForEvent:g_ev value:fence];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    for (unsigned l = 0; l < 6; l++) {
        size_t w = MAX(t->d.width >> l, 1u), h = MAX(t->d.height >> l, 1u);
        [blit copyFromTexture:image sourceSlice:0 sourceLevel:l sourceOrigin:MTLOriginMake(0,0,0)
                   sourceSize:MTLSizeMake(w,h,1) toBuffer:read destinationOffset:offsets[l]
          destinationBytesPerRow:rows[l] destinationBytesPerImage:rows[l]*h];
    }
    [blit endEncoding];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) { (void)completed; dispatch_semaphore_signal(done); }];
    [cb commit]; checkpoint(done);
    CHECK(cb.status == MTLCommandBufferStatusCompleted && !cb.error, "cross-queue image readback completed");
    unsigned bad = 0;
    for (unsigned l = 0; l < 6; l++) {
        size_t w = MAX(t->d.width >> l, 1u), h = MAX(t->d.height >> l, 1u);
        for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w*2; x++)
            bad += ((uint8_t *)read.contents)[offsets[l] + y*rows[l] + x] != (x % 2 ? 128+l : 64+l);
    }
    CHECK(!bad, "all actual GPU mip texels match the independent literal values");
}
typedef struct { NVNmemoryPool *pool; size_t offset, size; } invalidation;
static void *invalidate_worker(void *opaque) {
    const invalidation *r = opaque;
    h_nvnMemoryPoolInvalidateMappedRange(r->pool, r->offset, r->size);
    return NULL;
}
static void scenario(int mode) { @autoreleasepool {
    // Modes: #604 control, GPU-owned, delayed-publication stress, concurrent invalidate.
    mtl_init(); state_reset(); memset(&R, 0, sizeof R);
    const size_t bytes = 1u << 20, offset = 65536;
    uint8_t *mem = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    CHECK(mem != MAP_FAILED, "anonymous synthetic storage"); if (mem == MAP_FAILED) exit(2);
    pool_t pool = {0};
    pool_builder_t pb = {.mem=mem, .size=bytes, .flags=NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&pool, (NVNmemoryPoolBuilder *)&pb), "pool initialized");
    NVNtextureBuilder b; NVNtexture texture = {0};
    h_nvnTextureBuilderSetDefaults(&b);
    h_nvnTextureBuilderSetWidth(&b, 37); h_nvnTextureBuilderSetHeight(&b, 29);
    h_nvnTextureBuilderSetLevels(&b, 6); h_nvnTextureBuilderSetFormat(&b, NVN_FORMAT_RG8);
    h_nvnTextureBuilderSetFlags(&b, NVN_TEXTURE_FLAGS_MINIMAL_LAYOUT);
    h_nvnTextureBuilderSetStorage(&b, (NVNmemoryPool *)&pool, offset);
    CHECK(h_nvnTextureInitialize(&texture, &b), "texture initialized");
    tex_t *t = (tex_t *)&texture;
    if (mode == 0 || mode == 2) {
        // Exercise the real CPU-write/classification API, independent of profile switches.
        uint8_t zeros[37 * 29 * 2] = {0};
        NVNcopyRegion region = {0, 0, 0, 37, 29, 1};
        h_nvnTextureWriteTexels(&texture, NULL, &region, zeros);
    }
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    if (mode == 2) {
        dispatch_async(g_feedback_q, ^{
            dispatch_semaphore_signal(entered);
            if (dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, 10000000000ll))) _Exit(2);
        });
        checkpoint(entered);
    }
    mtl_sub_begin();
    for (unsigned l = 0; l < t->d.levels; l++) {
        R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = t;
        R.rt.has_cview[0] = 1; R.rt.cview[0] = (view_t){.set_levels=1, .base_level=(int)l};
        R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake((64+l)/255., (128+l)/255., 0, 1);
        CHECK(rp_begin() != nil, "actual GPU mip render pass"); rp_end();
    }
    CHECK(!!mtl_tex_gpu_owned(t->serial) == (mode == 1 || mode == 3), "actual texture ownership classification");
    uint64_t fence = mtl_sub_commit();
    if (mode == 2) {
        // Exact GPU signal; feedback/publication is still gated. No unsynchronized
        // CPU/GPU write: the CPU writes only after all GPU access completed.
        CHECK([g_ev waitUntilSignaledValue:fence timeoutMS:5000], "producer GPU completed before CPU write");
        dm_guest_write_prepare(t->mem, t->L.size);
        memset(t->mem, 0xa7, t->L.size);
        dispatch_semaphore_signal(release);
    }
    CHECK(mtl_wait(fence, 5000000000ull), "producer CPU effects completed");
    verify_gpu(t, fence);
    if (mode == 3) {
        invalidation range = {(NVNmemoryPool *)&pool, offset, t->L.size};
        pthread_t workers[8]; unsigned started = 0;
        for (; started < 8; started++) if (pthread_create(&workers[started], NULL, invalidate_worker, &range)) break;
        CHECK(started == 8, "eight independent invalidators started");
        for (unsigned i = 0; i < started; i++) CHECK(!pthread_join(workers[i], NULL), "invalidator joined");
    } else h_nvnMemoryPoolInvalidateMappedRange((NVNmemoryPool *)&pool, offset, t->L.size);
    CHECK(!mtl_last_commit_error(), "no GPU execution error");
    if (mode == 2) {
        size_t bad = 0;
        for (size_t i = 0; i < t->L.size; i++) bad += t->mem[i] != 0xa7;
        printf("CPU-newer bytes overwritten: %zu / %llu\n", bad, (unsigned long long)t->L.size);
        CHECK(!bad, "newer CPU bytes survive delayed GPU publication");
    } else {
        unsigned bad = mismatches(t, t->d.levels);
        printf("GPU-to-CPU texel-byte mismatches: %u\n", bad);
        CHECK(!bad, "every rendered mip visible to CPU after invalidate");
    }
    h_nvnTextureFinalize(&texture); h_nvnMemoryPoolFinalize((NVNmemoryPool *)&pool);
    CHECK(!mtl_cpu_tex_count(), "texture retirement clears live CPU membership");
    munmap(mem, bytes);
    printf("pool_visibility_repro mode=%d checks=%u failures=%u\n", mode, checks, failures);
} }
int main(int argc, char **argv) {
    int mode = argc > 1 ? atoi(argv[1]) : 0;
    int repeats = argc > 2 ? atoi(argv[2]) : 1;
    if (mode < 0 || mode > 3 || repeats < 1 || repeats > 100) return 2;
    // Optional isolation control for the existing seg_ts lazy-init race.
    if (getenv("DM_REPRO_PRIME_TS")) (void)seg_ts();
    for (int i = 0; i < repeats; i++) scenario(mode);
    return failures != 0;
}
