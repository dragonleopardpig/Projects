vec4 animation(vec2 uv) {
  float visible = umbriel_direction > 0.0
      ? umbriel_clamped_progress
      : 1.0 - umbriel_clamped_progress;
  if (visible <= 0.0)
    return vec4(0.0);
  if (visible >= 1.0)
    return umbriel_sample(uv);

  float variant = floor(umbriel_random_seed.x * 4.0);
  float mask = visible;
  if (variant >= 1.0 && variant < 2.0) {
    float coordinate = umbriel_random_seed.y < 0.5 ? uv.x : 1.0 - uv.x;
    float edge = mix(-0.03, 1.03, visible);
    mask = 1.0 - smoothstep(edge - 0.025, edge + 0.025, coordinate);
  } else if (variant >= 2.0 && variant < 3.0) {
    float coordinate = umbriel_random_seed.y < 0.5 ? uv.y : 1.0 - uv.y;
    float edge = mix(-0.03, 1.03, visible);
    mask = 1.0 - smoothstep(edge - 0.025, edge + 0.025, coordinate);
  } else if (variant >= 3.0) {
    float edge = mix(-0.03, 0.77, visible);
    mask = 1.0 - smoothstep(edge - 0.025, edge + 0.025, distance(uv, vec2(0.5)));
  }
  return umbriel_sample(uv) * mask;
}
