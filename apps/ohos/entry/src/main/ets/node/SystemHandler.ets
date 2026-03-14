/**
 * System invoke handler: system.notify.
 */
import { notificationManager } from '@kit.NotificationKit';
import type { InvokeResult, InvokeErrorShape } from '../gateway/GatewaySession';

interface NotifyParams {
  title: string;
  body: string;
}

function invokeOk(): InvokeResult {
  const r: InvokeResult = { ok: true, payloadJson: null, error: null };
  return r;
}

function invokeErr(code: string, message: string): InvokeResult {
  const err: InvokeErrorShape = { code, message };
  const r: InvokeResult = { ok: false, payloadJson: null, error: err };
  return r;
}

function parseNotifyRequest(paramsJson: string | null): NotifyParams | null {
  if (!paramsJson || !paramsJson.trim()) return null;
  try {
    const obj = JSON.parse(paramsJson) as Record<string, string>;
    const title = String(obj['title'] ?? '').trim();
    const body = String(obj['body'] ?? '').trim();
    return { title, body };
  } catch {
    return null;
  }
}

export class SystemHandler {
  async handleSystemNotify(paramsJson: string | null): Promise<InvokeResult> {
    const params = parseNotifyRequest(paramsJson);
    if (!params) {
      return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: expected JSON object with title/body');
    }
    if (params.title.length === 0 && params.body.length === 0) {
      return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: empty notification');
    }
    try {
      const req: notificationManager.NotificationRequest = {
        id: Math.floor(Date.now() % 0x7FFFFFFF),
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: params.title || 'OpenClaw',
            text: params.body,
            additionalText: '',
          },
        },
      };
      await notificationManager.publish(req);
      return invokeOk();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return invokeErr('UNAVAILABLE', `NOTIFICATION_FAILED: ${msg}`);
    }
  }
}
