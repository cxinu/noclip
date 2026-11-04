#version 330 core

in vec4 fragColor;
in float fragDist;

uniform vec3 fogColor;
uniform vec2 fogRange; // (near, far)

out vec4 finalColor;

void main() {
    float f = clamp((fogRange.y - fragDist) / (fogRange.y - fogRange.x), 0.0, 1.0);
    finalColor = vec4(mix(fogColor, fragColor.rgb, f), 1.0);
}
