/**
 * Camera invoke handler: uses CameraManager for list and system cameraPicker for snap/clip.
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { camera, cameraPicker } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import fs from '@ohos.file.fs';
import type { InvokeErrorShape, InvokeResult } from '../gateway/GatewaySession';
import type { CameraHudKind } from '../NodeRuntime';

const CAMERA_CLIP_MAX_RAW_BYTES = 18 * 1024 * 1024;
const MAX_IMAGE_READ_BYTES = 25 * 1024 * 1024;

type JsonValue = object | string | number | boolean | null | undefined;

interface CameraDeviceRow {
  id: string;
  name: string;
  position: string;
  deviceType: string;
}

interface CameraListPayload {
  devices: CameraDeviceRow[];
}

interface CameraSnapPayload {
  format: string;
  base64: string;
  width: number;
  height: number;
}

interface CameraClipPayload {
  format: string;
  base64: string;
  durationMs: number;
  hasAudio: boolean;
}

interface SnapParams {
  facing: string | null;
  deviceId: string | null;
  maxWidth: number | null;
  quality: number | null;
  format: string;
}

interface ClipParams {
  facing: string | null;
  deviceId: string | null;
  durationMs: number;
  includeAudio: boolean;
}

interface EncodedImageResult {
  base64: string;
  width: number;
  height: number;
}

interface PickerResultShape {
  resultCode: number;
  resultUri: string;
  mediaType: cameraPicker.PickerMediaType;
}

interface CameraErrorLikeShape {
  message?: string;
  code?: string | number;
}

function invokeErr(code: string, message: string): InvokeResult {
  const error: InvokeErrorShape = { code, message };
  return { ok: false, payloadJson: null, error };
}

function invokeOk(payloadJson: string): InvokeResult {
  return { ok: true, payloadJson, error: null };
}

function normalizeFormat(raw: string | null): string {
  const value = (raw ?? '').trim().toLowerCase();
  if (value === 'png') {
    return 'png';
  }
  return 'jpg';
}

function mimeFromFormat(format: string): string {
  return format === 'png' ? 'image/png' : 'image/jpeg';
}

function extensionFromMediaType(mediaType: cameraPicker.PickerMediaType): string {
  return mediaType === cameraPicker.PickerMediaType.VIDEO ? 'mp4' : 'jpg';
}

export class CameraHandler {
  private context: common.UIAbilityContext;
  private isForeground: () => boolean;
  private showHud: (message: string, kind: CameraHudKind, autoHideMs: number | null) => void;
  private triggerFlash: () => void;

  constructor(
    context: common.UIAbilityContext,
    isForeground: () => boolean,
    showHud: (message: string, kind: CameraHudKind, autoHideMs: number | null) => void,
    triggerFlash: () => void,
  ) {
    this.context = context;
    this.isForeground = isForeground;
    this.showHud = showHud;
    this.triggerFlash = triggerFlash;
  }

  async handleList(_paramsJson: string | null): Promise<InvokeResult> {
    try {
      const supported = this.supportedCameras();
      const devices: CameraDeviceRow[] = [];
      for (let i = 0; i < supported.length; i++) {
        const item = supported[i];
        devices.push({
          id: item.cameraId,
          name: this.cameraName(item.cameraPosition),
          position: this.cameraPosition(item.cameraPosition),
          deviceType: this.cameraType(item.cameraType),
        });
      }
      const payload: CameraListPayload = { devices };
      return invokeOk(JSON.stringify(payload));
    } catch (error) {
      return invokeErr('UNAVAILABLE', this.errorMessage(error, 'camera list failed'));
    }
  }

  async handleSnap(paramsJson: string | null): Promise<InvokeResult> {
    if (!this.isForeground()) {
      return invokeErr(
        'NODE_BACKGROUND_UNAVAILABLE',
        'NODE_BACKGROUND_UNAVAILABLE: camera requires OpenClaw to stay open',
      );
    }
    if (!this.hasPermission(['ohos.permission.CAMERA'])) {
      return invokeErr(
        'CAMERA_PERMISSION_REQUIRED',
        'CAMERA_PERMISSION_REQUIRED: grant Camera permission',
      );
    }
    const params = this.parseSnapParams(paramsJson);
    try {
      this.showHud('Taking photo…', 'photo', null);
      this.triggerFlash();
      const result = await this.pickMedia(
        cameraPicker.PickerMediaType.PHOTO,
        params.facing,
        params.deviceId,
        undefined,
      );
      const raw = this.readUriToBuffer(result.resultUri, MAX_IMAGE_READ_BYTES);
      if (!raw) {
        this.showHud('Camera unavailable', 'error', 2200);
        return invokeErr('UNAVAILABLE', 'UNAVAILABLE: camera snap failed');
      }
      const encoded = await this.encodeImage(raw, params.format, params.maxWidth, params.quality);
      if (!encoded) {
        this.showHud('Camera unavailable', 'error', 2200);
        return invokeErr('UNAVAILABLE', 'UNAVAILABLE: camera snap failed');
      }
      this.showHud('Photo captured', 'success', 1600);
      const payload: CameraSnapPayload = {
        format: params.format,
        base64: encoded.base64,
        width: encoded.width,
        height: encoded.height,
      };
      return invokeOk(JSON.stringify(payload));
    } catch (error) {
      this.showHud('Camera unavailable', 'error', 2200);
      return invokeErr('UNAVAILABLE', this.errorMessage(error, 'camera snap failed'));
    }
  }

  async handleClip(paramsJson: string | null): Promise<InvokeResult> {
    if (!this.isForeground()) {
      return invokeErr(
        'NODE_BACKGROUND_UNAVAILABLE',
        'NODE_BACKGROUND_UNAVAILABLE: camera requires OpenClaw to stay open',
      );
    }
    if (!this.hasPermission(['ohos.permission.CAMERA'])) {
      return invokeErr(
        'CAMERA_PERMISSION_REQUIRED',
        'CAMERA_PERMISSION_REQUIRED: grant Camera permission',
      );
    }
    const params = this.parseClipParams(paramsJson);
    if (params.includeAudio && !this.hasPermission(['ohos.permission.MICROPHONE'])) {
      return invokeErr(
        'MICROPHONE_PERMISSION_REQUIRED',
        'MICROPHONE_PERMISSION_REQUIRED: grant Microphone permission',
      );
    }
    try {
      this.showHud('Recording…', 'recording', null);
      const result = await this.pickMedia(
        cameraPicker.PickerMediaType.VIDEO,
        params.facing,
        params.deviceId,
        params.durationMs,
      );
      const raw = this.readUriToBuffer(result.resultUri, CAMERA_CLIP_MAX_RAW_BYTES + 1);
      if (!raw) {
        this.showHud('Camera unavailable', 'error', 2400);
        return invokeErr('UNAVAILABLE', 'UNAVAILABLE: camera clip failed');
      }
      if (raw.byteLength > CAMERA_CLIP_MAX_RAW_BYTES) {
        this.showHud('Clip too large', 'error', 2400);
        return invokeErr(
          'PAYLOAD_TOO_LARGE',
          `PAYLOAD_TOO_LARGE: camera clip is ${raw.byteLength} bytes; max is ${CAMERA_CLIP_MAX_RAW_BYTES} bytes. Reduce durationMs and retry.`,
        );
      }
      const helper = new util.Base64Helper();
      this.showHud('Clip captured', 'success', 1800);
      const payload: CameraClipPayload = {
        format: extensionFromMediaType(result.mediaType),
        base64: helper.encodeToStringSync(new Uint8Array(raw)),
        durationMs: params.durationMs,
        hasAudio: params.includeAudio,
      };
      return invokeOk(JSON.stringify(payload));
    } catch (error) {
      this.showHud('Camera unavailable', 'error', 2400);
      return invokeErr('UNAVAILABLE', this.errorMessage(error, 'camera clip failed'));
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
        // Ignore unsupported permission names on this build.
      }
    }
    return false;
  }

  private parseSnapParams(paramsJson: string | null): SnapParams {
    let facing: string | null = null;
    let deviceId: string | null = null;
    let maxWidth: number | null = null;
    let quality: number | null = null;
    let format = 'jpg';
    if (paramsJson && paramsJson.trim().length > 0) {
      try {
        const root = JSON.parse(paramsJson) as Record<string, JsonValue>;
        const facingRaw = root.facing;
        const deviceIdRaw = root.deviceId;
        const maxWidthRaw = root.maxWidth;
        const qualityRaw = root.quality;
        const formatRaw = root.format;
        facing = typeof facingRaw === 'string' ? facingRaw.trim().toLowerCase() : null;
        deviceId = typeof deviceIdRaw === 'string' && deviceIdRaw.trim().length > 0 ? deviceIdRaw.trim() : null;
        maxWidth = typeof maxWidthRaw === 'number' && Number.isFinite(maxWidthRaw) ? Math.max(1, Math.floor(maxWidthRaw)) : null;
        quality = typeof qualityRaw === 'number' && Number.isFinite(qualityRaw)
          ? Math.max(0.1, Math.min(1, qualityRaw))
          : null;
        format = normalizeFormat(typeof formatRaw === 'string' ? formatRaw : null);
      } catch {
        // Keep defaults.
      }
    }
    return { facing, deviceId, maxWidth, quality, format };
  }

  private parseClipParams(paramsJson: string | null): ClipParams {
    let facing: string | null = null;
    let deviceId: string | null = null;
    let durationMs = 3000;
    let includeAudio = true;
    if (paramsJson && paramsJson.trim().length > 0) {
      try {
        const root = JSON.parse(paramsJson) as Record<string, JsonValue>;
        const facingRaw = root.facing;
        const deviceIdRaw = root.deviceId;
        const durationRaw = root.durationMs;
        const includeAudioRaw = root.includeAudio;
        facing = typeof facingRaw === 'string' ? facingRaw.trim().toLowerCase() : null;
        deviceId = typeof deviceIdRaw === 'string' && deviceIdRaw.trim().length > 0 ? deviceIdRaw.trim() : null;
        durationMs = typeof durationRaw === 'number' && Number.isFinite(durationRaw)
          ? Math.max(200, Math.min(60_000, Math.floor(durationRaw)))
          : 3000;
        includeAudio = typeof includeAudioRaw === 'boolean' ? includeAudioRaw : true;
      } catch {
        // Keep defaults.
      }
    }
    return { facing, deviceId, durationMs, includeAudio };
  }

  private async pickMedia(
    mediaType: cameraPicker.PickerMediaType,
    facing: string | null,
    deviceId: string | null,
    durationMs: number | undefined,
  ): Promise<PickerResultShape> {
    const profile = new cameraPicker.PickerProfile();
    profile.cameraPosition = this.resolveRequestedCameraPosition(facing, deviceId);
    if (mediaType === cameraPicker.PickerMediaType.VIDEO && durationMs !== undefined) {
      profile.videoDuration = Math.max(1, Math.ceil(durationMs / 1000));
    }
    const result = await cameraPicker.pick(this.context, [mediaType], profile) as PickerResultShape;
    if (!result.resultUri || result.resultUri.trim().length === 0) {
      throw new Error('camera picker did not return a result');
    }
    return result;
  }

  private readUriToBuffer(uri: string, maxBytes: number): ArrayBuffer | null {
    let opened: fs.File | null = null;
    try {
      opened = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(opened.fd);
      const size = stat.size;
      if (size <= 0 || size > maxBytes) {
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

  private async encodeImage(
    raw: ArrayBuffer,
    format: string,
    maxWidth: number | null,
    quality: number | null,
  ): Promise<EncodedImageResult | null> {
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    try {
      source = image.createImageSource(raw);
      const info = await source.getImageInfo();
      const originalWidth = info.size.width;
      const originalHeight = info.size.height;
      if (originalWidth <= 0 || originalHeight <= 0) {
        return null;
      }
      let width = originalWidth;
      let height = originalHeight;
      if (maxWidth !== null && width > maxWidth) {
        const scale = maxWidth / width;
        width = Math.max(1, Math.floor(width * scale));
        height = Math.max(1, Math.floor(height * scale));
      }
      pixelMap = await source.createPixelMap({
        desiredSize: { width, height },
      });
      const packer = image.createImagePacker();
      const packed = await packer.packing(pixelMap, {
        format: mimeFromFormat(format),
        quality: quality !== null ? Math.round(quality * 100) : 95,
      });
      const helper = new util.Base64Helper();
      return {
        base64: helper.encodeToStringSync(new Uint8Array(packed)),
        width,
        height,
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
      if (source) {
        try {
          source.release();
        } catch {
          // ignore
        }
      }
    }
  }

  private supportedCameras(): camera.CameraDevice[] {
    const manager = camera.getCameraManager(this.context);
    const supported = manager.getSupportedCameras().slice();
    supported.sort((left, right) => left.cameraId.localeCompare(right.cameraId));
    return supported;
  }

  private findCameraById(deviceId: string): camera.CameraDevice | null {
    const supported = this.supportedCameras();
    for (let i = 0; i < supported.length; i++) {
      if (supported[i].cameraId === deviceId) {
        return supported[i];
      }
    }
    return null;
  }

  private resolveRequestedCameraPosition(
    facing: string | null,
    deviceId: string | null,
  ): camera.CameraPosition {
    if (deviceId !== null) {
      const matched = this.findCameraById(deviceId);
      if (matched === null) {
        throw new Error(`INVALID_REQUEST: unknown camera deviceId '${deviceId}'`);
      }
      return matched.cameraPosition;
    }
    return this.resolvePickerCameraPosition(facing);
  }

  private resolvePickerCameraPosition(facing: string | null): camera.CameraPosition {
    if (facing === 'front') {
      return camera.CameraPosition.CAMERA_POSITION_FRONT;
    }
    return camera.CameraPosition.CAMERA_POSITION_BACK;
  }

  private cameraPosition(value: camera.CameraPosition): string {
    if (value === camera.CameraPosition.CAMERA_POSITION_FRONT) {
      return 'front';
    }
    if (value === camera.CameraPosition.CAMERA_POSITION_BACK) {
      return 'back';
    }
    return 'unknown';
  }

  private cameraType(value: camera.CameraType): string {
    if (value === camera.CameraType.CAMERA_TYPE_ULTRA_WIDE) {
      return 'ultraWide';
    }
    if (value === camera.CameraType.CAMERA_TYPE_TELEPHOTO) {
      return 'telephoto';
    }
    if (value === camera.CameraType.CAMERA_TYPE_TRUE_DEPTH) {
      return 'trueDepth';
    }
    if (value === camera.CameraType.CAMERA_TYPE_WIDE_ANGLE) {
      return 'wideAngle';
    }
    return 'default';
  }

  private cameraName(position: camera.CameraPosition): string {
    if (position === camera.CameraPosition.CAMERA_POSITION_FRONT) {
      return 'Front Camera';
    }
    if (position === camera.CameraPosition.CAMERA_POSITION_BACK) {
      return 'Back Camera';
    }
    return 'Camera';
  }

  private errorMessage(error: JsonValue, fallback: string): string {
    if (error instanceof Error && error.message.trim().length > 0) {
      return error.message;
    }
    if (typeof error === 'object' && error !== null) {
      const root = error as CameraErrorLikeShape;
      if (typeof root.message === 'string' && root.message.trim().length > 0) {
        return root.message;
      }
      if (typeof root.code === 'string' || typeof root.code === 'number') {
        return `${fallback} (code=${String(root.code)})`;
      }
    }
    return fallback;
  }
}
