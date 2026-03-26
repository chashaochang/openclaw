/**
 * A2UI user-action → agent message formatting (matches Android OpenClawCanvasA2UIAction).
 */
export type A2UIUserActionMap = Record<string, string | number | boolean | object | null>;

export function sanitizeTagValue(value: string): string {
  const trimmed = value.trim().length > 0 ? value.trim() : '-';
  const normalized = trimmed.replace(/ /g, '_');
  let out = '';
  for (let i = 0; i < normalized.length; i++) {
    const c = normalized.charAt(i);
    const ok = /[a-zA-Z0-9_.:-]/.test(c);
    out += ok ? c : '_';
  }
  return out;
}

export function extractActionName(userAction: A2UIUserActionMap): string | null {
  const name = String(userAction['name'] ?? '').trim();
  if (name.length > 0) {
    return name;
  }
  const action = String(userAction['action'] ?? '').trim();
  return action.length > 0 ? action : null;
}

export function formatAgentMessage(
  actionName: string,
  sessionKey: string,
  surfaceId: string,
  sourceComponentId: string,
  host: string,
  instanceId: string,
  contextJson: string | null,
): string {
  const ctxSuffix = contextJson && contextJson.trim().length > 0 ? ` ctx=${contextJson}` : '';
  return [
    'CANVAS_A2UI',
    `action=${sanitizeTagValue(actionName)}`,
    `session=${sanitizeTagValue(sessionKey)}`,
    `surface=${sanitizeTagValue(surfaceId)}`,
    `component=${sanitizeTagValue(sourceComponentId)}`,
    `host=${sanitizeTagValue(host)}`,
    `instance=${sanitizeTagValue(instanceId)}${ctxSuffix}`,
    'default=update_canvas',
  ].join(' ');
}

function jsonStringLiteral(raw: string): string {
  return JSON.stringify(raw).replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
}

export function jsDispatchA2UIActionStatus(actionId: string, ok: boolean, error: string | null): string {
  const err = jsonStringLiteral(error ?? '');
  const okLiteral = ok ? 'true' : 'false';
  const idLiteral = jsonStringLiteral(actionId);
  return `window.dispatchEvent(new CustomEvent('openclaw:a2ui-action-status', { detail: { id: ${idLiteral}, ok: ${okLiteral}, error: ${err} } }));`;
}
