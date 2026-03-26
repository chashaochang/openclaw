/**
 * Chat image attachments: pick from gallery, downscale + JPEG recompress (Android ChatImageCodec parity).
 */
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import type { OutgoingAttachment } from './ChatController';
import type { ChatPendingAttachment } from './ChatModels';

/** Match Android ChatSheetContent + ChatImageCodec. */
export const CHAT_ATTACHMENT_MAX_COUNT = 8;
const CHAT_ATTACHMENT_MAX_WIDTH = 1600;
const CHAT_ATTACHMENT_MAX_BASE64_CHARS = 300 * 1024;
const CHAT_ATTACHMENT_START_QUALITY = 85;
const MAX_READ_BYTES = 25 * 1024 * 1024;

const MAX_EDGE_STEPS: number[] = [1600, 1280, 960, 720, 480, 360];

function buildQualitySteps(): number[] {
  const out: number[] = [];
  let q = CHAT_ATTACHMENT_START_QUALITY;
  while (q >= 20) {
    out.push(q);
    q -= 10;
  }
  if (out[out.length - 1] !== 20) {
    out.push(20);
  }
  return out;
}

const QUALITY_STEPS: number[] = buildQualitySteps();

function extractFileStemFromUri(uri: string): string {
  const u = uri.trim();
  if (u.length === 0) {
    return 'image';
  }
  const noQuery = u.split('?')[0];
  const parts = noQuery.split('/');
  let last = parts.length > 0 ? parts[parts.length - 1] : '';
  try {
    last = decodeURIComponent(last);
  } catch {
    // keep raw
  }
  return last.length > 0 ? last : 'image';
}

export function normalizeChatAttachmentFileName(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.length === 0) {
    return 'image.jpg';
  }
  const lastDot = trimmed.lastIndexOf('.');
  const stem = lastDot >= 0 ? trimmed.substring(0, lastDot) : trimmed;
  const safeStem = stem.trim().length > 0 ? stem.trim() : 'image';
  return `${safeStem}.jpg`;
}

function readUriToBuffer(uri: string): ArrayBuffer | null {
  let opened: fs.File | null = null;
  try {
    opened = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const st = fs.statSync(opened.fd);
    const size = st.size;
    if (size <= 0 || size > MAX_READ_BYTES) {
      return null;
    }
    const buf = new ArrayBuffer(size);
    fs.readSync(opened.fd, buf);
    return buf;
  } catch {
    return null;
  } finally {
    if (opened) {
      try {
        fs.closeSync(opened);
      } catch {
        // ignore
      }
    }
  }
}

async function decodeToPixelMap(raw: ArrayBuffer, maxEdge: number): Promise<image.PixelMap | null> {
  let src: image.ImageSource | null = null;
  try {
    src = image.createImageSource(raw);
    const info = await src.getImageInfo();
    const w = info.size.width;
    const h = info.size.height;
    if (w <= 0 || h <= 0) {
      return null;
    }
    const long = Math.max(w, h);
    let tw = w;
    let th = h;
    if (long > maxEdge) {
      const scale = maxEdge / long;
      tw = Math.max(1, Math.floor(w * scale));
      th = Math.max(1, Math.floor(h * scale));
    }
    const decodingOptions: image.DecodingOptions = {
      desiredSize: { width: tw, height: th },
    };
    return await src.createPixelMap(decodingOptions);
  } catch {
    return null;
  } finally {
    if (src) {
      try {
        src.release();
      } catch {
        // ignore
      }
    }
  }
}

async function packPixelMapToJpegBase64(pm: image.PixelMap, quality: number): Promise<string | null> {
  try {
    const packer = image.createImagePacker();
    const opts: image.PackingOption = {
      format: 'image/jpeg',
      quality: quality,
    };
    const out = await packer.packing(pm, opts);
    const u8 = new Uint8Array(out);
    const helper = new util.Base64Helper();
    return helper.encodeToStringSync(u8);
  } catch {
    return null;
  }
}

async function encodeBufferToPending(uri: string, raw: ArrayBuffer): Promise<ChatPendingAttachment | null> {
  const id = `${uri}#${Date.now()}_${(Math.floor(Math.random() * 1e9)).toString()}`;
  const fileName = normalizeChatAttachmentFileName(extractFileStemFromUri(uri));
  const maxB64 = CHAT_ATTACHMENT_MAX_BASE64_CHARS;

  for (let ei = 0; ei < MAX_EDGE_STEPS.length; ei++) {
    const maxEdge = Math.min(MAX_EDGE_STEPS[ei], CHAT_ATTACHMENT_MAX_WIDTH);
    const pm = await decodeToPixelMap(raw, maxEdge);
    if (!pm) {
      continue;
    }
    try {
      for (let qi = 0; qi < QUALITY_STEPS.length; qi++) {
        const q = QUALITY_STEPS[qi];
        const b64 = await packPixelMapToJpegBase64(pm, q);
        if (b64 && b64.length > 0 && b64.length <= maxB64) {
          const row: ChatPendingAttachment = {
            id: id,
            fileName: fileName,
            mimeType: 'image/jpeg',
            base64: b64,
          };
          return row;
        }
      }
    } finally {
      try {
        pm.release();
      } catch {
        // ignore
      }
    }
  }
  return null;
}

export function toOutgoingImageAttachments(pending: ChatPendingAttachment[]): OutgoingAttachment[] {
  const out: OutgoingAttachment[] = [];
  for (let i = 0; i < pending.length; i++) {
    const p = pending[i];
    out.push({
      type: 'image',
      mimeType: p.mimeType,
      fileName: p.fileName,
      base64: p.base64,
    });
  }
  return out;
}

/**
 * Opens the system photo picker and returns resized JPEG attachments (base64), same caps as Android.
 */
export async function pickAndEncodeChatImages(_ctx: common.UIAbilityContext | null, maxAdd: number): Promise<ChatPendingAttachment[]> {
  if (maxAdd <= 0) {
    return [];
  }
  const cap = Math.min(maxAdd, CHAT_ATTACHMENT_MAX_COUNT);
  let uriList: string[] = [];
  try {
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = cap;
    const picker = new photoAccessHelper.PhotoViewPicker();
    const result = await picker.select(options);
    uriList = result.photoUris ?? [];
  } catch {
    return [];
  }
  const out: ChatPendingAttachment[] = [];
  for (let i = 0; i < uriList.length; i++) {
    const uri = uriList[i];
    const raw = readUriToBuffer(uri);
    if (!raw) {
      continue;
    }
    const row = await encodeBufferToPending(uri, raw);
    if (row) {
      out.push(row);
    }
  }
  return out;
}
