// Render a batch of Markdown math spans with the installed MathJax bundle.
// SPDX-License-Identifier: GPL-3.0-or-later

const fs = require("node:fs");
const path = require("node:path");

const bundle = path.resolve(process.argv[2]);
const loadComponent = (file) => {
  if (file === "node:worker_threads") return require(file);
  const resolved = path.resolve(file);
  if (!resolved.startsWith(bundle + path.sep)) {
    throw new Error("MathJax component must come from the local bundle");
  }
  return require(resolved);
};

// Fixed packages supply common mathematical notation without allowing a
// document to load extensions or inject HTML through TeX macros.
global.MathJax = {
  loader: {
    paths: { mathjax: bundle },
    load: ["adaptors/liteDOM", "[tex]/boldsymbol", "[tex]/mathtools", "[tex]/cancel"],
    require: loadComponent,
  },
  startup: { typeset: false },
  tex: {
    packages: ["base", "ams", "newcommand", "boldsymbol", "mathtools", "cancel"],
    formatError: (_jax, error) => { throw error; },
  },
  svg: { fontCache: "local" },
  options: { enableSpeech: false },
};

loadComponent(path.join(bundle, "tex-svg.js"));

async function render({ tex, display }) {
  try {
    const adaptor = MathJax.startup.adaptor;
    const node = await MathJax.tex2svgPromise(tex, { display });
    const svg = adaptor.tags(node, "svg")[0];
    const [, top, width, height] = adaptor.getAttribute(svg, "viewBox").split(/\s+/).map(Number);
    if (!(width > 0 && height > 0)) return null;

    // Preserve the baseline and use pixel dimensions for native SVG images.
    adaptor.setAttribute(svg, "width", String(16 * width / 1000));
    adaptor.setAttribute(svg, "height", String(16 * height / 1000));
    return {
      svg: adaptor.outerHTML(svg),
      ems: width / 1000,
      ascent: Math.max(0, Math.min(100, Math.round(-100 * top / height))),
    };
  } catch {
    return null;
  }
}

async function main() {
  const expressions = JSON.parse(fs.readFileSync(0, "utf8"));
  await MathJax.startup.promise;
  const results = [];
  for (const expression of expressions) results.push(await render(expression));

  // The standalone process also owns MathJax's auxiliary worker threads.
  process.stdout.write(JSON.stringify(results), () => process.exit(0));
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
