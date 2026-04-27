/**
 * Chat controller: sessions, messages, send, streaming.
 */
import type { GatewaySession } from '../gateway/GatewaySession';
import { buildTalkSpeakRpcParams } from '../voice/TalkDirectiveParser';
import type { TalkDirective } from '../voice/TalkDirectiveParser';
import type { ChatMessage, ChatMessageContent, ChatPendingToolCall, ChatSessionEntry } from './ChatModels';

export interface ChatHistoryResult {
  messages: ChatMessage[];
  thinkingLevel?: string;
}

export interface ChatSubscribeParams {
  sessionKey: string;
}

export interface ChatHistoryParams {
  sessionKey: string;
}

export interface ChatSendParams {
  sessionKey: string;
  message: string;
  thinking: string;
  timeoutMs: number;
  idempotencyKey: string;
}

function randomId(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

export type ChatStateListener = (state: ChatState) => void;

export interface OutgoingAttachment {
  type: string;
  mimeType: string;
  fileName: string;
  base64: string;
}

interface ChatSendAttachmentItem {
  type: string;
  mimeType: string;
  fileName: string;
  content: string;
}

interface SessionsListPayload {
  sessions?: Record<string, string | number>[];
}

export interface ChatState {
  sessionKey: string;
  mainSessionKey: string;
  messages: ChatMessage[];
  errorText: string | null;
  healthOk: boolean;
  streamingAssistantText: string | null;
  pendingRunCount: number;
  thinkingLevel: string;
  sessions: ChatSessionEntry[];
  pendingToolCalls: ChatPendingToolCall[];
}

export interface BootstrapOptions {
  skipSessionFetch?: boolean;
  sessionLimit?: number;
}

export interface TalkSpeakResult {
  audioBase64: string;
  mimeType: string | null;
  outputFormat: string | null;
  fileExtension: string | null;
}

/** Gateway talk.speak RPC (directive + persisted voice/model from VoiceCoordinator). */
export interface TalkSpeakRequest {
  text: string;
  language: string;
  directive: TalkDirective | null;
  persistentVoiceId: string | null;
  persistentModelId: string | null;
}

function stringFingerprint(value: string | undefined): string {
  const text = (value ?? '').trim();
  if (text.length === 0) {
    return '';
  }
  let hash = 5381;
  for (let i = 0; i < text.length; i++) {
    hash = ((hash << 5) + hash) + text.charCodeAt(i);
  }
  return String(hash >>> 0);
}

function messageIdentityKey(message: ChatMessage): string | null {
  const role = (message.role ?? '').trim().toLowerCase();
  if (role.length === 0) {
    return null;
  }
  const timestamp = message.timestampMs !== undefined ? String(message.timestampMs) : '';
  let contentFingerprint = '';
  for (let i = 0; i < message.content.length; i++) {
    const part = message.content[i];
    const row = [
      (part.type ?? '').trim().toLowerCase(),
      (part.text ?? '').trim(),
      (part.mimeType ?? '').trim().toLowerCase(),
      (part.fileName ?? '').trim(),
      stringFingerprint(part.base64),
    ].join('\u001F');
    contentFingerprint = contentFingerprint.length > 0 ? `${contentFingerprint}\u001E${row}` : row;
  }
  if (timestamp.length === 0 && contentFingerprint.length === 0) {
    return null;
  }
  return [role, timestamp, contentFingerprint].join('|');
}

function reconcileMessageIds(previous: ChatMessage[], incoming: ChatMessage[]): ChatMessage[] {
  if (previous.length === 0 || incoming.length === 0) {
    return incoming;
  }
  const idsByKey = new Map<string, string[]>();
  for (let i = 0; i < previous.length; i++) {
    const message = previous[i];
    const key = messageIdentityKey(message);
    if (!key) {
      continue;
    }
    const bucket = idsByKey.get(key) ?? [];
    bucket.push(message.id);
    idsByKey.set(key, bucket);
  }
  const reconciled: ChatMessage[] = [];
  for (let i = 0; i < incoming.length; i++) {
    const message = incoming[i];
    const key = messageIdentityKey(message);
    if (!key) {
      reconciled.push(message);
      continue;
    }
    const bucket = idsByKey.get(key);
    if (!bucket || bucket.length === 0) {
      reconciled.push(message);
      continue;
    }
    const reusedId = bucket.shift();
    if (!reusedId || reusedId === message.id) {
      reconciled.push(message);
    } else {
      reconciled.push({
        id: reusedId,
        role: message.role,
        content: message.content,
        timestampMs: message.timestampMs,
      });
    }
    if (bucket.length === 0) {
      idsByKey.delete(key);
    } else {
      idsByKey.set(key, bucket);
    }
  }
  return reconciled;
}

function normalizeThinking(level: string): string {
  const t = (level ?? '').trim().toLowerCase();
  if (t === 'low' || t === 'medium' || t === 'high') return t;
  return 'off';
}

export class ChatController {
  private session: GatewaySession;
  private listeners = new Map<number, ChatStateListener>();
  private nextListenerId = 1;
  private _sessionKey = 'main';
  private _mainSessionKey = 'main';
  private _messages: ChatMessage[] = [];
  private _errorText: string | null = null;
  private _healthOk = false;
  private _streamingAssistantText: string | null = null;
  private _pendingRunCount = 0;
  private _thinkingLevel = 'off';
  private _sessions: ChatSessionEntry[] = [];
  private pendingRuns = new Set<string>();
  private pendingToolCallsById = new Map<string, ChatPendingToolCall>();
  private _pendingToolCalls: ChatPendingToolCall[] = [];

  constructor(session: GatewaySession) {
    this.session = session;
  }

  setListener(listener: ChatStateListener | null): void {
    this.listeners.clear();
    if (!listener) {
      return;
    }
    const id = this.nextListenerId++;
    this.listeners.set(id, listener);
    listener(this.snapshotState());
  }

  addListener(listener: ChatStateListener): number {
    const id = this.nextListenerId++;
    this.listeners.set(id, listener);
    listener(this.snapshotState());
    return id;
  }

  removeListener(listenerId: number): void {
    this.listeners.delete(listenerId);
  }

  setThinkingLevel(level: string): void {
    const trimmed = normalizeThinking(level);
    if (trimmed === this._thinkingLevel) return;
    this._thinkingLevel = trimmed;
    this.notify();
  }

  getThinkingLevel(): string {
    return this._thinkingLevel;
  }

  setSessionKey(key: string): void {
    const k = (key ?? '').trim() || 'main';
    if (k === this._sessionKey) return;
    this._sessionKey = k;
    void this.bootstrap({ skipSessionFetch: true });
  }

  load(sessionKey: string): void {
    const key = (sessionKey ?? '').trim() || 'main';
    this._sessionKey = key;
    void this.bootstrap({ skipSessionFetch: true });
  }

  refreshSessions(): void {
    this.fetchSessions(50);
  }

  private notify(): void {
    if (this.listeners.size === 0) return;
    const state = this.snapshotState();
    this.listeners.forEach((listener) => {
      listener(state);
    });
  }

  private snapshotState(): ChatState {
    const state: ChatState = {
      sessionKey: this._sessionKey,
      mainSessionKey: this._mainSessionKey,
      messages: this._messages,
      errorText: this._errorText,
      healthOk: this._healthOk,
      streamingAssistantText: this._streamingAssistantText,
      pendingRunCount: this._pendingRunCount,
      thinkingLevel: this._thinkingLevel,
      sessions: this._sessions,
      pendingToolCalls: this._pendingToolCalls,
    };
    return state;
  }

  onDisconnected(_message: string): void {
    this._healthOk = false;
    this._errorText = null;
    this.clearPendingRuns();
    this.clearPendingTools();
    this._streamingAssistantText = null;
    this.notify();
  }

  applyMainSessionKey(mainSessionKey: string): void {
    const trimmed = mainSessionKey.trim();
    if (!trimmed) return;
    this._mainSessionKey = trimmed;
    if (this._sessionKey === trimmed) return;
    if (this._sessionKey !== 'main') return;
    this._sessionKey = trimmed;
    void this.bootstrap();
  }

  async bootstrap(options: BootstrapOptions = {}): Promise<void> {
    this._errorText = null;
    this._healthOk = false;
    this.clearPendingRuns();
    this.clearPendingTools();
    this._streamingAssistantText = null;
    const key = this._sessionKey;
    const skipList = options.skipSessionFetch === true;
    const sessionLimit = options.sessionLimit !== undefined ? options.sessionLimit : 50;
    try {
      const subParams: ChatSubscribeParams = { sessionKey: key };
      await this.session.sendNodeEvent('chat.subscribe', JSON.stringify(subParams));
      const histRec: Record<string, string> = { 'sessionKey': key };
      const res = await this.session.request('chat.history', histRec, 15000);
      const history = this.parseHistory(res.payloadJson, key, this._messages);
      this._messages = history.messages;
      const tl = history.thinkingLevel?.trim();
      if (tl && tl.length > 0) this._thinkingLevel = normalizeThinking(tl);
      this.pollHealth();
      if (!skipList && sessionLimit > 0) {
        await this.fetchSessions(sessionLimit);
      } else {
        this.notify();
      }
    } catch (err) {
      this._errorText = err instanceof Error ? err.message : String(err);
      this.notify();
    }
  }

  private async fetchSessions(limit: number): Promise<void> {
    try {
      const params: Record<string, string | number | boolean> = {
        'includeGlobal': true,
        'includeUnknown': false,
        'includeDerivedTitles': true,
        'includeLastMessage': true,
        'limit': limit,
      };
      const res = await this.session.request('sessions.list', params, 10000);
      this._sessions = this.parseSessions(res.payloadJson);
      this.notify();
    } catch (_) {
      // best-effort
    }
  }

  private parseSessions(payloadJson: string | null): ChatSessionEntry[] {
    if (!payloadJson?.trim()) return [];
    try {
      const root = JSON.parse(payloadJson) as SessionsListPayload;
      const arr = root.sessions;
      if (!arr || !Array.isArray(arr)) return [];
      const out: ChatSessionEntry[] = [];
      for (let i = 0; i < arr.length; i++) {
        const item = arr[i] as Record<string, string | number>;
        const key = String(item['key'] ?? '');
        if (!key) continue;
        const updatedRaw = item['updatedAtMs'] ?? item['updatedAt'];
        const updatedAtMs = typeof updatedRaw === 'number' ? updatedRaw : undefined;
        out.push({
          key,
          updatedAtMs: updatedAtMs,
          displayName: typeof item['displayName'] === 'string' ? item['displayName'] : undefined,
          derivedTitle: typeof item['derivedTitle'] === 'string' ? item['derivedTitle'] : undefined,
          lastMessagePreview: typeof item['lastMessagePreview'] === 'string' ? item['lastMessagePreview'] : undefined,
        });
      }
      return out;
    } catch {
      return [];
    }
  }

  abort(): void {
    const runIds = Array.from(this.pendingRuns);
    if (runIds.length === 0) return;
    for (let i = 0; i < runIds.length; i++) {
      const runId = runIds[i];
      const abortRec: Record<string, string> = {
        'sessionKey': this._sessionKey,
        'runId': runId,
      };
      this.session.request('chat.abort', abortRec, 8000).catch(() => {
        // best-effort
      });
    }
  }

  private parseHistory(historyJson: string | null, _sessionKey: string, previousMessages: ChatMessage[]): ChatHistoryResult {
    const empty: ChatHistoryResult = { messages: [] };
    if (!historyJson?.trim()) return empty;
    try {
      const root = JSON.parse(historyJson) as Record<string, object[] | string>;
      const array = root['messages'];
      const thinkingLevel = typeof root['thinkingLevel'] === 'string' ? root['thinkingLevel'] as string : undefined;
      if (!array || !Array.isArray(array)) {
        const result: ChatHistoryResult = { messages: [] };
        if (thinkingLevel) result.thinkingLevel = thinkingLevel;
        return result;
      }
      const messages: ChatMessage[] = [];
      for (let i = 0; i < array.length; i++) {
        const item = array[i] as Record<string, string | number | object[]>;
        const role = String(item['role'] ?? '');
        const contentArr = item['content'];
        const content: ChatMessageContent[] = [];
        if (Array.isArray(contentArr)) {
          for (let j = 0; j < contentArr.length; j++) {
            const c = contentArr[j] as Record<string, string>;
            const cc: ChatMessageContent = {
              type: String(c['type'] ?? 'text'),
              text: c['text'],
              mimeType: c['mimeType'],
              fileName: c['fileName'],
              base64: c['content'],
            };
            content.push(cc);
          }
        }
        const msg: ChatMessage = {
          id: randomId(),
          role,
          content,
          timestampMs: item['timestamp'] as number,
        };
        messages.push(msg);
      }
      return { messages: reconcileMessageIds(previousMessages, messages), thinkingLevel };
    } catch {
      return empty;
    }
  }

  private async pollHealth(): Promise<void> {
    try {
      const res = await this.session.request('health', null, 10000);
      this._healthOk = res.ok;
    } catch {
      this._healthOk = false;
    }
    this.notify();
  }

  /**
   * @returns Canonical run id from gateway (may differ from idempotencyKey). Null if send was skipped or failed.
   */
  async sendMessage(
    message: string,
    thinking?: string,
    attachments?: OutgoingAttachment[] | undefined,
    idempotencyKey?: string | null,
  ): Promise<string | null> {
    const trimmed = (message ?? '').trim();
    const atts = attachments ?? [];
    if (!trimmed && atts.length === 0) {
      return null;
    }
    if (!this._healthOk) {
      this._errorText = 'Gateway health not OK; cannot send';
      this.notify();
      return null;
    }
    const keyTrim = (idempotencyKey ?? '').trim();
    const runId = keyTrim.length > 0 ? keyTrim : randomId();
    const text = trimmed || 'See attached.';
    const thinkingVal = normalizeThinking(thinking ?? this._thinkingLevel);
    const userContent: ChatMessageContent[] = [{ type: 'text', text }];
    for (let i = 0; i < atts.length; i++) {
      const a = atts[i];
      userContent.push({
        type: a.type,
        mimeType: a.mimeType,
        fileName: a.fileName,
        base64: a.base64,
      });
    }
    const userMsg: ChatMessage = {
      id: randomId(),
      role: 'user',
      content: userContent,
      timestampMs: Date.now(),
    };
    this._messages = [...this._messages, userMsg];
    this._errorText = null;
    this._streamingAssistantText = null;
    this.clearPendingTools();
    this.pendingRuns.add(runId);
    this._pendingRunCount = this.pendingRuns.size;
    this.notify();

    try {
      const sendRec: Record<string, string | number | object[]> = {
        'sessionKey': this._sessionKey,
        'message': text,
        'thinking': thinkingVal,
        'timeoutMs': 30000,
        'idempotencyKey': runId,
      };
      if (atts.length > 0) {
        const attachList: ChatSendAttachmentItem[] = [];
        for (let i = 0; i < atts.length; i++) {
          const a = atts[i];
          attachList.push({
            type: a.type,
            mimeType: a.mimeType,
            fileName: a.fileName,
            content: a.base64,
          });
        }
        sendRec['attachments'] = attachList;
      }
      const res = await this.session.request('chat.send', sendRec, 30000);
      if (!res.ok) {
        const errMsg = res.error?.message ?? 'chat.send failed';
        this._errorText = errMsg;
        this.pendingRuns.delete(runId);
        this._pendingRunCount = this.pendingRuns.size;
        this.notify();
        return null;
      }
      const payload = res.payloadJson ? JSON.parse(res.payloadJson) as Record<string, string> : {} as Record<string, string>;
      const actualRunId = String(payload['runId'] ?? runId).trim() || runId;
      if (actualRunId !== runId) {
        this.pendingRuns.delete(runId);
        this.pendingRuns.add(actualRunId);
      }
      this._pendingRunCount = this.pendingRuns.size;
      this.notify();
      return actualRunId;
    } catch (err) {
      this.pendingRuns.delete(runId);
      this._errorText = err instanceof Error ? err.message : String(err);
    }
    this._pendingRunCount = this.pendingRuns.size;
    this.notify();
    return null;
  }

  async requestTalkSpeak(req: TalkSpeakRequest): Promise<TalkSpeakResult | null> {
    const t = (req.text ?? '').trim();
    if (t.length === 0) {
      return null;
    }
    const params = buildTalkSpeakRpcParams(
      t,
      req.language,
      req.directive,
      req.persistentVoiceId,
      req.persistentModelId,
    );
    const res = await this.session.request('talk.speak', params, 30000);
    if (!res.ok || !res.payloadJson) {
      return null;
    }
    const root = JSON.parse(res.payloadJson) as Record<string, string>;
    const audioBase64 = String(root['audioBase64'] ?? '').trim();
    if (audioBase64.length === 0) {
      return null;
    }
    const out: TalkSpeakResult = {
      audioBase64: audioBase64,
      mimeType: root['mimeType'] ? String(root['mimeType']).trim() : null,
      outputFormat: root['outputFormat'] ? String(root['outputFormat']).trim() : null,
      fileExtension: root['fileExtension'] ? String(root['fileExtension']).trim() : null,
    };
    return out;
  }

  async requestTalkConfig(): Promise<string | null> {
    const res = await this.session.request('talk.config', null, 10000);
    if (!res.ok) {
      return null;
    }
    return res.payloadJson;
  }

  handleGatewayEvent(event: string, payloadJson: string | null): void {
    if (event === 'tick') {
      this.pollHealth();
      return;
    }
    if (event === 'health') {
      this._healthOk = true;
      this.notify();
      return;
    }
    if (event === 'seqGap') {
      this._errorText = 'Event stream interrupted; try refreshing.';
      this.clearPendingRuns();
      this.clearPendingTools();
      this._streamingAssistantText = null;
      this.notify();
      return;
    }
    if (event === 'chat' && payloadJson) {
      this.handleChatEvent(payloadJson);
      return;
    }
    if (event === 'agent' && payloadJson) {
      this.handleAgentEvent(payloadJson);
      return;
    }
  }

  private handleChatEvent(payloadJson: string): void {
    try {
      const payload = JSON.parse(payloadJson) as Record<string, string | object>;
      const sessionKey = (payload['sessionKey'] as string)?.trim();
      if (sessionKey && sessionKey !== this._sessionKey) return;
      const state = payload['state'] as string;
      const runIdRaw = payload['runId'];
      const runId = runIdRaw !== undefined && runIdRaw !== null ? String(runIdRaw).trim() : '';
      if (state === 'delta') {
        const isPending = runId.length === 0 ? true : this.pendingRuns.has(runId);
        if (!isPending) return;
        const text = this.parseAssistantDeltaText(payload);
        if (text) {
          this._streamingAssistantText = text;
          this.notify();
        }
        return;
      }
      if (state === 'final' || state === 'aborted' || state === 'error') {
        if (state === 'error') {
          this._errorText = (payload['errorMessage'] as string) ?? 'Chat failed';
        }
        this.clearPendingTools();
        if (runId.length > 0) {
          this.pendingRuns.delete(runId);
          this._pendingRunCount = this.pendingRuns.size;
        } else {
          this.clearPendingRuns();
        }
        this._streamingAssistantText = null;
        this.reloadHistory();
      }
    } catch (_) {
      // ignore
    }
  }

  private parseAssistantDeltaText(payload: Record<string, string | object>): string | null {
    const message = payload['message'] as Record<string, string | object>;
    if (!message || (message['role'] as string) !== 'assistant') return null;
    const content = message['content'] as Record<string, string>[];
    if (!content) return null;
    for (let i = 0; i < content.length; i++) {
      const obj = content[i];
      if ((obj['type'] as string) !== 'text') continue;
      const text = obj['text'] as string;
      if (text) return text;
    }
    return null;
  }

  private handleAgentEvent(payloadJson: string): void {
    try {
      const payload = JSON.parse(payloadJson) as Record<string, string | object | number | null>;
      const sessionKey = (payload['sessionKey'] as string)?.trim();
      if (sessionKey && sessionKey !== this._sessionKey) return;
      const stream = String(payload['stream'] ?? '').trim();
      const data = payload['data'] as Record<string, object | string | number | null> | undefined;
      if (stream === 'assistant' && data) {
        const text = data['text'];
        const textStr = typeof text === 'string' ? text : text !== undefined ? String(text) : '';
        if (textStr.length > 0) {
          this._streamingAssistantText = textStr;
          this.notify();
        }
        return;
      }
      if (stream === 'tool' && data) {
        const phase = String(data['phase'] ?? '').trim();
        const name = String(data['name'] ?? '').trim();
        const toolCallId = String(data['toolCallId'] ?? '').trim();
        if (phase.length === 0 || name.length === 0 || toolCallId.length === 0) return;
        const tsRaw = payload['ts'];
        const ts = typeof tsRaw === 'number' && Number.isFinite(tsRaw) ? tsRaw : Date.now();
        if (phase === 'start') {
          const argsRaw = data['args'];
          let args: Record<string, object | string | number | boolean | null> | null = null;
          if (argsRaw !== null && argsRaw !== undefined && typeof argsRaw === 'object' && !Array.isArray(argsRaw)) {
            args = argsRaw as Record<string, object | string | number | boolean | null>;
          }
          const row: ChatPendingToolCall = {
            toolCallId: toolCallId,
            name: name,
            args: args,
            startedAtMs: ts,
            isError: null,
          };
          this.pendingToolCallsById.set(toolCallId, row);
          this.publishPendingToolCalls();
          this.notify();
        } else if (phase === 'result') {
          this.pendingToolCallsById.delete(toolCallId);
          this.publishPendingToolCalls();
          this.notify();
        }
        return;
      }
      if (stream === 'error') {
        this._errorText = 'Event stream interrupted; try refreshing.';
        this.clearPendingRuns();
        this.clearPendingTools();
        this._streamingAssistantText = null;
        this.notify();
      }
    } catch (_) {
      // ignore
    }
  }

  private reloadHistory(): void {
    const key = this._sessionKey;
    const histRec: Record<string, string> = { 'sessionKey': key };
    void this.session
      .request('chat.history', histRec, 15000)
      .then((res) => {
        if (!res.ok || !res.payloadJson) return;
        const history = this.parseHistory(res.payloadJson, key, this._messages);
        this._messages = history.messages;
        const tl = history.thinkingLevel?.trim();
        if (tl && tl.length > 0) {
          this._thinkingLevel = normalizeThinking(tl);
        }
        this.notify();
      })
      .catch(() => {});
  }

  private clearPendingTools(): void {
    this.pendingToolCallsById.clear();
    this._pendingToolCalls = [];
  }

  private publishPendingToolCalls(): void {
    const arr: ChatPendingToolCall[] = [];
    this.pendingToolCallsById.forEach((v) => arr.push(v));
    arr.sort((a, b) => a.startedAtMs - b.startedAtMs);
    this._pendingToolCalls = arr;
  }

  private clearPendingRuns(): void {
    this.pendingRuns.clear();
    this._pendingRunCount = 0;
  }
}
