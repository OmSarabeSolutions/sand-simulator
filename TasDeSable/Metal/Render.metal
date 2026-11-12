#include <metal_stdlib>
using namespace metal;

// Même disposition que RenderUniforms dans SandpileRenderer.swift.
struct RenderUniforms {
    float4x4 viewProjection;
    float4x4 palette;    // colonnes : les quatre couleurs des cases (rgb)
    uint width;
    uint height;
    uint threshold;
    uint flags;          // bit 0 : hauteur affichée ; bit 1 : valeurs = masses (tas divisible)
    float heightScale;   // hauteur d'une colonne pleine, en cases
    float gap;           // marge entre deux colonnes, en fraction de case
    float pad0;
    float pad1;
};

struct VertexOut {
    float4 position [[position]];
    float3 color;
};

constant float3 kNormals[6] = {
    float3(0, 1, 0), float3(0, -1, 0), float3(1, 0, 0),
    float3(-1, 0, 0), float3(0, 0, 1), float3(0, 0, -1)
};

// Quatre coins de chaque face d'un cube unité [0,1]^3.
constant float3 kCorners[6][4] = {
    { float3(0,1,0), float3(0,1,1), float3(1,1,1), float3(1,1,0) },   // dessus
    { float3(0,0,0), float3(1,0,0), float3(1,0,1), float3(0,0,1) },   // dessous
    { float3(1,0,0), float3(1,1,0), float3(1,1,1), float3(1,0,1) },   // +x
    { float3(0,0,0), float3(0,0,1), float3(0,1,1), float3(0,1,0) },   // -x
    { float3(0,0,1), float3(1,0,1), float3(1,1,1), float3(0,1,1) },   // +z
    { float3(0,0,0), float3(0,1,0), float3(1,1,0), float3(1,0,0) }    // -z
};

constant uint kTriangle[6] = { 0, 1, 2, 0, 2, 3 };

// Dégradé entre les quatre couleurs de la palette, pour t dans [0, 1].
// Identique à Palette.ramp côté Swift.
float3 ramp(float4x4 palette, float t) {
    float x = clamp(t, 0.0f, 1.0f) * 3.0f;
    uint i = min(uint(x), 2u);
    return mix(palette[i].rgb, palette[i + 1].rgb, x - float(i));
}

vertex VertexOut cellVertex(uint vid                         [[vertex_id]],
                            uint iid                         [[instance_id]],
                            constant RenderUniforms &u       [[buffer(0)]],
                            device const float *values       [[buffer(1)]]) {
    uint face = vid / 6;
    float3 corner = kCorners[face][kTriangle[vid % 6]];

    float value = values[iid];
    bool isMass = (u.flags & 2u) != 0;
    bool showHeight = (u.flags & 1u) != 0;

    // Niveau normalisé : grains / (T - 1), ou masse bornée à 1.
    float level = isMass ? clamp(value, 0.0f, 1.0f)
                         : value / float(max(u.threshold, 2u) - 1);
    float3 color;
    if (isMass) {
        // Tas divisible : 4e couleur si la case est pleine, sinon 1re → 2e selon la masse.
        color = value >= 0.999f ? u.palette[3].rgb : mix(u.palette[0].rgb, u.palette[1].rgb, level);
    } else {
        color = ramp(u.palette, level);
    }

    float columnHeight = showHeight ? 0.08f + level * u.heightScale : 0.08f;
    float x = float(iid % u.width);
    float z = float(iid / u.width);
    float side = 1.0f - 2.0f * u.gap;
    float3 world = float3(x + u.gap + corner.x * side - float(u.width) * 0.5f,
                          corner.y * columnHeight,
                          z + u.gap + corner.z * side - float(u.height) * 0.5f);

    float3 light = normalize(float3(0.4, 1.0, 0.3));
    float shade = 0.35f + 0.65f * max(dot(kNormals[face], light), 0.0f);

    VertexOut out;
    out.position = u.viewProjection * float4(world, 1.0);
    out.color = color * shade;
    return out;
}

fragment float4 cellFragment(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
