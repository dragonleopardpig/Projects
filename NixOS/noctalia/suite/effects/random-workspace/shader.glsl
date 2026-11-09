vec4 animation(vec2 uv) {
  float progress = umbriel_clamped_progress;
  if (progress <= 0.0)
    return umbriel_sample(uv);
  if (progress >= 1.0)
    return umbriel_sample_incoming(uv);

  // Fade, horizontal wipe, vertical wipe, radial reveal, then three slides.
  float variant = floor(umbriel_random_seed.x * 7.0);
  if (variant >= 4.0) {
    vec2 direction = variant < 5.0 ? vec2(0.0, 1.0)
                   : variant < 6.0 ? vec2(-1.0, 0.0)
                                   : vec2(1.0, 0.0);
    vec2 outgoing_uv = uv - direction * progress;
    if (all(greaterThanEqual(outgoing_uv, vec2(0.0))) &&
        all(lessThanEqual(outgoing_uv, vec2(1.0))))
      return umbriel_sample(outgoing_uv);
    return umbriel_sample_incoming(uv + direction * (1.0 - progress));
  }

  vec4 outgoing = umbriel_sample(uv);
  vec4 incoming = umbriel_sample_incoming(uv);
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
