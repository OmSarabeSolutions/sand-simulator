#include <metal_stdlib>
using namespace metal;

// Paramètres partagés avec Swift (voir GPUSandpile.swift, même disposition mémoire).
struct ToppleParams {
    uint width;
    uint height;
    uint threshold;
    uint pad;
};

struct DivisibleParams {
    uint width;
    uint height;
    float epsilon;
    float pad;
};

// Nombre de bascules simultanées d'une case portant h grains : une case à h >= T
// bascule k fois de sorte que h - 4k < T.
inline uint fires(uint h, uint t) {
    return h >= t ? (h - t) / 4 + 1 : 0;
}

// Une ronde de bascules parallèles du tas abélien.
// h' = h - 4 k(h) + somme des k des voisines (les voisines hors grille ne donnent rien).
kernel void topple(device const uint *src        [[buffer(0)]],
                   device uint *dst              [[buffer(1)]],
                   device atomic_uint *unstable  [[buffer(2)]],
                   constant ToppleParams &p      [[buffer(3)]],
                   uint2 gid                     [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint i = gid.y * p.width + gid.x;
    uint h = src[i];
    uint v = h - 4 * fires(h, p.threshold);
    if (gid.x > 0)            v += fires(src[i - 1], p.threshold);
    if (gid.x + 1 < p.width)  v += fires(src[i + 1], p.threshold);
    if (gid.y > 0)            v += fires(src[i - p.width], p.threshold);
    if (gid.y + 1 < p.height) v += fires(src[i + p.width], p.threshold);
    dst[i] = v;
    if (v >= p.threshold) {
        atomic_store_explicit(unstable, 1u, memory_order_relaxed);
    }
}

// Excès qu'une case du tas divisible envoie à chacune de ses quatre voisines.
inline float share(float m) {
    return max(m - 1.0f, 0.0f) * 0.25f;
}

// Une ronde du tas divisible : chaque case pleine garde 1 et partage son excès.
kernel void divisible(device const float *src      [[buffer(0)]],
                      device float *dst            [[buffer(1)]],
                      device atomic_uint *unstable [[buffer(2)]],
                      constant DivisibleParams &p  [[buffer(3)]],
                      uint2 gid                    [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint i = gid.y * p.width + gid.x;
    float v = min(src[i], 1.0f);
    if (gid.x > 0)            v += share(src[i - 1]);
    if (gid.x + 1 < p.width)  v += share(src[i + 1]);
    if (gid.y > 0)            v += share(src[i - p.width]);
    if (gid.y + 1 < p.height) v += share(src[i + p.width]);
    dst[i] = v;
    if (v > 1.0f + p.epsilon) {
        atomic_store_explicit(unstable, 1u, memory_order_relaxed);
    }
}
