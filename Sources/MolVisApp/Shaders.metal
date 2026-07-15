#include <metal_stdlib>
using namespace metal;

struct VertexIn  { float3 position  [[attribute(0)]]; float3 normal  [[attribute(1)]]; };
struct LineVertexIn { float3 position [[attribute(0)]]; };

struct InstanceData { float4x4 model; float4 color; float radius; float metalness; };
struct FrameData    { float4x4 view; float4x4 proj; float3 lightDir; };

struct VInOut  { float4 position [[position]]; float3 worldPos; float3 normal; float3 color; };
struct LineVOut { float4 position [[position]]; float3 color; };

float3x3 normalMatrix3x3(float3x3 m) {
    float a = m[0][0], b = m[1][0], c = m[2][0];
    float d = m[0][1], e = m[1][1], f = m[2][1];
    float g = m[0][2], h = m[1][2], k = m[2][2];
    float c00 = e*k - f*h, c01 = -(d*k - f*g), c02 = d*h - e*g;
    float c10 = -(b*k - c*h), c11 = a*k - c*g, c12 = -(a*h - b*g);
    float c20 = b*f - c*e, c21 = -(a*f - c*d), c22 = a*e - b*d;
    float det = a*c00 + b*c01 + c*c02;
    if (abs(det) < 1e-12) return float3x3(1.0);
    return float3x3(float3(c00, c10, c20) / det,
                    float3(c01, c11, c21) / det,
                    float3(c02, c12, c22) / det);
}

vertex VInOut v_main(VertexIn in [[stage_in]],
                     constant InstanceData *insts [[buffer(1)]],
                     constant FrameData &f [[buffer(2)]],
                     uint iid [[instance_id]]) {
    VInOut o;
    constant InstanceData &inst = insts[iid];
    float4 world = inst.model * float4(in.position * inst.radius, 1.0);
    o.worldPos = world.xyz;
    float3x3 model3 = float3x3(inst.model[0].xyz, inst.model[1].xyz, inst.model[2].xyz);
    o.normal = normalMatrix3x3(model3) * in.normal;
    o.color = inst.color.rgb;
    o.position = f.proj * f.view * world;
    return o;
}

fragment float4 f_main(VInOut in [[stage_in]], constant FrameData &f [[buffer(2)]]) {
    float3 N = normalize(in.normal);
    float3 L = normalize(f.lightDir);
    float diff = max(dot(N, L), 0.0);
    float3 ambient = in.color.rgb * 0.35;
    float3 diffuse = in.color.rgb * diff * 0.65;
    return float4(ambient + diffuse, 1.0);
}

vertex LineVOut lv_main(LineVertexIn in [[stage_in]],
                        constant FrameData &f [[buffer(2)]],
                        constant float3 &color [[buffer(3)]]) {
    LineVOut o; o.color = color; o.position = f.proj * f.view * float4(in.position, 1.0); return o;
}

fragment float4 lf_main(LineVOut in [[stage_in]]) { return float4(in.color, 1.0); }
