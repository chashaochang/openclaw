/**
 * Parse canvas.invoke params (matches Android CanvasController companions).
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

function parseParamsObject(paramsJson: string | null | undefined): JsonRecord | null {
  const raw = (paramsJson ?? '').trim();
  if (raw.length === 0) {
    return null;
  }
  try {
    const v = JSON.parse(raw) as JsonRecord;
    return v;
  } catch {
    return null;
  }
}

function objString(obj: JsonRecord | null, key: string): string {
  if (!obj) {
    return '';
  }
  const v = obj[key];
  if (v === null || v === undefined) {
    return '';
  }
  if (typeof v === 'string') {
    return v === 'null' ? '' : v;
  }
  return String(v);
}

export function parseCanvasNavigateUrl(paramsJson: string | null | undefined): string {
  const obj = parseParamsObject(paramsJson);
  return objString(obj, 'url').trim();
}

export function parseCanvasEvalJs(paramsJson: string | null | undefined): string | null {
  const obj = parseParamsObject(paramsJson);
  const js = objString(obj, 'javaScript').trim();
  return js.length > 0 ? js : null;
}

export type CanvasSnapshotFormat = 'png' | 'jpeg';

export interface CanvasSnapshotParams {
  format: CanvasSnapshotFormat;
  quality: number | null;
  maxWidth: number | null;
}

export function parseSnapshotFormat(paramsJson: string | null | undefined): CanvasSnapshotFormat {
  const obj = parseParamsObject(paramsJson);
  const raw = objString(obj, 'format').trim().toLowerCase();
  if (raw === 'png') {
    return 'png';
  }
  return 'jpeg';
}

export function parseSnapshotQuality(paramsJson: string | null | undefined): number | null {
  const obj = parseParamsObject(paramsJson);
  if (!obj || !recordHasKey(obj, 'quality')) {
    return null;
  }
  const v = obj['quality'];
  const n = typeof v === 'number' ? v : parseFloat(String(v));
  if (!Number.isFinite(n)) {
    return null;
  }
  return Math.min(1, Math.max(0.1, n));
}

export function parseSnapshotMaxWidth(paramsJson: string | null | undefined): number | null {
  const obj = parseParamsObject(paramsJson);
  if (!obj || !recordHasKey(obj, 'maxWidth')) {
    return null;
  }
  const v = obj['maxWidth'];
  const n = typeof v === 'number' ? v : parseInt(String(v), 10);
  if (!Number.isFinite(n) || n <= 0) {
    return null;
  }
  return n;
}

export function parseSnapshotParams(paramsJson: string | null | undefined): CanvasSnapshotParams {
  return {
    format: parseSnapshotFormat(paramsJson),
    quality: parseSnapshotQuality(paramsJson),
    maxWidth: parseSnapshotMaxWidth(paramsJson),
  };
}
