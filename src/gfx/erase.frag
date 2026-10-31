#version 450
layout(set=3,binding=0) uniform Window { vec4 size_radius; } window;
layout(location=0) out vec4 outputColor;
void main() {
    vec2 size = window.size_radius.xy;
    float r = min(window.size_radius.z, min(size.x, size.y) * 0.5);
    vec2 q = abs(gl_FragCoord.xy - size * 0.5) - (size * 0.5 - r);
    float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    float coverage = clamp(0.5 - distance, 0.0, 1.0);
    outputColor = vec4(0.0, 0.0, 0.0, coverage);
}
