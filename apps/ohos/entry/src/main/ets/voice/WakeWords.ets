const DEFAULT_WAKE_WORDS: string[] = ['openclaw', 'claude'];
const MAX_WORDS = 32;
const MAX_WORD_LENGTH = 64;

export function defaultWakeWords(): string[] {
  return DEFAULT_WAKE_WORDS.slice();
}

export function parseWakeWordsCsv(input: string): string[] {
  return input
    .split(',')
    .map((item: string) => item.trim())
    .filter((item: string) => item.length > 0);
}

export function sanitizeWakeWords(words: string[], defaults: string[] = DEFAULT_WAKE_WORDS): string[] {
  const next: string[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < words.length && next.length < MAX_WORDS; i++) {
    const trimmed = words[i].trim().slice(0, MAX_WORD_LENGTH);
    const dedupeKey = trimmed.toLowerCase();
    if (trimmed.length === 0 || seen.has(dedupeKey)) {
      continue;
    }
    seen.add(dedupeKey);
    next.push(trimmed);
  }
  return next.length > 0 ? next : defaults.slice();
}
