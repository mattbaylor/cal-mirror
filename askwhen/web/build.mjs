// esbuild, and nothing else.
//
// The bundler question in web/README.md, answered: esbuild. It is one
// dependency, it needs no config file, and its output is a single file per
// entry point — which is what makes the "no third-party requests" property
// checkable by reading the artifact instead of trusting the toolchain.
//
// `docs/` stays hand-written and build-step-free. The two do not meet.

import { build } from 'esbuild';
import { cp, mkdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const dev = process.argv.includes('--dev');

await rm(here('dist'), { recursive: true, force: true });
await mkdir(here('dist'), { recursive: true });

await build({
  entryPoints: {
    app: here('src/main.js'),
    gallery: here('src/gallery.js'),
  },
  outdir: here('dist'),
  bundle: true,
  format: 'iife',
  target: ['es2022', 'safari16', 'firefox115', 'chrome110'],
  minify: !dev,
  sourcemap: dev,
  legalComments: 'inline',
  logLevel: 'info',
});

await cp(here('index.html'), here('dist/index.html'));
await cp(here('gallery.html'), here('dist/gallery.html'));
