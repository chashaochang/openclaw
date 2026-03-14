/**
 * Chat controller: sessions, messages, send, streaming.
 */
import type { GatewaySession } from '../gateway/GatewaySession';
import type { ChatMessage, ChatMessageContent, ChatSessionEntry } from './ChatModels';

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
  messages: ChatMessage[];
  errorText: string | null;
  healthOk: boolean;
  streamingAssistantText: string | null;
  pendingRunCount: number;
  thinkingLevel: string;
  sessions: ChatSessionEntry[];
}


function normalizeThinking(level: string): string {
  const t = (level ?? '').trim().toLowerCase();
  if (t === 'low' || t === 'medium' || t === 'high') return t;
  return 'off';
}

export class ChatController {
  private session: GatewaySession;
  private listener: ChatStateListener | null = null;
  private _sessionKey = 'main';
  private _messages: ChatMessage[] = [];
  private _errorText: string | null = null;
  private _healthOk = false;
  private _streamingAssistantText: string | null = null;
  private _pendingRunCount = 0;
  private _thinkingLevel = 'off';
  private _sessions: ChatSessionEntry[] = [];
  private pendingRuns = new Set<string>();

  constructor(session: GatewaySession) {
    this.session = session;
  }

  setListener(listener: ChatStateListener | null): void {
    this.listener = listener;
    if (listener) {
      this.notify();
    }
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
    this.bootstrap();
  }

  load(sessionKey: string): void {
    const key = (sessionKey ?? '').trim() || 'main';
    this._sessionKey = key;
    this.bootstrap();
  }

  refreshSessions(): void {
    this.fetchSessions(50);
  }

  private notify(): void {
    if (!this.listener) return;
    const state: ChatState = {
      sessionKey: this._sessionKey,
      messages: this._messages,
      errorText: this._errorText,
      healthOk: this._healthOk,
      streamingAssistantText: this._streamingAssistantText,
      pendingRunCount: this._pendingRunCount,
      thinkingLevel: this._thinkingLevel,
      sessions: this._sessions,
    };
    this.listener(state);
  }

  onDisconnected(_message: string): void {
    this._healthOk = false;
    this._errorText = null;
    this.clearPendingRuns();
    this._streamingAssistantText = null;
    this.notify();
  }

  applyMainSessionKey(mainSessionKey: string): void {
    const trimmed = mainSessionKey.trim();
    if (!trimmed || this._sessionKey === trimmed) return;
    if (this._sessionKey !== 'main') return;
    this._sessionKey = trimmed;
    this.bootstrap();
  }

  async bootstrap(): Promise<void> {
    this._errorText = null;
    this._healthOk = false;
    this.clearPendingRuns();
    this._streamingAssistantText = null;
    const key = this._sessionKey;
    try {
      const subParams: ChatSubscribeParams = { sessionKey: key };
      await this.session.sendNodeEvent('chat.subscribe', JSON.stringify(subParams));
      const histRec: Record<string, string> = { 'sessionKey': key };
      const res = await this.session.request('chat.history', histRec, 15000);
      const history = this.parseHistory(res.payloadJson, key);
      this._messages = history.messages;
      const tl = history.thinkingLevel?.trim();
      if (tl && tl.length > 0) this._thinkingLevel = normalizeThinking(tl);
      this.pollHealth();
      this.fetchSessions(50);
      this.notify();
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
        out.push({
          key,
          updatedAtMs: typeof item['updatedAtMs'] === 'number' ? item['updatedAtMs'] : undefined,
          displayName: typeof item['displayName'] === 'string' ? item['displayName'] : undefined,
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

  private parseHistory(historyJson: string | null, _sessionKey: string): ChatHistoryResult {
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
      return { messages, thinkingLevel };
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

  async sendMessage(
    message: string,
    thinking?: string,
    attachments?: OutgoingAttachment[],
  ): Promise<void> {
    const trimmed = (message ?? '').trim();
    const atts = attachments ?? [];
    if (!trimmed && atts.length === 0) return;
    if (!this._healthOk) {
      this._errorText = 'Gateway health not OK; cannot send';
      this.notify();
      return;
    }
    const runId = randomId();
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
      const payload = res.payloadJson ? JSON.parse(res.payloadJson) as Record<string, string> : {} as Record<string, string>;
      const actualRunId = payload['runId'] ?? runId;
      if (actualRunId !== runId) {
        this.pendingRuns.delete(runId);
        this.pendingRuns.add(actualRunId);
      }
    } catch (err) {
      this.pendingRuns.delete(runId);
      this._errorText = err instanceof Error ? err.message : String(err);
    }
    this._pendingRunCount = this.pendingRuns.size;
    this.notify();
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
      const runId = payload['runId'] as string;
      if (state === 'delta') {
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
        if (runId && runId.length > 0) this.pendingRuns.delete(runId);
        else this.clearPendingRuns();
        this._streamingAssistantText = null;
        this.bootstrap();
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
      const payload = JSON.parse(payloadJson) as Record<string, string | Record<string, string>>;
      const sessionKey = (payload['sessionKey'] as string)?.trim();
      if (sessionKey && sessionKey !== this._sessionKey) return;
      const stream = payload['stream'] as string;
      const data = payload['data'] as Record<string, string>;
      if (stream === 'assistant' && data) {
        const text = data['text'] as string;
        if (text) {
          this._streamingAssistantText = text;
          this.notify();
        }
      }
    } catch (_) {
      // ignore
    }
  }

  private clearPendingRuns(): void {
    this.pendingRuns.clear();
    this._pendingRunCount = 0;
  }
}
