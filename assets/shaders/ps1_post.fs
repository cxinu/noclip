#version 330 core

in vec2 fragTexCoord;

uniform sampler2D texture0; // scene at internal resolution
uniform sampler2D bloomTex; // blurred bloom
uniform int color_depth;    // bits per channel (1..8)
uniform int dithering;      // 0 / 1
uniform float gamma;        // output gamma (1.0 = off, >1 lifts darks)
uniform float bloomStrength;

out vec4 finalColor;

const int pattern[16] = int[16](
    -4,  0, -3,  1,
     2, -2,  3, -1,
    -3,  1, -4,  0,
     3, -1,  2, -2
);

void main() {
    int depth = clamp(color_depth, 1, 8);
    float g = max(gamma, 0.001);

    // nearest sample of the low-res scene
    ivec2 size = textureSize(texture0, 0);
    ivec2 px = clamp(ivec2(fragTexCoord * vec2(size)), ivec2(0), size - 1);
    vec3 color = texelFetch(texture0, px, 0).rgb;

    // additive bloom, then gamma encode
    color += texture(bloomTex, fragTexCoord).rgb * bloomStrength;
    color = pow(color, vec3(1.0 / g));

    // quantise to N bits with ordered dithering
    ivec3 c = ivec3(round(clamp(color, 0.0, 1.0) * 255.0));
    if (dithering != 0) {
        c += ivec3(pattern[(px.y % 4) * 4 + (px.x % 4)]);
    }

    c = clamp(c, 0, 255);
    c >>= (8 - depth);
    finalColor = vec4(vec3(c) / float((1 << depth) - 1), 1.0);
}
