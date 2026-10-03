/**
 * Phase 7 / T7.3 — 区域框选截图（⌘⇧A / `--region-rect`）
 *
 * 通过标准（docs/tasks.md T7.3）：
 *   > 区域模式：框选矩形与输出图片像素一致（Retina 坐标换算正确）。
 *
 * 覆盖范围：
 * - 主流程：`--region-rect x,y,w,h` 输出 PNG，且 IHDR 像素尺寸与 JSON 一致、宽高比与选区一致；
 * - 常规边界：参数不完整 / 过小选区分别返回 INVALID_REGION_RECT / REGION_TOO_SMALL；
 * - 交互链路（⌘⇧A 遮罩框选）与「全屏模式」仍需人工验收，见文末用例。
 *
 * 环境门控：与其它 native 用例一致（二进制已构建 + 当前会话具备屏幕录制权限）。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'

import { fileExists, makeTempDir, removeDir } from './helpers/fs.ts'
import { nativeSkipReason, probeNative } from './helpers/native-probe.ts'
import { nativeBinaryExists, parseFirstJsonLine, runNative } from './helpers/run-native.ts'
import type { NativeErrorResult, NativeSuccessResult } from './helpers/types.ts'

const probe = await probeNative()
const nativeGate = nativeSkipReason(probe)
const binaryGate = nativeBinaryExists() ? false : 'native binary 未构建（先执行 pnpm build:native）'

/** 读取 PNG 的 IHDR 宽高：验证「选区点 → 输出像素」的真实落盘结果。 */
function pngSize(bytes: Buffer): { width: number; height: number } {
  assert.equal(bytes.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', '应为 PNG 签名')
  assert.equal(bytes.subarray(12, 16).toString('ascii'), 'IHDR', '首个 chunk 应为 IHDR')
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) }
}

test('--help 列出区域截图选项（主流程）', { skip: binaryGate }, async () => {
  const result = await runNative(['--help'])
  assert.equal(result.code, 0)
  assert.ok(result.stdout.includes('--region-rect'), '--help 应列出 --region-rect')
  assert.ok(result.stdout.includes('--region'), '--help 应列出 --region')
})

test('--region-rect 输出像素与选区一致（Retina 换算，主流程）', { skip: nativeGate }, async () => {
  const dir = await makeTempDir('dsh-appshot-region-')
  const output = join(dir, 'region.png')
  try {
    const result = await runNative(['--region-rect', '120,120,400,300', '--output', output])
    assert.equal(result.code, 0, `stderr: ${result.stderr.trim().slice(0, 300)}`)

    const parsed = parseFirstJsonLine(result.stdout) as NativeSuccessResult
    assert.equal(parsed.ok, true)
    assert.equal(parsed.captureKind, 'region')
    assert.equal(parsed.imagePath, output)
    assert.equal(parsed.mimeType, 'image/png')
    // 400×300 点：Retina（scale 2）→ 800×600 像素；非 Retina → 1:1
    assert.ok([400, 800].includes(parsed.width), `宽度应为 400 或 800，实际 ${parsed.width}`)
    assert.ok([300, 600].includes(parsed.height), `高度应为 300 或 600，实际 ${parsed.height}`)
    assert.equal(parsed.width / parsed.height, 400 / 300, '宽高比应与选区一致')
    assert.equal(parsed.windowId, 0, '区域截图无归属窗口')

    assert.equal(await fileExists(output), true, 'PNG 应落盘')
    const size = pngSize(await readFile(output))
    assert.equal(size.width, parsed.width, 'PNG 实际像素宽应与 JSON 一致')
    assert.equal(size.height, parsed.height, 'PNG 实际像素高应与 JSON 一致')
  } finally {
    await removeDir(dir)
  }
})

test('--region-rect 参数不完整返回 INVALID_REGION_RECT（常规边界）', { skip: binaryGate }, async () => {
  const result = await runNative(['--region-rect', '1,2,3'])
  assert.notEqual(result.code, 0, '错误路径退出码必须非 0')
  const parsed = parseFirstJsonLine(result.stdout) as NativeErrorResult
  assert.equal(parsed.ok, false)
  assert.equal(parsed.code, 'INVALID_REGION_RECT')
})

test('--region-rect 过小选区返回 REGION_TOO_SMALL（常规边界）', { skip: nativeGate }, async () => {
  const result = await runNative(['--region-rect', '10,10,0,5'])
  assert.notEqual(result.code, 0, '错误路径退出码必须非 0')
  const parsed = parseFirstJsonLine(result.stdout) as NativeErrorResult
  assert.equal(parsed.ok, false)
  assert.equal(parsed.code, 'REGION_TOO_SMALL')
})

test('手动：⌘⇧A 框选后自动挂入输入框（人工验收）', {
  skip: '人工验收：在任意应用按 ⌘⇧A → 整屏压暗、拖动框选 → 松开后截图落盘、DSH 唤起、图片出现在输入框；Esc / 右键 / 过小选区应取消且不产生附件',
}, () => {})

test('手动：全屏模式按目标屏幕捕获（未实现，Post-MVP）', {
  skip: '未实现：当前仅支持鼠标所在屏的区域框选；全屏截图可继续用窗口链路或系统截图后粘贴',
}, () => {})
