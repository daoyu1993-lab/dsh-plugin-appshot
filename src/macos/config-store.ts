/**
 * src/macos/config-store.ts — macOS 配置持久化（用户级 JSON 文件）。
 *
 * 为什么不再走 ctx.settings：DSH 0.2.0-rc.2 的 settings 服务只按 profile 条目 id
 * 暴露 `.volatile()` 字段，0.1.x 的 `settings.register(ns, schema)` 已不存在。
 * 旧实现调用 `settings.update('appshot', patch)` 返回 rejected Promise，未被捕获时
 * 直接终止宿主进程（两次崩溃证据见 docs/api-grounded-review.md §3.7）。
 * 这里改为插件自持文件，读写失败只告警，不影响截图主链路。
 * - 位置：$DSH_HOME/plugins/appshot/config.json（无 DSH_HOME 时 ~/.dsh/plugins/appshot/config.json）；
 * - 读取宽容：文件不存在、JSON 损坏或字段非法一律回退默认值，不阻断启动；
 * - 写入原子：tmp 文件 + rename 覆盖，失败返回 false（内存配置仍然生效）。
 */

import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import type { AppshotConfig } from '../shared/types.ts'

/** macOS Native Agent 支持的触发方式（与 native/macos/Sources/main.swift 的 switch 一致）。 */
const MAC_SHORTCUT_MODES: readonly AppshotConfig['shortcutMode'][] = [
  'dual-cmd',
  'double-cmd',
  'dual-option',
  'double-option',
  'dual-control',
  'double-control',
  'cmd-option',
]

export const DEFAULT_MACOS_CONFIG: AppshotConfig = {
  platform: 'darwin',
  shortcutMode: 'dual-cmd',
  soundEnabled: true,
  animationEnabled: true,
  regionShortcutEnabled: true,
}

/** 默认持久化路径：DSH home 下的插件目录；无 DSH_HOME 时回退 ~/.dsh。 */
export function resolveConfigStorePath(): string {
  const home = process.env.DSH_HOME && process.env.DSH_HOME.trim() !== ''
    ? process.env.DSH_HOME
    : join(homedir() || tmpdir(), '.dsh')
  return join(home, 'plugins', 'appshot', 'config.json')
}

/** 白名单字段校验：只接受已知枚举与布尔值，任何非法字段丢弃（不影响其余字段）。 */
export function sanitizeMacosConfig(raw: unknown): AppshotConfig | null {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return null
  const source = raw as Record<string, unknown>
  const config: AppshotConfig = {}
  if (typeof source.shortcutMode === 'string' && (MAC_SHORTCUT_MODES as readonly string[]).includes(source.shortcutMode)) {
    config.shortcutMode = source.shortcutMode as AppshotConfig['shortcutMode']
  }
  if (typeof source.soundEnabled === 'boolean') config.soundEnabled = source.soundEnabled
  if (typeof source.animationEnabled === 'boolean') config.animationEnabled = source.animationEnabled
  if (typeof source.regionShortcutEnabled === 'boolean') config.regionShortcutEnabled = source.regionShortcutEnabled
  return Object.keys(config).length > 0 ? config : null
}

/** 同步读取持久化配置；不存在/损坏/字段全非法时返回默认值（不抛出）。 */
export function loadMacosConfig(path: string): AppshotConfig {
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, 'utf-8'))
    const persisted = sanitizeMacosConfig(parsed)
    return persisted === null ? { ...DEFAULT_MACOS_CONFIG } : { ...DEFAULT_MACOS_CONFIG, ...persisted }
  } catch {
    return { ...DEFAULT_MACOS_CONFIG }
  }
}

/** 原子写持久化配置；成功返回 true，失败返回 false（不抛出）。 */
export function saveMacosConfig(path: string, config: AppshotConfig): boolean {
  const temp = `${path}.${process.pid}.tmp`
  try {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(temp, JSON.stringify(config, null, 2) + '\n', { encoding: 'utf-8', mode: 0o600 })
    renameSync(temp, path)
    return true
  } catch {
    try {
      rmSync(temp, { force: true })
    } catch {
      // 清理失败无需处理：临时文件位于插件自有目录，下次写入会覆盖
    }
    return false
  }
}
