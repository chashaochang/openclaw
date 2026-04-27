function escapeRegex(raw: string): string {
  return raw.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export class VoiceWakeCommandExtractor {
  static extractCommand(text: string, triggerWords: string[]): string | null {
    const raw = text.trim();
    if (raw.length === 0) {
      return null;
    }
    const triggers = triggerWords
      .map((item: string) => item.trim().toLowerCase())
      .filter((item: string) => item.length > 0);
    if (triggers.length === 0) {
      return null;
    }
    const alternation = triggers.map((item: string) => escapeRegex(item)).join('|');
    const punctuation = `[\\s.,!?;:'"“”‘’，。！？；：、()\\[\\]{}<>\\-_/]*`;
    const pattern = new RegExp(`(?:^|\\s)(${alternation})\\b${punctuation}([\\s\\S]+)$`, 'i');
    const match = raw.match(pattern);
    if (!match || match.length < 3) {
      return null;
    }
    const extracted = (match[2] ?? '').trim();
    if (extracted.length === 0) {
      return null;
    }
    const cleaned = extracted.replace(new RegExp(`^${punctuation}`), '').trim();
    return cleaned.length > 0 ? cleaned : null;
  }
}
