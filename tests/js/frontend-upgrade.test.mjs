import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

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
  assert.match(docker, /FROM node:24-bookworm-slim AS ui-build/);
  assert.match(docker, /npm run check && npm run build/);
  assert.match(pipeline, /npm run check/);
  assert.match(pipeline, /node --check/);
});
