/**
 * Session strip choices (parity with Android SessionFilters.kt).
 */
import type { ChatSessionEntry } from './ChatModels';

const RECENT_WINDOW_MS = 24 * 60 * 60 * 1000;

/** Derive label from raw session key (telegram:, agent:, g- prefix, etc.). */
export function friendlySessionKeyLabel(key: string): string {
  const k = (key ?? '').trim();
  if (k.length === 0) {
    return 'Session';
  }
  const stripped = k.includes(':') ? k.substring(k.lastIndexOf(':') + 1) : k;
  const cleaned = stripped.startsWith('g-') ? stripped.substring(2) : stripped;
  const parts = cleaned.split(/[-_]/).filter((s) => s.length > 0);
  const words: string[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < parts.length; i++) {
    const w = parts[i];
    const cap = w.charAt(0).toUpperCase() + w.slice(1).toLowerCase();
    const low = cap.toLowerCase();
    if (seen.has(low)) {
      continue;
    }
    seen.add(low);
    words.push(cap);
  }
  const result = words.join(' ');
  return result.length > 0 ? result : k;
}

export function friendlyChipLabel(entry: ChatSessionEntry): string {
  const dn = entry.displayName?.trim();
  if (dn && dn.length > 0) {
    return dn;
  }
  return friendlySessionKeyLabel(entry.key);
}

export function resolveSessionChoices(
  currentSessionKey: string,
  sessions: ChatSessionEntry[],
  mainSessionKey: string,
  nowMs: number = Date.now(),
): ChatSessionEntry[] {
  const mainKey = mainSessionKey.trim().length > 0 ? mainSessionKey.trim() : 'main';
  let current = currentSessionKey.trim();
  if (current === 'main' && mainKey !== 'main') {
    current = mainKey;
  }
  const aliasKey = mainKey === 'main' ? null : 'main';
  const cutoff = nowMs - RECENT_WINDOW_MS;

  const sorted = [...sessions].sort((a, b) => (b.updatedAtMs ?? 0) - (a.updatedAtMs ?? 0));
  const recent: ChatSessionEntry[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < sorted.length; i++) {
    const entry = sorted[i];
    if (aliasKey !== null && entry.key === aliasKey) {
      continue;
    }
    if (seen.has(entry.key)) {
      continue;
    }
    seen.add(entry.key);
    if ((entry.updatedAtMs ?? 0) < cutoff) {
      continue;
    }
    recent.push(entry);
  }

  const result: ChatSessionEntry[] = [];
  const included = new Set<string>();
  let mainEntry: ChatSessionEntry | null = null;
  for (let i = 0; i < sorted.length; i++) {
    if (sorted[i].key === mainKey) {
      mainEntry = sorted[i];
      break;
    }
  }
  if (mainEntry !== null) {
    result.push(mainEntry);
    included.add(mainKey);
  } else if (current === mainKey) {
    const synthetic: ChatSessionEntry = { key: mainKey, updatedAtMs: undefined, displayName: undefined };
    result.push(synthetic);
    included.add(mainKey);
  }

  for (let i = 0; i < recent.length; i++) {
    const entry = recent[i];
    if (!included.has(entry.key)) {
      included.add(entry.key);
      result.push(entry);
    }
  }

  if (current.length > 0 && !included.has(current)) {
    const extra: ChatSessionEntry = { key: current, updatedAtMs: undefined, displayName: undefined };
    result.push(extra);
  }

  return result;
}
