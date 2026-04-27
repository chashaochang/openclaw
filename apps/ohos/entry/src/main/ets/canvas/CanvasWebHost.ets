/**
 * Web canvas host: load scaffold or remote URL, inject home/debug state, run JS (eval / A2UI).
 */
import { webview } from '@kit.ArkWeb';

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
    }
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

  navigate(url: string): void {
    const t = url.trim();
    this.currentDocumentUrl = '';
    if (t.length === 0 || t === '/') {
      this.targetUrl = null;
    } else {
      this.targetUrl = t;
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
        c.loadUrl(CANVAS_SCAFFOLD_RESOURCE_URL);
      } else {
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
}
