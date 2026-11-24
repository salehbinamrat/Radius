import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as fs from 'node:fs';

const root = new URL('../../src/RadiusManager.Api/frontend/', import.meta.url);
const pkg = JSON.parse(readFileSync(new URL('package.json', root), 'utf8'));
const cfg = readFileSync(new URL('vite.config.ts', root), 'utf8');
const types = JSON.parse(readFileSync(new URL('tsconfig.json', root), 'utf8'));
const pipeline = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const docker = readFileSync(new URL('../../src/RadiusManager.Api/Dockerfile', import.meta.url), 'utf8');

test('React 19, Vite 8 and TypeScript 7: stable exact versions, matched runtime and types', () => {
  assert.equal(pkg.dependencies.react, '19.3.1');
  assert.equal(pkg.dependencies['react-dom'], '19.3.1');
  assert.equal(pkg.devDependencies['@types/react'], '19.3.0');
  assert.equal(pkg.devDependencies['@types/react-dom'], '19.3.0');
  assert.equal(pkg.devDependencies.vite, '8.3.8');
  assert.equal(pkg.devDependencies['@vitejs/plugin-react'], '6.3.0');
  assert.equal(pkg.devDependencies.typescript, '7.0.2');
  for (const version of [...Object.values(pkg.dependencies),
    ...Object.values(pkg.devDependencies)]) {
    assert.match(version, /^\d+\.\d+\.\d+$/, 'pin exact stable dependency version');
  }
  assert.equal(pkg.private, true);
});
test('retain TS strict mode and offline single entrypoint for CSP', () => {
  assert.equal(types.compilerOptions.strict, true);
  assert.equal(types.compilerOptions.noEmit, true);
  assert.equal(types.compilerOptions.moduleResolution, 'Bundler');
  assert.match(cfg, /noc-react\.mjs/);
  assert.match(cfg, /emptyOutDir:\s*true/);
  assert.match(cfg, /src\/main\.tsx/);
  assert.doesNotMatch(cfg, /https?:\/\/|cdn\./);
});
test('same supported Node LTS major on CI and Docker, no bypassed TS checks', () => {
  assert.match(pipeline, /node-version:\s*'24'/);
  const pinnedNodeImage = /^FROM node:24-bookworm-slim@sha256:[a-f0-9]{64} AS ui-build$/m;
  assert.match(docker, pinnedNodeImage);
  assert.doesNotMatch('FROM node:24-bookworm-slim AS ui-build', pinnedNodeImage);
  assert.doesNotMatch('FROM node:24-bookworm-slim@sha256:123 AS ui-build', pinnedNodeImage);
  assert.doesNotMatch('FROM node:22-bookworm-slim@sha256:' + 'a'.repeat(64) + ' AS ui-build', pinnedNodeImage);
  assert.match(docker, /npm run check && npm run build/);
  assert.match(pipeline, /npm run check/);
  assert.match(pipeline, /node --check/);
});

test('Docker UI stage includes every shared wwwroot model imported by React and its types', () => {
  const { readdirSync } = fs;
  const stage = docker.split(/\nFROM /)[0];
  const copied = new Set(stage.split('\n')
    .filter(line => line.startsWith('COPY ') && line.endsWith(' /ui/wwwroot/'))
    .flatMap(line => line.trim().split(/\s+/).slice(1, -1)));
  const src = new URL('src/', root);
  const modules = readdirSync(src, { recursive: true }).filter(name => /\.[cm]?[jt]sx?$/.test(name));
  const dependencies = new Set();
  for (const file of modules) {
    const code = readFileSync(new URL(file, src), 'utf8');
    for (const match of code.matchAll(/['"](?:\.\.\/)+wwwroot\/([^'"]+\.mjs)['"]/g))
      dependencies.add(match[1]);
  }
  assert.ok(dependencies.has('capacity-utils.mjs'));
  assert.ok(dependencies.has('live-status-model.mjs'));
  for (const name of dependencies) {
    assert.ok(copied.has('wwwroot/' + name), name + ' missing from Docker UI build stage');
    const declarations = name.replace(/\.mjs$/, '.d.mts');
    assert.ok(copied.has('wwwroot/' + declarations), declarations + ' missing from Docker UI build stage');
    assert.ok(fs.existsSync(new URL('../wwwroot/' + declarations, root)));
  }
});
