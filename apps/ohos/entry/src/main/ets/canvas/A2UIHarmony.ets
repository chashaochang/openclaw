/**
 * A2UI v0.8 message decode + JS snippets (matches Android A2UIHandler companion).
 */
type JsonRecord = Record<string, object | string | number | boolean | null>;

function recordHasKey(obj: JsonRecord, key: string): boolean {
  const ks = Object.keys(obj);
  for (let i = 0; i < ks.length; i++) {
    if (ks[i] === key) {
      return true;
    }
  }
  return false;
}

export const A2UI_READY_CHECK_JS: string = `(() => {
  try {
    const host = globalThis.openclawA2UI;
    return !!host && typeof host.applyMessages === 'function';
  } catch (_) {
    return false;
  }
})()`;

export const A2UI_RESET_JS: string = `(() => {
  try {
    const host = globalThis.openclawA2UI;
    if (!host) return { ok: false, error: "missing openclawA2UI" };
    return host.reset();
  } catch (e) {
    return { ok: false, error: String(e?.message ?? e) };
  }
})()`;

export function a2uiApplyMessagesJS(messagesJson: string): string {
  return `(() => {
    try {
      const host = globalThis.openclawA2UI;
      if (!host) return { ok: false, error: "missing openclawA2UI" };
      const messages = ${messagesJson};
      return host.applyMessages(messages);
    } catch (e) {
      return { ok: false, error: String(e?.message ?? e) };
    }
  })()`;
}

function validateA2uiV0_8(msg: JsonRecord, lineNumber: number): void {
  if (recordHasKey(msg, 'createSurface')) {
    throw new Error(
      `A2UI JSONL line ${lineNumber}: looks like A2UI v0.9 (\`createSurface\`). Canvas supports v0.8 messages only.`,
    );
  }
  const allowed = new Set(['beginRendering', 'surfaceUpdate', 'dataModelUpdate', 'deleteSurface']);
  const keys = Object.keys(msg).filter((k) => allowed.has(k));
  if (keys.length !== 1) {
    const found = Object.keys(msg).sort().join(', ');
    throw new Error(
      `A2UI JSONL line ${lineNumber}: expected exactly one of ${Array.from(allowed).sort().join(', ')}; found: ${found}`,
    );
  }
}

export function decodeA2uiMessages(command: string, paramsJson: string | null | undefined): string {
  const raw = (paramsJson ?? '').trim();
  if (raw.length === 0) {
    throw new Error('INVALID_REQUEST: paramsJSON required');
  }
  const obj = JSON.parse(raw) as JsonRecord;
  if (!obj || typeof obj !== 'object') {
    throw new Error('INVALID_REQUEST: expected object params');
  }
  const jsonlField = String(obj['jsonl'] ?? '').trim();
  const hasMessagesArray = Array.isArray(obj['messages']);

  if (command === 'canvas.a2ui.pushJSONL' || (!hasMessagesArray && jsonlField.length > 0)) {
    if (jsonlField.length === 0) {
      throw new Error('INVALID_REQUEST: jsonl required');
    }
    const lines = jsonlField.split('\n');
    const messages: JsonRecord[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const el = JSON.parse(line) as JsonRecord;
      if (!el || typeof el !== 'object') {
        throw new Error(`A2UI JSONL line ${i + 1}: expected a JSON object`);
      }
      validateA2uiV0_8(el, i + 1);
      messages.push(el);
    }
    return JSON.stringify(messages);
  }

  const arr = obj['messages'];
  if (!Array.isArray(arr)) {
    throw new Error('INVALID_REQUEST: messages[] required');
  }
  const out: JsonRecord[] = [];
  for (let i = 0; i < arr.length; i++) {
    const el = arr[i] as JsonRecord;
    if (!el || typeof el !== 'object') {
      throw new Error(`A2UI messages[${i}]: expected a JSON object`);
    }
    validateA2uiV0_8(el, i + 1);
    out.push(el);
  }
  return JSON.stringify(out);
}
