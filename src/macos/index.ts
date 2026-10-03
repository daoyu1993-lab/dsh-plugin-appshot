/**
 * src/macos/index.ts — macOS 宿主插件实现（SSE 广播 + saveImage 字节流 + 原生唤起）。
 *
 * 权威依据：docs/technical.md / docs/requirements.md（macOS MVP）。
 * 平台分流入口见 src/index.ts；Windows 实现见 src/windows/index.ts。
 */

import type { Context } from '@deepseek-ai/cordis'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { cleanOrphanStagingFiles } from './staging.ts'
import { createAppshotSSEHub, type AppshotSSEHub } from './sse.ts'
import { ingestScreenshot } from './ingest.ts'
import { startAgent, type AgentProcess } from './agent.ts'
import { loadMacosConfig, resolveConfigStorePath, sanitizeMacosConfig, saveMacosConfig } from './config-store.ts'
import type { AppshotConfig, AppshotEventCapture, ImageAttachmentRef } from '../shared/types.ts'

// 镜像自 @deepseek-ai/dsh-attachment StoredImageAttachment（禁 any/@ts-ignore）
interface HostAttachmentStore {
  readImage(ref: ImageAttachmentRef): Promise<{ ref: ImageAttachmentRef; data: Uint8Array }>
}

// macOS 插件自持状态（Windows runtime 状态在 src/index.ts）
let macosAgent: AgentProcess | undefined
let macosSseHub: AppshotSSEHub | undefined
let macosConfig: AppshotConfig | undefined

function resolveAgentBinaryPath(): string {
  const currentDir = typeof __dirname !== 'undefined'
    ? __dirname
    : dirname(fileURLToPath(import.meta.url))

  const candidates = [
    // 优先：打包后的 App Bundle 可执行文件
    join(currentDir, '../native/macos/.build/Appshot Agent.app/Contents/MacOS/appshot-macos'),
    // 次优：根目录或构建目录的可执行文件
    join(currentDir, '../native/macos/appshot-macos'),
    join(currentDir, '../native/macos/.build/debug/appshot-macos'),
  ]

  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate
    }
  }

  return candidates[0]
}

export function applyMacos(ctx: Context) {
  console.log('[dsh-plugin-appshot] plugin applying...')

  // 1. 启动时孤儿文件 GC
  cleanOrphanStagingFiles().catch((err) => {
    console.error('[dsh-plugin-appshot] failed to clean orphan files:', err)
  })

  // 2. 注册 SSE 广播 Hub
  const sseHub = createAppshotSSEHub(ctx as unknown as Parameters<typeof createAppshotSSEHub>[0])
  macosSseHub = sseHub

  // 3. 读取插件自持配置（DSH 0.2.0 起 settings 服务只按 profile 条目 id 暴露 volatile 字段，
  //    旧的 register/update 用法已不可用，详见 config-store.ts 头注）
  const configStorePath = resolveConfigStorePath()
  macosConfig = loadMacosConfig(configStorePath)

  // 4. 启动 Native Agent 常驻进程
  if (process.env.DSH_DISABLE_AGENT_SPAWN !== '1') {
    const binaryPath = resolveAgentBinaryPath()
    if (existsSync(binaryPath)) {
      console.log('[dsh-plugin-appshot] starting native agent from:', binaryPath)
      const activatePid = process.ppid || process.pid
      startAgent({
        command: binaryPath,
        args: [
          '--daemon',
          '--activate-pid', String(activatePid),
          '--activate-app', 'com.deepseek-harness.desktop',
        ],
        onEvent: async (event) => {
          if (event.type === 'ready') {
            console.log('[dsh-plugin-appshot] native agent ready, pid:', event.pid)
            if (macosAgent !== undefined && macosConfig !== undefined) {
              macosAgent.sendConfig(macosConfig)
            }
          } else if (event.type === 'appshot') {
            const capture = event as AppshotEventCapture
            console.log('[dsh-plugin-appshot] captured screenshot:', capture.appName, capture.imagePath)
            try {
              const attachmentRef = await ingestScreenshot(
                ctx as unknown as Parameters<typeof ingestScreenshot>[0],
                capture.imagePath,
                capture.appName,
              )
              console.log('[dsh-plugin-appshot] attachment saved:', attachmentRef.attachmentId)

              // 草稿态附件尚未进入任何 session 日志，客户端 readAttachment 读不到（宿主拒绝：
              // "Image is not referenced by this session"）。改为把已验证字节直接放进帧。
              let dataBase64: string | undefined
              try {
                const stored = await (ctx as unknown as { attachments: HostAttachmentStore }).attachments
                  .readImage(attachmentRef)
                dataBase64 = Buffer.from(stored.data).toString('base64')
              } catch (err) {
                console.warn('[dsh-plugin-appshot] readImage failed, frame carries metadata only:', err)
              }

              sseHub.broadcast({
                type: 'appshot/ready',
                attachmentRef,
                dataBase64,
                appName: capture.appName,
                windowTitle: capture.windowTitle,
                timestamp: capture.timestamp ?? Date.now(),
              })
            } catch (err) {
              console.error('[dsh-plugin-appshot] failed to ingest screenshot:', err)
            }
          } else if (event.type === 'error') {
            console.error('[dsh-plugin-appshot] native agent error:', event.code, event.message)
          }
        },
        onExit: (info) => {
          console.log('[dsh-plugin-appshot] native agent exited with code:', info.code, 'signal:', info.signal)
        },
      }).then((agent) => {
        macosAgent = agent
        if (macosConfig) {
          agent.sendConfig(macosConfig)
        }
      }).catch((err) => {
        console.error('[dsh-plugin-appshot] failed to start native agent:', err)
      })
    }
  }

  // 5. 注册配置 REST 端点（客户端设置面板的唯一读写通道，落盘见 config-store.ts）
  const webServer = (ctx as unknown as { webServer?: { register?(route: { kind: string; path: string; handler: (req: unknown, res: unknown) => void }): () => void } }).webServer
  if (typeof webServer?.register === 'function') {
    const getConfig = (): AppshotConfig => macosConfig ?? loadMacosConfig(configStorePath)

    webServer.register({
      kind: 'exact',
      path: '/plugins/appshot/config',
      handler(req: unknown, res: unknown) {
        const httpReq = req as { method?: string; on?(event: string, cb: (chunk: Buffer) => void): void }
        const httpRes = res as {
          writeHead(status: number, headers?: Record<string, string>): void
          end(body?: string): void
        }
        const respond = (status: number, payload: unknown): void => {
          httpRes.writeHead(status, { 'Content-Type': 'application/json' })
          httpRes.end(JSON.stringify(payload))
        }

        // 端点内任何异常都就地转成响应：0.2.0 宿主把未处理拒绝视为致命错误并退出进程
        try {
          if (httpReq.method === 'GET') {
            respond(200, getConfig())
            return
          }

          if (httpReq.method === 'POST') {
            const chunks: Buffer[] = []
            const reqNode = req as { on(event: string, cb: (data?: Buffer) => void): void }
            reqNode.on('data', (chunk?: Buffer) => { if (chunk) chunks.push(chunk) })
            reqNode.on('end', () => {
              try {
                const patch = sanitizeMacosConfig(JSON.parse(Buffer.concat(chunks).toString('utf-8')) as unknown)
                if (patch === null) {
                  respond(400, { error: 'No valid config field in request body' })
                  return
                }
                const merged: AppshotConfig = { ...getConfig(), ...patch }
                macosConfig = merged
                if (macosAgent !== undefined) {
                  macosAgent.sendConfig(merged)
                }
                const persisted = saveMacosConfig(configStorePath, merged)
                if (!persisted) {
                  console.warn('[dsh-plugin-appshot] config not persisted; in-memory value stays active:', configStorePath)
                }
                respond(200, { ...merged, persisted })
              } catch (err) {
                respond(400, { error: 'Invalid JSON', detail: String(err) })
              }
            })
            return
          }

          respond(405, { error: 'Method not allowed' })
        } catch (err) {
          console.error('[dsh-plugin-appshot] config endpoint failed:', err)
          try {
            respond(500, { error: 'Config endpoint failed', detail: String(err) })
          } catch {
            // 连接可能已断开：不再向上抛，避免影响宿主进程
          }
        }
      },
    })
  }
}

export function disposeMacos(): void {
  if (macosAgent) {
    macosAgent.stop().catch(() => {})
    macosAgent = undefined
  }
  if (macosSseHub) {
    macosSseHub.dispose()
    macosSseHub = undefined
  }
}
