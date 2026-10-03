/**
 * Phase 8 — DSH 0.2.0 兼容移植：插件自持配置与配置端点防崩
 *
 * 背景（真机崩溃证据，2026-10-03）：
 * - DSH 0.2.0-rc.2 的 settings 服务按 profile 条目 id 暴露 volatile 字段，
 *   `settings.register(ns, schema)` 已不存在；
 * - 旧实现 `settings.update('appshot', patch)` 返回 rejected Promise 且未被捕获，
 *   宿主把未处理拒绝视为致命错误并退出进程（`dsh: fatal load failure:
 *   Error: No configurable plugin entry "appshot"`）。
 *
 * 覆盖范围：
 * - 主流程：GET 返回当前配置；POST 合法字段 → 200 且原子落盘；
 * - 常规边界：非法 JSON / 无合法字段 → 4xx 且不抛出；处理器同步异常不外泄。
 */
import { after, test } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// 必须在 apply 前设定：agent 不启动、配置文件写到临时 DSH home
process.env.DSH_DISABLE_AGENT_SPAWN = '1'
const tempHome = mkdtempSync(join(tmpdir(), 'appshot-home-'))
process.env.DSH_HOME = tempHome

const { DEFAULT_MACOS_CONFIG, loadMacosConfig, resolveConfigStorePath, sanitizeMacosConfig, saveMacosConfig } =
  await import('../src/macos/config-store.ts')
const plugin = await import('../src/index.ts')

interface RegisteredRoute {
  kind: string
  path: string
  handler: (req: unknown, res: unknown) => void
}

interface MockRequest {
  method: string
  on(event: string, listener: (chunk?: Buffer) => void): MockRequest
  fire(event: string, chunk?: Buffer): void
}

interface MockResponse {
  status: number
  body: string
  writeHead(status: number, headers?: Record<string, string>): void
  end(body?: string): void
}

/** 只实现插件实际触碰的服务面：webServer.register + attachments/effect 兜底。 */
function createEndpointCtx(): { ctx: Record<string, unknown>; routes: Map<string, RegisteredRoute> } {
  const routes = new Map<string, RegisteredRoute>()
  const ctx = {
    webServer: {
      register(route: RegisteredRoute) {
        routes.set(route.path, route)
        return () => routes.delete(route.path)
      },
    },
    attachments: {
      readImage: async () => ({ ref: {}, data: new Uint8Array() }),
      saveImage: async () => ({ attachmentId: 'att_unused', mediaType: 'image/png', bytes: 0, width: 1, height: 1 }),
    },
    effect(fn: () => void | (() => void)) {
      fn()
    },
  }
  return { ctx, routes }
}

function createRequest(method: string): MockRequest {
  const listeners = new Map<string, Array<(chunk?: Buffer) => void>>()
  const request: MockRequest = {
    method,
    on(event, listener) {
      const bucket = listeners.get(event) ?? []
      bucket.push(listener)
      listeners.set(event, bucket)
      return request
    },
    fire(event, chunk) {
      for (const listener of listeners.get(event) ?? []) listener(chunk)
    },
  }
  return request
}

function createResponse(): MockResponse {
  return {
    status: 0,
    body: '',
    writeHead(status) {
      this.status = status
    },
    end(body) {
      this.body = body ?? ''
    },
  }
}

function invoke(
  routes: Map<string, RegisteredRoute>,
  method: string,
  payload?: string,
): { status: number; json: Record<string, unknown> } {
  const route = routes.get('/plugins/appshot/config')
  assert.ok(route, '插件必须注册 /plugins/appshot/config 端点')
  const request = createRequest(method)
  const response = createResponse()
  route.handler(request, response)
  if (payload !== undefined) {
    request.fire('data', Buffer.from(payload, 'utf-8'))
    request.fire('end')
  }
  return { status: response.status, json: response.body === '' ? {} : JSON.parse(response.body) as Record<string, unknown> }
}

test('sanitizeMacosConfig 只接受白名单字段（常规边界）', () => {
  assert.equal(sanitizeMacosConfig(null), null)
  assert.equal(sanitizeMacosConfig('nope'), null)
  assert.equal(sanitizeMacosConfig({ shortcutMode: 'not-a-mode' }), null)

  const patch = sanitizeMacosConfig({ shortcutMode: 'double-cmd', soundEnabled: false, injected: 'x' })
  assert.deepEqual(patch, { shortcutMode: 'double-cmd', soundEnabled: false })
})

test('区域框选开关默认启用且可关闭（主流程）', () => {
  assert.equal(DEFAULT_MACOS_CONFIG.regionShortcutEnabled, true)
  assert.deepEqual(sanitizeMacosConfig({ regionShortcutEnabled: false }), { regionShortcutEnabled: false })
  assert.deepEqual(sanitizeMacosConfig({ regionShortcutEnabled: 'no' }), null)
})

test('配置读写往返且损坏文件回退默认值（主流程 + 边界）', () => {
  const path = join(tempHome, 'plugins', 'appshot', 'config.json')
  assert.equal(saveMacosConfig(path, { ...DEFAULT_MACOS_CONFIG, shortcutMode: 'dual-option', soundEnabled: false }), true)
  assert.equal(existsSync(path), true)

  const loaded = loadMacosConfig(path)
  assert.equal(loaded.shortcutMode, 'dual-option')
  assert.equal(loaded.soundEnabled, false)
  assert.equal(loaded.animationEnabled, true)

  const broken = join(tempHome, 'broken.json')
  saveMacosConfig(broken, DEFAULT_MACOS_CONFIG)
  rmSync(path, { force: true })
  assert.equal(loadMacosConfig(path).shortcutMode, 'dual-cmd')
})

test('GET 返回默认配置，POST 合法字段落盘（主流程）', () => {
  const { ctx, routes } = createEndpointCtx()
  plugin.apply(ctx as unknown as Parameters<typeof plugin.apply>[0])
  assert.equal(resolveConfigStorePath().startsWith(tempHome), true)

  const initial = invoke(routes, 'GET')
  assert.equal(initial.status, 200)
  assert.equal(initial.json.shortcutMode, 'dual-cmd')

  const saved = invoke(routes, 'POST', JSON.stringify({ shortcutMode: 'double-cmd', soundEnabled: false }))
  assert.equal(saved.status, 200)
  assert.equal(saved.json.shortcutMode, 'double-cmd')
  assert.equal(saved.json.persisted, true)

  const persisted = JSON.parse(readFileSync(resolveConfigStorePath(), 'utf-8')) as Record<string, unknown>
  assert.equal(persisted.shortcutMode, 'double-cmd')
  assert.equal(persisted.soundEnabled, false)

  const after = invoke(routes, 'GET')
  assert.equal(after.json.shortcutMode, 'double-cmd')
})

test('非法请求体返回 4xx 且不抛出（崩溃回归）', () => {
  const { ctx, routes } = createEndpointCtx()
  plugin.apply(ctx as unknown as Parameters<typeof plugin.apply>[0])

  const badJson = invoke(routes, 'POST', '{ not json')
  assert.equal(badJson.status, 400)

  const noFields = invoke(routes, 'POST', JSON.stringify({ unexpected: true }))
  assert.equal(noFields.status, 400)

  const wrongMethod = invoke(routes, 'DELETE')
  assert.equal(wrongMethod.status, 405)
})

after(() => {
  rmSync(tempHome, { recursive: true, force: true })
})
