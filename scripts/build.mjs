#!/usr/bin/env node
/**
 * scripts/build.mjs — 双 bundle 构建（宿主 ESM + 客户端 CJS 工厂）。
 *
 * 用 esbuild 的 JS API，不经过 node_modules/.bin：pnpm 在 esbuild 安装脚本被允许之前
 * 生成的 .bin 包装会以 node 执行 bin/esbuild；安装脚本随后把该文件替换成原生可执行文件，
 * 旧包装再跑就是 "SyntaxError: Invalid or unexpected token"。
 * 产物契约不变：
 * - dist/index.js：宿主插件，ESM、仅 node: 内置依赖（不得出现裸 react 等外部包）；
 * - dist/client.js：浏览器侧模块工厂，react 由 __ModuleLoader__ 宿主提供。
 */

import { build } from 'esbuild'

/** 客户端 bundle 的模块工厂包装（与既有产物保持一致）。 */
const CLIENT_BANNER = "window.__ModuleLoader__.load({ id: 'dsh-plugin-appshot', factory: (require) => { var module = { exports: {} }; var exports = module.exports;"
const CLIENT_FOOTER = 'return module.exports; } });'

await build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  platform: 'node',
  format: 'esm',
  packages: 'external',
  outfile: 'dist/index.js',
  logLevel: 'info',
})

await build({
  entryPoints: ['src/client.ts'],
  bundle: true,
  platform: 'browser',
  format: 'cjs',
  external: ['react', 'react-dom', 'react/jsx-runtime'],
  outfile: 'dist/client.js',
  banner: { js: CLIENT_BANNER },
  footer: { js: CLIENT_FOOTER },
  logLevel: 'info',
})
