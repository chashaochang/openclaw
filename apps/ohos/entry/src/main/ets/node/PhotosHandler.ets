/**
 * Photos invoke handler: fetch recent images and return JPEG base64 payloads like Android photos.latest.
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import dataSharePredicates from '@ohos.data.dataSharePredicates';
import type { InvokeErrorShape, InvokeResult } from '../gateway/GatewaySession';

const DEFAULT_PHOTOS_LIMIT = 1;
const DEFAULT_PHOTOS_MAX_WIDTH = 1600;
const DEFAULT_PHOTOS_QUALITY = 0.85;
const MAX_TOTAL_BASE64_CHARS = 340 * 1024;
const MAX_PER_PHOTO_BASE64_CHARS = 300 * 1024;

type JsonValue = object | string | number | boolean | null | undefined;

interface PhotosLatestRequest {
  limit: number;
  maxWidth: number;
  quality: number;
}

interface PhotoAssetLike {
  get(member: string): string | number | boolean | null | undefined;
  getThumbnail(size?: image.Size): Promise<image.PixelMap>;
}

interface FetchResultLike<T> {
  getAllObjects(): Promise<T[]>;
  close(): void;
}

interface EncodedPhotoPayload {
  format: string;
  base64: string;
  width: number;
  height: number;
  createdAt: string | null;
}

function invokeErr(code: string, message: string): InvokeResult {
  const error: InvokeErrorShape = { code, message };
  return { ok: false, payloadJson: null, error };
}

function invokeOk(payloadJson: string): InvokeResult {
  return { ok: true, payloadJson, error: null };
}

function clampLimit(limit: number): number {
  return Math.max(1, Math.min(8, Math.floor(limit)));
}

function clampMaxWidth(width: number): number {
  return Math.max(160, Math.min(1600, Math.floor(width)));
}

function clampQuality(quality: number): number {
  if (!Number.isFinite(quality)) {
    return DEFAULT_PHOTOS_QUALITY;
  }
  return Math.max(0.1, Math.min(1.0, quality));
}

function isoTimestamp(epochMs: number): string | null {
  if (!Number.isFinite(epochMs) || epochMs <= 0) {
    return null;
  }
  try {
    return new Date(epochMs).toISOString();
  } catch {
    return null;
  }
}

export class PhotosHandler {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async handlePhotosLatest(paramsJson: string | null): Promise<InvokeResult> {
    if (!this.hasPermission(['ohos.permission.READ_IMAGEVIDEO'])) {
      return invokeErr(
        'PHOTOS_PERMISSION_REQUIRED',
        'PHOTOS_PERMISSION_REQUIRED: grant Photos permission',
      );
    }

    const request = this.parseRequest(paramsJson);
    if (request === null) {
      return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: expected JSON object');
    }

    try {
      const photos = await this.loadLatestPhotos(request);
      return invokeOk(JSON.stringify({ photos }));
    } catch (error) {
      const message = this.errorMessage(error);
      return invokeErr('PHOTOS_UNAVAILABLE', `PHOTOS_UNAVAILABLE: ${message}`);
    }
  }

  private hasPermission(permissionNames: Permissions[]): boolean {
    const atManager = abilityAccessCtrl.createAtManager();
    const tokenId = this.context.applicationInfo.accessTokenId;
    for (let i = 0; i < permissionNames.length; i++) {
      try {
        const status = atManager.checkAccessTokenSync(tokenId, permissionNames[i]);
        if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return true;
        }
      } catch {
        // Ignore unsupported permission names on some builds.
      }
    }
    return false;
  }

  private parseRequest(paramsJson: string | null): PhotosLatestRequest | null {
    if (!paramsJson || paramsJson.trim().length === 0) {
      return {
        limit: DEFAULT_PHOTOS_LIMIT,
        maxWidth: DEFAULT_PHOTOS_MAX_WIDTH,
        quality: DEFAULT_PHOTOS_QUALITY,
      };
    }
    try {
      const root = JSON.parse(paramsJson) as Record<string, JsonValue>;
      const limitRaw = root['limit'];
      const maxWidthRaw = root['maxWidth'];
      const qualityRaw = root['quality'];
      return {
        limit: typeof limitRaw === 'number' && Number.isFinite(limitRaw)
          ? clampLimit(limitRaw)
          : DEFAULT_PHOTOS_LIMIT,
        maxWidth: typeof maxWidthRaw === 'number' && Number.isFinite(maxWidthRaw)
          ? clampMaxWidth(maxWidthRaw)
          : DEFAULT_PHOTOS_MAX_WIDTH,
        quality: typeof qualityRaw === 'number' ? clampQuality(qualityRaw) : DEFAULT_PHOTOS_QUALITY,
      };
    } catch {
      return null;
    }
  }

  private async loadLatestPhotos(request: PhotosLatestRequest): Promise<EncodedPhotoPayload[]> {
    const helper = photoAccessHelper.getPhotoAccessHelper(this.context);
    const predicates = new dataSharePredicates.DataSharePredicates();
    predicates
      .equalTo(photoAccessHelper.PhotoKeys.PHOTO_TYPE, photoAccessHelper.PhotoType.IMAGE)
      .orderByDesc(photoAccessHelper.PhotoKeys.DATE_TAKEN_MS)
      .orderByDesc(photoAccessHelper.PhotoKeys.DATE_ADDED_MS)
      .limit(request.limit, 0);
    const options: photoAccessHelper.FetchOptions = {
      fetchColumns: [
        photoAccessHelper.PhotoKeys.DATE_TAKEN_MS,
        photoAccessHelper.PhotoKeys.DATE_ADDED_MS,
        photoAccessHelper.PhotoKeys.WIDTH,
        photoAccessHelper.PhotoKeys.HEIGHT,
      ],
      predicates,
    };

    let fetchResult: FetchResultLike<PhotoAssetLike> | null = null;
    try {
      fetchResult = await helper.getAssets(options) as FetchResultLike<PhotoAssetLike>;
      const assets = await fetchResult.getAllObjects();
      const out: EncodedPhotoPayload[] = [];
      let remainingBudget = MAX_TOTAL_BASE64_CHARS;
      for (let i = 0; i < assets.length; i++) {
        if (remainingBudget <= 0) {
          break;
        }
        const encoded = await this.encodeAsset(assets[i], request.maxWidth, request.quality);
        if (encoded === null) {
          continue;
        }
        if (encoded.base64.length > remainingBudget) {
          break;
        }
        remainingBudget -= encoded.base64.length;
        out.push(encoded);
      }
      return out;
    } finally {
      if (fetchResult) {
        try {
          fetchResult.close();
        } catch {
          // ignore
        }
      }
    }
  }

  private async encodeAsset(
    asset: PhotoAssetLike,
    maxWidth: number,
    quality: number,
  ): Promise<EncodedPhotoPayload | null> {
    let pixelMap: image.PixelMap | null = null;
    try {
      const size: image.Size = {
        width: maxWidth,
        height: maxWidth,
      };
      pixelMap = await asset.getThumbnail(size);
      const encoded = await this.packPixelMapToJpegBase64(pixelMap, Math.round(quality * 100));
      if (encoded === null || encoded.length === 0 || encoded.length > MAX_PER_PHOTO_BASE64_CHARS) {
        return null;
      }
      return {
        format: 'jpeg',
        base64: encoded,
        width: pixelMap.getImageInfoSync().size.width,
        height: pixelMap.getImageInfoSync().size.height,
        createdAt: this.assetCreatedAt(asset),
      };
    } catch {
      return null;
    } finally {
      if (pixelMap) {
        try {
          pixelMap.release();
        } catch {
          // ignore
        }
      }
    }
  }

  private assetCreatedAt(asset: PhotoAssetLike): string | null {
    const takenMs = asset.get(photoAccessHelper.PhotoKeys.DATE_TAKEN_MS);
    if (typeof takenMs === 'number') {
      const taken = isoTimestamp(takenMs);
      if (taken) {
        return taken;
      }
    }
    const addedMs = asset.get(photoAccessHelper.PhotoKeys.DATE_ADDED_MS);
    if (typeof addedMs === 'number') {
      return isoTimestamp(addedMs);
    }
    return null;
  }

  private async packPixelMapToJpegBase64(
    pixelMap: image.PixelMap,
    quality: number,
  ): Promise<string | null> {
    try {
      const packer = image.createImagePacker();
      const opts: image.PackingOption = {
        format: 'image/jpeg',
        quality: Math.max(20, Math.min(100, quality)),
      };
      const out = await packer.packing(pixelMap, opts);
      const helper = new util.Base64Helper();
      return helper.encodeToStringSync(new Uint8Array(out));
    } catch {
      return null;
    }
  }

  private errorMessage(error: JsonValue): string {
    if (error instanceof Error) {
      return error.message.trim().length > 0 ? error.message : 'photos query failed';
    }
    if (typeof error === 'object' && error !== null) {
      const root = error as Record<string, JsonValue>;
      const message = typeof root['message'] === 'string' ? root['message'].trim() : '';
      if (message.length > 0) {
        return message;
      }
      const code = root['code'];
      if (typeof code === 'number' || typeof code === 'string') {
        return String(code);
      }
    }
    return 'photos query failed';
  }
}
