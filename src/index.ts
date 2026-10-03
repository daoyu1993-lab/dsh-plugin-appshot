/**
 * src/index.ts — 宿主插件入口（平台分流 + 公开面）。
 *
 * - win32 → Windows Basic 路径（src/windows/）
 * - 其余 → macOS 路径（src/macos/）
 * - 跨平台类型在 src/shared/types.ts
 */

import type { Context } from '@deepseek-ai/cordis'
import { applyMacos, disposeMacos } from './macos/index.ts'
import { applyWindows, type WindowsPluginRuntime } from './windows/index.ts'

export const name = 'dsh-plugin-appshot'
// settings 服务自 DSH 0.2.0 起只按 profile 条目 id 暴露 volatile 字段，本插件改为自持配置文件，
// 不再声明 settings 依赖（理由与证据见 src/macos/config-store.ts 头注）。
export const inject = ['attachments', 'webServer', 'sessions']

export interface PluginState {
  windows?: WindowsPluginRuntime
}

let globalState: PluginState = {}

/** 平台分流入口：win32 走 Windows Basic 路径，其余保持 macOS 实现。 */
export function apply(ctx: Context) {
  if (process.platform === 'win32') {
    console.log('[dsh-plugin-appshot] windows platform detected, applying windows runtime...')
    applyWindows(ctx as unknown as Parameters<typeof applyWindows>[0], {})
      .then((runtime) => {
        globalState.windows = runtime
        console.log('[dsh-plugin-appshot] windows runtime applied, staging:', runtime.stagingDir)
      })
      .catch((err) => {
        console.error('[dsh-plugin-appshot] windows runtime apply failed:', err)
      })
    return
  }
  applyMacos(ctx)
}

export function dispose(ctx?: Context) {
  if (globalState.windows) {
    void globalState.windows.dispose()
    globalState.windows = undefined
  }
  disposeMacos()
  console.log('[dsh-plugin-appshot] plugin disposed')
}

// ── 公开面（与既有导出保持一致） ─────────────────────────────────────────
// 注意：宿主入口不再 re-export src/client.ts。客户端组件会 import react（Browser
// 侧由 __ModuleLoader__ 提供），一旦被 esbuild 打进宿主 bundle，Node 侧解析不到
// react 会让整个插件加载失败（ERR_MODULE_NOT_FOUND）。客户端入口见 package.json
// 的 exports["./client"] → dist/client.js。
export { cleanOrphanStagingFiles } from './macos/staging.ts'
export { ingestScreenshot } from './macos/ingest.ts'
export { createAppshotSSEHub } from './macos/sse.ts'
export { createNdjsonParser } from './macos/ipc.ts'
export { startAgent } from './macos/agent.ts'
export { loadMacosConfig, resolveConfigStorePath, sanitizeMacosConfig, saveMacosConfig } from './macos/config-store.ts'
export * from './shared/types.ts'
export { applyWindows } from './windows/index.ts'
