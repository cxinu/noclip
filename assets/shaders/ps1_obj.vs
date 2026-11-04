#version 330 core

in vec3 vertexPosition;
in vec4 vertexColor;

uniform mat4 mvp;
uniform float snapFactor;
uniform vec2 resolution;

out vec4 fragColor;
out float fragDist;

void main() {
    fragColor = vertexColor;

    vec4 pos = mvp * vec4(vertexPosition, 1.0);

    // PS1 vertex snapping: quantise NDC to the internal pixel grid
    if (snapFactor > 0.0) {
        vec4 ndc = pos / pos.w;
        vec2 grid = resolution * snapFactor;
        ndc.xy = floor(ndc.xy * grid + 0.5) / grid;
        pos = ndc * pos.w;
    }

    fragDist = pos.w;
    gl_Position = pos;
}
