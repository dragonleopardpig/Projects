vec4 animation(vec2 uv) {
  float progress = umbriel_clamped_progress;
  vec4 outgoing = umbriel_sample(uv);
  if (progress <= 0.0)
    return outgoing;
  vec4 incoming = umbriel_sample_incoming(uv);
  if (progress >= 1.0)
    return incoming;

  float variant = floor(umbriel_random_seed.x * 4.0);
  float mask = progress;
  if (variant >= 1.0 && variant < 2.0) {
    float coordinate = umbriel_random_seed.y < 0.5 ? uv.x : 1.0 - uv.x;
    float edge = mix(-0.03, 1.03, progress);
    mask = 1.0 - smoothstep(edge - 0.025, edge + 0.025, coordinate);
  } else if (variant >= 2.0 && variant < 3.0) {
    float coordinate = umbriel_random_seed.y < 0.5 ? uv.y : 1.0 - uv.y;
    float edge = mix(-0.03, 1.03, progress);
    mask = 1.0 - smoothstep(edge - 0.025, edge + 0.025, coordinate);
  } else if (variant >= 3.0) {
    vec2 center = mix(vec2(0.35), vec2(0.65), umbriel_random_seed.yz);
    float edge = mix(-0.03, 1.0, progress);
    mask = 1.0 - smoothstep(edge - 0.025, edge + 0.025, distance(uv, center));
  }
  return mix(outgoing, incoming, mask);
}
