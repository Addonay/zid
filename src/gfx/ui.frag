#version 450
layout(set=2,binding=0) uniform sampler2D atlas;
layout(set=2,binding=1) uniform sampler2D color_atlas;
layout(location=0) in vec2 texcoord;
layout(location=1) in vec4 tint;
layout(location=0) out vec4 outputColor;
void main(){
    // u >= 2 addresses the premultiplied RGBA icon atlas; otherwise a tinted coverage mask.
    if (texcoord.x >= 2.0) {
        vec4 c = texture(color_atlas, texcoord - vec2(2.0, 0.0));
        outputColor = vec4(c.rgb / max(c.a, 1e-5), c.a * tint.a);
    } else {
        outputColor = vec4(tint.rgb, tint.a * texture(atlas, texcoord).r);
    }
}
