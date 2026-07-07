#include <metal_stdlib>
using namespace metal;

struct VertexIn  { float3 position  [[attribute(0)]]; float3 normal  [[attribute(1)]]; };
struct LineVertexIn { float3 position [[attribute(0)]]; };

struct InstanceData { float4x4 model; float4 color; float radius; float metalness; };
struct FrameData    { float4x4 view; float4x4 proj; float3 lightDir; };

struct VInOut  { float4 position [[position]]; float3 worldPos; float3 normal; float3 color; };
struct LineVOut { float4 position [[position]]; float3 color; };

vertex VInOut v_main(VertexIn in [[stage_in]],
                     constant InstanceData &inst [[buffer(1)]],
                     constant FrameData &f [[buffer(2)]],
                     uint iid [[instance_id]]) {
    VInOut o;
    float3 p = in.position * inst.radius + inst.model[3].xyz;
    o.worldPos = p;
    o.normal = in.normal;
    o.color = inst.color.rgb;
    o.position = f.proj * f.view * float4(p, 1.0);
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
