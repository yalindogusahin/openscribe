#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vs_main(uint vid [[vertex_id]],
                         const device VertexIn* verts [[buffer(0)]]) {
    VertexOut o;
    o.position = float4(verts[vid].position, 0.0, 1.0);
    o.color = verts[vid].color;
    return o;
}

fragment float4 fs_main(VertexOut in [[stage_in]]) {
    return in.color;
}
