/**
 * First-line JSON talk directives (parity with Android TalkDirectiveParser + TalkModeRuntime).
 */

type JsonVal = string | number | boolean | object | null;
type HeadRecord = Record<string, JsonVal>;

export interface TalkDirective {
  voiceId: string | null;
  modelId: string | null;
  speed: number | null;
  rateWpm: number | null;
  stability: number | null;
  similarity: number | null;
  style: number | null;
  speakerBoost: boolean | null;
  seed: number | null;
  normalize: string | null;
  language: string | null;
  outputFormat: string | null;
  latencyTier: number | null;
  once: boolean | null;
}

export interface TalkDirectiveParseResult {
  directive: TalkDirective | null;
  stripped: string;
  unknownKeys: string[];
}

function strVal(obj: HeadRecord, keys: string[]): string | null {
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    const raw = obj[k];
    if (raw === null || raw === undefined) {
      continue;
    }
    const s = typeof raw === 'string' ? raw.trim() : String(raw).trim();
    if (s.length > 0) {
      return s;
    }
  }
  return null;
}

function doubleVal(obj: HeadRecord, keys: string[]): number | null {
  for (let i = 0; i < keys.length; i++) {
    const raw = obj[keys[i]];
    if (raw === null || raw === undefined) {
      continue;
    }
    if (typeof raw === 'number' && Number.isFinite(raw)) {
      return raw;
    }
    if (typeof raw === 'string') {
      const n = parseFloat(raw.trim());
      if (Number.isFinite(n)) {
        return n;
      }
    }
  }
  return null;
}

function intVal(obj: HeadRecord, keys: string[]): number | null {
  for (let i = 0; i < keys.length; i++) {
    const raw = obj[keys[i]];
    if (raw === null || raw === undefined) {
      continue;
    }
    if (typeof raw === 'number' && Number.isFinite(raw)) {
      return Math.trunc(raw);
    }
    if (typeof raw === 'string') {
      const n = parseInt(raw.trim(), 10);
      if (!Number.isNaN(n)) {
        return n;
      }
    }
  }
  return null;
}

function longVal(obj: HeadRecord, keys: string[]): number | null {
  const d = doubleVal(obj, keys);
  if (d === null) {
    return null;
  }
  const t = Math.trunc(d);
  if (!Number.isFinite(t)) {
    return null;
  }
  return t;
}

function boolVal(obj: HeadRecord, keys: string[]): boolean | null {
  for (let i = 0; i < keys.length; i++) {
    const raw = obj[keys[i]];
    if (raw === null || raw === undefined) {
      continue;
    }
    if (typeof raw === 'boolean') {
      return raw;
    }
    if (typeof raw === 'number') {
      if (raw === 1) {
        return true;
      }
      if (raw === 0) {
        return false;
      }
    }
    if (typeof raw === 'string') {
      const c = raw.trim().toLowerCase();
      if (c === 'true' || c === 'yes' || c === '1') {
        return true;
      }
      if (c === 'false' || c === 'no' || c === '0') {
        return false;
      }
    }
  }
  return null;
}

function parseHeadObject(line: string): HeadRecord | null {
  try {
    const v = JSON.parse(line) as object;
    if (v === null || typeof v !== 'object') {
      return null;
    }
    return v as HeadRecord;
  } catch {
    return null;
  }
}

function resolveSpeed(speed: number | null, rateWpm: number | null): number | null {
  if (rateWpm !== null && rateWpm > 0) {
    const resolved = rateWpm / 175.0;
    if (resolved <= 0.5 || resolved >= 2.0) {
      return null;
    }
    return resolved;
  }
  if (speed !== null) {
    if (speed <= 0.5 || speed >= 2.0) {
      return null;
    }
    return speed;
  }
  return null;
}

function validatedUnit(value: number | null): number | null {
  if (value === null) {
    return null;
  }
  if (value < 0 || value > 1) {
    return null;
  }
  return value;
}

function validatedStability(value: number | null, modelId: string | null): number | null {
  if (value === null) {
    return null;
  }
  const normalized = (modelId ?? '').trim().toLowerCase();
  if (normalized === 'eleven_v3') {
    if (value === 0.0 || value === 0.5 || value === 1.0) {
      return value;
    }
    return null;
  }
  return validatedUnit(value);
}

function validatedSeed(value: number | null): number | null {
  if (value === null) {
    return null;
  }
  const t = Math.trunc(value);
  if (t < 0 || t > 4294967295) {
    return null;
  }
  return t;
}

function validatedNormalize(value: string | null): string | null {
  const normalized = (value ?? '').trim().toLowerCase();
  if (normalized.length === 0) {
    return null;
  }
  if (normalized === 'auto' || normalized === 'on' || normalized === 'off') {
    return normalized;
  }
  return null;
}

function validatedLanguage(value: string | null): string | null {
  const normalized = (value ?? '').trim().toLowerCase();
  if (normalized.length !== 2) {
    return null;
  }
  for (let i = 0; i < normalized.length; i++) {
    const ch = normalized.charCodeAt(i);
    if (ch < 97 || ch > 122) {
      return null;
    }
  }
  return normalized;
}

const KNOWN_KEY_LOWER = new Set<string>([
  'voice',
  'voice_id',
  'voiceid',
  'model',
  'model_id',
  'modelid',
  'speed',
  'rate',
  'wpm',
  'stability',
  'similarity',
  'similarity_boost',
  'similarityboost',
  'style',
  'speaker_boost',
  'speakerboost',
  'no_speaker_boost',
  'nospeakerboost',
  'seed',
  'normalize',
  'apply_text_normalization',
  'lang',
  'language_code',
  'language',
  'output_format',
  'format',
  'latency',
  'latency_tier',
  'latencytier',
  'once',
]);

export function parseTalkDirective(text: string): TalkDirectiveParseResult {
  const normalized = text.replace(/\r\n/g, '\n');
  const lines = normalized.split('\n');
  if (lines.length === 0) {
    const empty: TalkDirectiveParseResult = { directive: null, stripped: text, unknownKeys: [] };
    return empty;
  }
  let firstNonEmpty = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim().length > 0) {
      firstNonEmpty = i;
      break;
    }
  }
  if (firstNonEmpty < 0) {
    const r: TalkDirectiveParseResult = { directive: null, stripped: text, unknownKeys: [] };
    return r;
  }
  const head = lines[firstNonEmpty].trim();
  if (!head.startsWith('{') || !head.endsWith('}')) {
    const r: TalkDirectiveParseResult = { directive: null, stripped: text, unknownKeys: [] };
    return r;
  }
  const obj = parseHeadObject(head);
  if (obj === null) {
    const r: TalkDirectiveParseResult = { directive: null, stripped: text, unknownKeys: [] };
    return r;
  }

  const noBoost = boolVal(obj, ['no_speaker_boost', 'noSpeakerBoost']);
  let speakerBoost = boolVal(obj, ['speaker_boost', 'speakerBoost']);
  if (noBoost !== null) {
    speakerBoost = !noBoost;
  }

  const d: TalkDirective = {
    voiceId: strVal(obj, ['voice', 'voice_id', 'voiceId']),
    modelId: strVal(obj, ['model', 'model_id', 'modelId']),
    speed: doubleVal(obj, ['speed']),
    rateWpm: intVal(obj, ['rate', 'wpm']),
    stability: doubleVal(obj, ['stability']),
    similarity: doubleVal(obj, ['similarity', 'similarity_boost', 'similarityBoost']),
    style: doubleVal(obj, ['style']),
    speakerBoost: speakerBoost,
    seed: longVal(obj, ['seed']),
    normalize: strVal(obj, ['normalize', 'apply_text_normalization']),
    language: strVal(obj, ['lang', 'language_code', 'language']),
    outputFormat: strVal(obj, ['output_format', 'format']),
    latencyTier: intVal(obj, ['latency', 'latency_tier', 'latencyTier']),
    once: boolVal(obj, ['once']),
  };

  const hasDirective =
    d.voiceId !== null ||
    d.modelId !== null ||
    d.speed !== null ||
    d.rateWpm !== null ||
    d.stability !== null ||
    d.similarity !== null ||
    d.style !== null ||
    d.speakerBoost !== null ||
    d.seed !== null ||
    d.normalize !== null ||
    d.language !== null ||
    d.outputFormat !== null ||
    d.latencyTier !== null ||
    d.once !== null;

  if (!hasDirective) {
    const r: TalkDirectiveParseResult = { directive: null, stripped: text, unknownKeys: [] };
    return r;
  }

  const keyList = Object.keys(obj);
  const unknownKeys: string[] = [];
  for (let i = 0; i < keyList.length; i++) {
    const low = keyList[i].toLowerCase();
    if (!KNOWN_KEY_LOWER.has(low)) {
      unknownKeys.push(keyList[i]);
    }
  }
  unknownKeys.sort();

  const rest = lines.slice(0);
  rest.splice(firstNonEmpty, 1);
  if (firstNonEmpty < rest.length && rest[firstNonEmpty].trim().length === 0) {
    rest.splice(firstNonEmpty, 1);
  }
  const stripped = rest.join('\n');
  const out: TalkDirectiveParseResult = { directive: d, stripped: stripped, unknownKeys: unknownKeys };
  return out;
}

export type TalkSpeakRpcParams = Record<string, string | number | boolean>;

export function buildTalkSpeakRpcParams(
  text: string,
  fallbackLanguage: string,
  directive: TalkDirective | null,
  persistentVoiceId: string | null,
  persistentModelId: string | null,
): TalkSpeakRpcParams {
  const t = (text ?? '').trim();
  const params: TalkSpeakRpcParams = {};
  params['text'] = t;

  const modelFromDir = directive !== null ? (directive.modelId ?? '').trim() : '';
  const voiceFromDir = directive !== null ? (directive.voiceId ?? '').trim() : '';
  const modelPersist = (persistentModelId ?? '').trim();
  const voicePersist = (persistentVoiceId ?? '').trim();

  const modelId = modelFromDir.length > 0 ? modelFromDir : modelPersist.length > 0 ? modelPersist : '';
  const voiceId = voiceFromDir.length > 0 ? voiceFromDir : voicePersist.length > 0 ? voicePersist : '';

  if (voiceId.length > 0) {
    params['voiceId'] = voiceId;
  }
  if (modelId.length > 0) {
    params['modelId'] = modelId;
  }

  let languageFromDirective = false;
  let outputFormatFromDirective = false;

  if (directive !== null) {
    const sp = resolveSpeed(directive.speed, directive.rateWpm);
    if (sp !== null) {
      params['speed'] = sp;
    }
    const st = validatedStability(directive.stability, modelId.length > 0 ? modelId : null);
    if (st !== null) {
      params['stability'] = st;
    }
    const sim = validatedUnit(directive.similarity);
    if (sim !== null) {
      params['similarity'] = sim;
    }
    const sty = validatedUnit(directive.style);
    if (sty !== null) {
      params['style'] = sty;
    }
    if (directive.speakerBoost !== null) {
      params['speakerBoost'] = directive.speakerBoost;
    }
    const sd = validatedSeed(directive.seed);
    if (sd !== null) {
      params['seed'] = sd;
    }
    const norm = validatedNormalize(directive.normalize);
    if (norm !== null) {
      params['normalize'] = norm;
    }
    const lang = validatedLanguage(directive.language);
    if (lang !== null) {
      params['language'] = lang;
      languageFromDirective = true;
    }
    const of = (directive.outputFormat ?? '').trim();
    if (of.length > 0) {
      params['outputFormat'] = of;
      outputFormatFromDirective = true;
    }
  }

  if (!languageFromDirective) {
    const fb = (fallbackLanguage ?? '').trim();
    if (fb.length > 0) {
      params['language'] = fb;
    }
  }

  if (!outputFormatFromDirective) {
    params['outputFormat'] = 'mp3';
  }

  return params;
}
