/**
 * Gateway node.invoke canvas + A2UI commands (subset of Android InvokeDispatcher).
 */
import type { InvokeResult } from '../gateway/GatewaySession';
import {
  OpenClawCanvasA2UICommand,
  OpenClawCanvasCommand,
} from '../protocol/OpenClawProtocol';
import {
  parseCanvasEvalJs,
  parseCanvasNavigateUrl,
  parseSnapshotParams,
} from './CanvasParams';
import {
  A2UI_READY_CHECK_JS,
  A2UI_RESET_JS,
  a2uiApplyMessagesJS,
  decodeA2uiMessages,
} from './A2UIHarmony';
import type { CanvasWebHost } from './CanvasWebHost';

type JsonRec = Record<string, object | string | number | boolean | null>;
interface SnapshotPayload {
  format: string;
  base64: string;
}

function invokeOk(payload: string | null): InvokeResult {
  return { ok: true, payloadJson: payload, error: null };
}

function invokeErr(code: string, message: string): InvokeResult {
  return { ok: false, payloadJson: null, error: { code, message } };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function buildSnapshotJs(format: 'png' | 'jpeg', quality: number | null, maxWidth: number | null): string {
  const mime = format === 'png' ? 'image/png' : 'image/jpeg';
  const qualityJs = quality === null ? (format === 'png' ? 'undefined' : '0.82') : String(quality);
  const maxWidthJs = maxWidth === null ? 'null' : String(maxWidth);
  return `(() => {
    try {
      const firstCanvas = document.querySelector('canvas');
      if (!firstCanvas) return JSON.stringify({ ok: false, error: 'SNAPSHOT_UNAVAILABLE: no canvas element' });
      const source = firstCanvas;
      let target = source;
      const maxWidth = ${maxWidthJs};
      if (typeof maxWidth === 'number' && Number.isFinite(maxWidth) && maxWidth > 0 && source.width > maxWidth) {
        const scale = maxWidth / source.width;
        const w = Math.max(1, Math.floor(source.width * scale));
        const h = Math.max(1, Math.floor(source.height * scale));
        const resized = document.createElement('canvas');
        resized.width = w;
        resized.height = h;
        const ctx = resized.getContext('2d');
        if (!ctx) return JSON.stringify({ ok: false, error: 'SNAPSHOT_UNAVAILABLE: 2d context unavailable' });
        ctx.drawImage(source, 0, 0, w, h);
        target = resized;
      }
      const dataUrl = target.toDataURL('${mime}', ${qualityJs});
      const comma = dataUrl.indexOf(',');
      if (comma < 0) return JSON.stringify({ ok: false, error: 'SNAPSHOT_UNAVAILABLE: malformed data url' });
      const base64 = dataUrl.substring(comma + 1);
      return JSON.stringify({
        ok: true,
        format: '${format}',
        mimeType: '${mime}',
        base64,
        width: target.width,
        height: target.height
      });
    } catch (e) {
      return JSON.stringify({ ok: false, error: 'SNAPSHOT_FAILED: ' + String(e && e.message ? e.message : e) });
    }
  })()`;
}

function parseJsResultObject(raw: string): JsonRec | null {
  const text = raw.trim();
  if (text.length === 0) {
    return null;
  }
  try {
    const direct = JSON.parse(text) as JsonRec;
    if (direct && typeof direct === 'object') {
      return direct;
    }
  } catch {
    // fall through
  }
  try {
    const quoted = JSON.parse(text) as string;
    const obj = JSON.parse(String(quoted)) as JsonRec;
    if (obj && typeof obj === 'object') {
      return obj;
    }
  } catch {
    // fall through
  }
  return null;
}

export interface CanvasInvokeDeps {
  canvas: CanvasWebHost;
  getNodeCanvasHost: () => string | null;
  getOperatorCanvasHost: () => string | null;
  refreshNodeCanvasCapability: () => Promise<boolean>;
  onNavigate: () => void;
  onA2uiPush: () => void;
  onA2uiReset: () => void;
}

export class CanvasInvokeHandler {
  private deps: CanvasInvokeDeps;

  constructor(deps: CanvasInvokeDeps) {
    this.deps = deps;
  }

  private resolveA2uiHostUrl(): string | null {
    const nodeRaw = (this.deps.getNodeCanvasHost() ?? '').trim();
    const opRaw = (this.deps.getOperatorCanvasHost() ?? '').trim();
    const raw = nodeRaw.length > 0 ? nodeRaw : opRaw;
    if (raw.length === 0) {
      return null;
    }
    const base = raw.replace(/\/+$/, '');
    return `${base}/__openclaw__/a2ui/?platform=harmony`;
  }

  private async ensureA2uiReady(a2uiUrl: string): Promise<boolean> {
    const canvas = this.deps.canvas;
    try {
      const already = await canvas.runJavaScript(A2UI_READY_CHECK_JS);
      if (already.trim() === 'true') {
        return true;
      }
    } catch {
      // continue
    }
    canvas.navigate(a2uiUrl);
    for (let i = 0; i < 50; i++) {
      try {
        const ready = await canvas.runJavaScript(A2UI_READY_CHECK_JS);
        if (ready.trim() === 'true') {
          return true;
        }
      } catch {
        // continue
      }
      await sleep(120);
    }
    return false;
  }

  private async withReadyA2ui(block: () => Promise<InvokeResult>): Promise<InvokeResult> {
    let a2uiUrl = this.resolveA2uiHostUrl();
    if (!a2uiUrl) {
      return invokeErr(
        'A2UI_HOST_NOT_CONFIGURED',
        'A2UI_HOST_NOT_CONFIGURED: gateway did not advertise canvas host',
      );
    }
    let ready = await this.ensureA2uiReady(a2uiUrl);
    if (!ready) {
      const refreshed = await this.deps.refreshNodeCanvasCapability();
      if (!refreshed) {
        return invokeErr(
          'A2UI_HOST_UNAVAILABLE',
          'A2UI_HOST_UNAVAILABLE: A2UI host not reachable',
        );
      }
      a2uiUrl = this.resolveA2uiHostUrl();
      if (!a2uiUrl) {
        return invokeErr(
          'A2UI_HOST_NOT_CONFIGURED',
          'A2UI_HOST_NOT_CONFIGURED: gateway did not advertise canvas host',
        );
      }
      ready = await this.ensureA2uiReady(a2uiUrl);
      if (!ready) {
        return invokeErr(
          'A2UI_HOST_UNAVAILABLE',
          'A2UI_HOST_UNAVAILABLE: A2UI host not reachable',
        );
      }
    }
    return block();
  }

  private async withCanvasAvailable(block: () => Promise<InvokeResult>): Promise<InvokeResult> {
    try {
      if (!this.deps.canvas.hasController()) {
        return invokeErr(
          'NODE_BACKGROUND_UNAVAILABLE',
          'NODE_BACKGROUND_UNAVAILABLE: open the Screen tab to attach the canvas WebView',
        );
      }
      return await block();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return invokeErr('NODE_BACKGROUND_UNAVAILABLE', `NODE_BACKGROUND_UNAVAILABLE: ${msg}`);
    }
  }

  async tryHandle(command: string, paramsJson: string | null): Promise<InvokeResult | null> {
    const canvas = this.deps.canvas;

    if (command === OpenClawCanvasCommand.Present) {
      const url = parseCanvasNavigateUrl(paramsJson);
      canvas.navigate(url);
      this.deps.onNavigate();
      return invokeOk(null);
    }
    if (command === OpenClawCanvasCommand.Hide) {
      return invokeOk(null);
    }
    if (command === OpenClawCanvasCommand.Navigate) {
      const url = parseCanvasNavigateUrl(paramsJson);
      canvas.navigate(url);
      this.deps.onNavigate();
      return invokeOk(null);
    }
    if (command === OpenClawCanvasCommand.Eval) {
      const js = parseCanvasEvalJs(paramsJson);
      if (!js) {
        return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: javaScript required');
      }
      return this.withCanvasAvailable(async () => {
        const result = await canvas.runJavaScript(js);
        return invokeOk(JSON.stringify({ result }));
      });
    }
    if (command === OpenClawCanvasCommand.Snapshot) {
      const snapshot = parseSnapshotParams(paramsJson);
      return this.withCanvasAvailable(async () => {
        try {
          const base64 = await canvas.snapshotBase64(
            snapshot.format,
            snapshot.quality,
            snapshot.maxWidth,
          );
          const payload: SnapshotPayload = {
            format: snapshot.format,
            base64,
          };
          return invokeOk(JSON.stringify(payload));
        } catch {
          const js = buildSnapshotJs(snapshot.format, snapshot.quality, snapshot.maxWidth);
          const raw = await canvas.runJavaScript(js);
          const obj = parseJsResultObject(raw);
          if (!obj) {
            return invokeErr('SNAPSHOT_UNAVAILABLE', 'SNAPSHOT_UNAVAILABLE: invalid snapshot result');
          }
          if (obj['ok'] !== true) {
            const err = String(obj['error'] ?? 'SNAPSHOT_UNAVAILABLE');
            return invokeErr('SNAPSHOT_UNAVAILABLE', err);
          }
          const base64 = String(obj['base64'] ?? '').trim();
          if (base64.length === 0) {
            return invokeErr('SNAPSHOT_UNAVAILABLE', 'SNAPSHOT_UNAVAILABLE: empty snapshot');
          }
          const payload: SnapshotPayload = {
            format: String(obj['format'] ?? snapshot.format),
            base64: base64,
          };
          return invokeOk(JSON.stringify(payload));
        }
      });
    }

    if (command === OpenClawCanvasA2UICommand.Reset) {
      return this.withReadyA2ui(() =>
        this.withCanvasAvailable(async () => {
          const res = await canvas.runJavaScript(A2UI_RESET_JS);
          this.deps.onA2uiReset();
          return invokeOk(res.length > 0 ? res : null);
        }),
      );
    }
    if (command === OpenClawCanvasA2UICommand.Push || command === OpenClawCanvasA2UICommand.PushJSONL) {
      let messagesJson: string;
      try {
        messagesJson = decodeA2uiMessages(command, paramsJson);
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        return invokeErr('INVALID_REQUEST', msg);
      }
      return this.withReadyA2ui(() =>
        this.withCanvasAvailable(async () => {
          const js = a2uiApplyMessagesJS(messagesJson);
          const res = await canvas.runJavaScript(js);
          this.deps.onA2uiPush();
          return invokeOk(res.length > 0 ? res : null);
        }),
      );
    }

    return null;
  }
}
