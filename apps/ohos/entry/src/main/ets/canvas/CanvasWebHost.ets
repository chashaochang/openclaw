/**
 * Web canvas host: load scaffold or remote URL, inject home/debug state, run JS (eval / A2UI).
 */
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { webview } from '@kit.ArkWeb';
import type { CanvasSnapshotFormat } from './CanvasParams';

/** Rawfile URL for bundled CanvasScaffold (matches Android asset path layout). */
export const CANVAS_SCAFFOLD_RESOURCE_URL = 'resource://rawfile/CanvasScaffold/scaffold.html';

export class OpenClawCanvasA2UIBridge {
  private readonly onPost: (payload: string) => void;

  constructor(onPost: (payload: string) => void) {
    this.onPost = onPost;
  }

  postMessage(payload: string): void {
    this.onPost(payload ?? '');
  }
}

export class CanvasWebHost {
  private controller: webview.WebviewController | null = null;
  /** Latest document URL from Web (for A2UI postMessage trust checks). */
  private currentDocumentUrl: string = '';
  private targetUrl: string | null = null;
  private homeStateJson: string | null = null;
  private debugEnabled = false;
  private debugTitle: string | null = null;
  private debugSubtitle: string | null = null;

  attach(ctrl: webview.WebviewController): void {
    this.controller = ctrl;
    this.refreshCurrentUrlFromController();
    this.syncLoadToController();
    void this.applyInjections();
  }

  /** Apply pending navigation without reloading scaffold if Web already loaded it via `src`. */
  private syncLoadToController(): void {
    const c = this.controller;
    if (!c) {
      return;
    }
    const u = this.targetUrl;
    if (u !== null && u.length > 0) {
      try {
        c.loadUrl(u);
      } catch {
        // ignore
      }
      return;
    }
    if (this.isScaffoldDocumentUrl(this.currentDocumentUrl)) {
      return;
    }
    try {
      c.loadUrl(CANVAS_SCAFFOLD_RESOURCE_URL);
    } catch {
      // ignore
    }
  }

  private isScaffoldDocumentUrl(url: string | null | undefined): boolean {
    const trimmed = (url ?? '').trim();
    if (trimmed.length === 0) {
      return false;
    }
    const normalized = trimmed.replace(/[?#].*$/, '');
    return normalized === CANVAS_SCAFFOLD_RESOURCE_URL;
  }

  detach(ctrl: webview.WebviewController): void {
    if (this.controller === ctrl) {
      this.controller = null;
    }
  }

  hasController(): boolean {
    return this.controller !== null;
  }

  setCurrentUrl(url: string): void {
    this.currentDocumentUrl = (url ?? '').trim();
  }

  clearCurrentUrl(): void {
    this.currentDocumentUrl = '';
  }

  getCurrentUrl(): string | null {
    const u = this.currentDocumentUrl.trim();
    return u.length > 0 ? u : null;
  }

  refreshCurrentUrlFromController(): string | null {
    const c = this.controller;
    if (!c) {
      return this.getCurrentUrl();
    }
    try {
      const raw = c.getUrl()?.trim() ?? '';
      if (raw.length > 0) {
        this.currentDocumentUrl = raw;
      }
    } catch {
      // ignore controller URL lookup failures
    }
    return this.getCurrentUrl();
  }

  navigate(url: string): void {
    const t = url.trim();
    if (t.length === 0 || t === '/') {
      this.targetUrl = null;
      this.currentDocumentUrl = CANVAS_SCAFFOLD_RESOURCE_URL;
    } else {
      this.targetUrl = t;
      this.currentDocumentUrl = t;
    }
    this.reload();
  }

  getTargetUrl(): string | null {
    return this.targetUrl;
  }

  isDefaultScaffold(): boolean {
    return this.targetUrl === null;
  }

  getDisplayUrl(): string {
    const u = this.targetUrl;
    if (u !== null && u.length > 0) {
      return u;
    }
    return CANVAS_SCAFFOLD_RESOURCE_URL;
  }

  setHomeStateJson(json: string | null): void {
    this.homeStateJson = json;
    void this.applyInjections();
  }

  setDebugStatus(enabled: boolean, title?: string | null, subtitle?: string | null): void {
    this.debugEnabled = enabled;
    this.debugTitle = title ?? null;
    this.debugSubtitle = subtitle ?? null;
    void this.applyInjections();
  }

  reloadCurrent(): void {
    const c = this.controller;
    if (!c) {
      return;
    }
    const u = this.targetUrl;
    try {
      if (u === null || u.length === 0) {
        this.currentDocumentUrl = CANVAS_SCAFFOLD_RESOURCE_URL;
        c.loadUrl(CANVAS_SCAFFOLD_RESOURCE_URL);
      } else {
        this.currentDocumentUrl = u;
        c.loadUrl(u);
      }
    } catch {
      // loadUrl can throw if controller is tearing down.
    }
  }

  private reload(): void {
    this.reloadCurrent();
  }

  notifyPageEnd(): void {
    void this.applyInjections();
  }

  private async applyInjections(): Promise<void> {
    const c = this.controller;
    if (!c) {
      return;
    }
    await this.applyDebugStatus(c);
    await this.applyHomeState(c);
  }

  private async applyDebugStatus(c: webview.WebviewController): Promise<void> {
    const titleJs = this.debugTitle ? JSON.stringify(this.debugTitle) : 'null';
    const subtitleJs = this.debugSubtitle ? JSON.stringify(this.debugSubtitle) : 'null';
    const en = this.debugEnabled ? 'true' : 'false';
    const js =
      `(() => { try { const api = globalThis.__openclaw; if (!api) return; ` +
      `if (typeof api.setDebugStatusEnabled === 'function') { api.setDebugStatusEnabled(${en}); } ` +
      `if (!${en}) return; if (typeof api.setStatus === 'function') { api.setStatus(${titleJs}, ${subtitleJs}); } ` +
      `} catch (_) {} })();`;
    try {
      await c.runJavaScript(js);
    } catch {
      // Page may not be ready yet.
    }
  }

  private async applyHomeState(c: webview.WebviewController): Promise<void> {
    const payload = this.homeStateJson ?? 'null';
    const js =
      `(() => { try { const api = globalThis.__openclaw; if (!api || typeof api.renderHome !== 'function') return; ` +
      `api.renderHome(${payload}); } catch (_) {} })();`;
    try {
      await c.runJavaScript(js);
    } catch {
      // Page may not be ready yet.
    }
  }

  async runJavaScript(script: string): Promise<string> {
    const c = this.controller;
    if (!c) {
      throw new Error('no webview');
    }
    const result = await c.runJavaScript(script);
    return result ?? '';
  }

  async snapshotBase64(
    format: CanvasSnapshotFormat,
    quality: number | null,
    maxWidth: number | null,
  ): Promise<string> {
    const c = this.controller;
    if (!c) {
      throw new Error('no webview');
    }
    const snapshot = await this.captureWholePageSnapshot(c);
    const pixelMap = snapshot.imagePixelMap;
    if (!snapshot.status || !pixelMap) {
      throw new Error('SNAPSHOT_UNAVAILABLE: native snapshot failed');
    }
    try {
      await this.scalePixelMapIfNeeded(pixelMap, maxWidth);
      const encoded = await this.packPixelMapToBase64(pixelMap, format, quality);
      if (encoded.length === 0) {
        throw new Error('SNAPSHOT_UNAVAILABLE: empty native snapshot');
      }
      return encoded;
    } finally {
      try {
        pixelMap.release();
      } catch {
        // ignore
      }
    }
  }

  private captureWholePageSnapshot(c: webview.WebviewController): Promise<webview.SnapshotResult> {
    return new Promise((resolve, reject) => {
      try {
        c.webPageSnapshot({}, (error, result) => {
          if (error) {
            const msg = error.message?.trim();
            reject(new Error(msg && msg.length > 0 ? msg : `snapshot failed (${error.code})`));
            return;
          }
          resolve(result ?? {});
        });
      } catch (error) {
        reject(error);
      }
    });
  }

  private async scalePixelMapIfNeeded(
    pixelMap: image.PixelMap,
    maxWidth: number | null,
  ): Promise<void> {
    if (maxWidth === null || maxWidth <= 0) {
      return;
    }
    const info = pixelMap.getImageInfoSync();
    const width = info.size.width;
    if (width <= 0 || width <= maxWidth) {
      return;
    }
    const scale = maxWidth / width;
    if (!(scale > 0 && scale < 1)) {
      return;
    }
    await pixelMap.scale(scale, scale);
  }

  private async packPixelMapToBase64(
    pixelMap: image.PixelMap,
    format: CanvasSnapshotFormat,
    quality: number | null,
  ): Promise<string> {
    const packer = image.createImagePacker();
    const packed = await packer.packing(pixelMap, {
      format: format === 'png' ? 'image/png' : 'image/jpeg',
      quality: this.snapshotQualityPercent(format, quality),
    });
    const helper = new util.Base64Helper();
    return helper.encodeToStringSync(new Uint8Array(packed));
  }

  private snapshotQualityPercent(format: CanvasSnapshotFormat, quality: number | null): number {
    if (format === 'png') {
      return 100;
    }
    const normalized = quality === null ? 0.82 : Math.min(1, Math.max(0.1, quality));
    return Math.max(1, Math.min(100, Math.round(normalized * 100)));
  }
}
