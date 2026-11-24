#include <flutter/runtime_effect.glsl>

precision highp float;

// Engine-supplied: backdrop size in device pixels, then the backdrop image.
uniform vec2 uSize;
uniform vec4 uRect;
uniform float uRadius;
uniform float uBezel;
uniform float uDisp;
uniform float uDark;
uniform sampler2D uTexture;

out vec4 fragColor;

// Rounded-rect signed distance. Negative values are inside the glass.
float sdRoundBox(vec2 p, vec2 halfSize, float radius) {
  vec2 q = abs(p) - halfSize + radius;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

vec4 sampleBackdrop(vec2 px) {
  vec2 uv = clamp(px / max(uSize, vec2(1.0)), 0.0, 1.0);
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uTexture, uv);
}

vec2 safeNormal(vec2 v) {
  float len = length(v);
  return len < 0.0001 ? vec2(0.0, -1.0) : v / len;
}

void main() {
  vec2 px = FlutterFragCoord().xy;
  vec2 center = uRect.xy + uRect.zw * 0.5;
  vec2 halfSize = max(uRect.zw * 0.5, vec2(1.0));
  vec2 local = px - center;
  float dist = sdRoundBox(local, halfSize, max(uRadius, 1.0));
  vec4 source = sampleBackdrop(px);

  // Outside the body, leave the backdrop alone. The clip already hides this.
  if (dist >= 1.0) {
    fragColor = source;
    return;
  }

  float bezel = max(uBezel, 1.0);
  float depth = clamp(-dist / bezel, 0.0, 1.0);
  // Bend only the rim. The middle stays a clear, lightly veiled sample so
  // controls drawn on top of this filter keep a stable background.
  float bend = (1.0 - depth);
  bend = bend * bend;

  vec2 probe = vec2(0.75, 0.0);
  float dx = sdRoundBox(local + probe.xy, halfSize, uRadius) -
      sdRoundBox(local - probe.xy, halfSize, uRadius);
  float dy = sdRoundBox(local + probe.yx, halfSize, uRadius) -
      sdRoundBox(local - probe.yx, halfSize, uRadius);
  vec2 off = -safeNormal(vec2(dx, dy)) * bend * uDisp;

  // A small red/blue split at the rim suggests thickness. It fades out
  // before the middle, so it does not fringe the controls.
  float chroma = 0.28 * bend;
  vec3 bent = vec3(
    sampleBackdrop(px + off * (1.0 - chroma)).r,
    sampleBackdrop(px + off).g,
    sampleBackdrop(px + off * (1.0 + chroma)).b
  );
  vec3 soft = (
    sampleBackdrop(px + off + vec2(1.2, 0.0)).rgb +
    sampleBackdrop(px + off - vec2(1.2, 0.0)).rgb +
    sampleBackdrop(px + off + vec2(0.0, 1.2)).rgb +
    sampleBackdrop(px + off - vec2(0.0, 1.2)).rgb
  ) * 0.25;
  vec3 glass = mix(bent, soft, 0.4);

  float luma = dot(glass, vec3(0.2126, 0.7152, 0.0722));
  glass = mix(vec3(luma), glass, 1.28);

  // Light glass is a thin white wash. Dark glass is a thin cool black wash,
  // not an opaque card.
  vec3 veil = mix(vec3(1.0), vec3(0.10, 0.10, 0.12), clamp(uDark, 0.0, 1.0));
  float veilAmount = mix(0.16, 0.24, clamp(uDark, 0.0, 1.0));
  glass = mix(glass, veil, veilAmount);

  float cover = clamp(0.5 - dist, 0.0, 1.0);
  fragColor = vec4(mix(source.rgb, glass, cover), 1.0);
}
