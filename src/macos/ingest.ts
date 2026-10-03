import { readFile, unlink } from 'node:fs/promises'
import type { ImageAttachmentRef, SaveImageInput } from '../shared/types.ts'

export interface AttachmentService {
  saveImage(input: SaveImageInput): Promise<ImageAttachmentRef>
}

export interface IngestContext {
  attachments: AttachmentService
}

export async function ingestScreenshot(
  ctx: IngestContext,
  imagePath: string,
  appName: string,
  captureKind: 'window' | 'region' = 'window',
): Promise<ImageAttachmentRef> {
  try {
    const data = await readFile(imagePath)
    const input: SaveImageInput = {
      data,
      mediaType: 'image/png',
      // 区域截图没有归属应用：命名固定，避免出现「区域截图 窗口截图.png」
      name: captureKind === 'region' ? '区域截图.png' : `${appName} 窗口截图.png`,
    }
    return await ctx.attachments.saveImage(input)
  } finally {
    await unlink(imagePath).catch(() => {})
  }
}
