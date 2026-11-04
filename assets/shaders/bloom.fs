#version 330 core

// Single-pass bloom: bright-pass + 5x5 gaussian, rendered at reduced resolution.

in vec2 fragTexCoord;

uniform sampler2D texture0; // full-resolution scene
uniform vec2 texelSize;     // 1.0 / bloom resolution
uniform float threshold;

out vec4 finalColor;

const float knee = 0.2;

vec3 bright(vec3 c) {
    float l = max(c.r, max(c.g, c.b));
    float soft = clamp(l - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    return c * (max(soft, l - threshold) / max(l, 1e-4));
}

// 5-tap gaussian weights (0.0625, 0.25, 0.375, 0.25, 0.0625)
float weight(int i) {
    int a = abs(i);
    return a == 0 ? 0.375 : (a == 1 ? 0.25 : 0.0625);
}

void main() {
    vec3 sum = vec3(0.0);
    for (int y = -2; y <= 2; y++) {
        for (int x = -2; x <= 2; x++) {
            vec2 off = vec2(float(x), float(y)) * texelSize;
            sum += bright(texture(texture0, fragTexCoord + off).rgb) * weight(x) * weight(y);
        }
    }
    finalColor = vec4(sum, 1.0);
}
