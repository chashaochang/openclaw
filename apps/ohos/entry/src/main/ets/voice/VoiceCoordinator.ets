/**
 * Voice tab: STT, send via chat.send, assistant bubbles + TTS (Android MicCaptureManager parity).
 */
import { i18n } from '@kit.LocalizationKit';
import { ChatController } from '../chat/ChatController';
import type { TalkSpeakResult } from '../chat/ChatController';
import type { SecurePrefs } from '../common/SecurePrefs';
import { HarmonySpeechRecognizer } from './HarmonySpeechRecognizer';
import { HarmonyTtsPlayer } from './HarmonyTtsPlayer';
import { parseTalkDirective } from './TalkDirectiveParser';
import { VoiceConversationEntry, VoiceConversationRole, VoiceUiState } from './VoiceModels';

type JsonRec = Record<string, object | string | number | boolean | null>;

const MAX_CONVERSATION = 40;
const DRAIN_MS = 2000;
const PENDING_RUN_TIMEOUT_MS = 45000;

function randomId(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

function parseAssistantChatText(payload: JsonRec): string | null {
  const msgRaw = payload['message'];
  if (msgRaw === null || typeof msgRaw !== 'object') {
    return null;
  }
  const msg = msgRaw as JsonRec;
  if (String(msg['role'] ?? '') !== 'assistant') {
    return null;
  }
  const contentRaw = msg['content'];
  if (!Array.isArray(contentRaw)) {
    return null;
  }
  const contentArr = contentRaw as object[];
  const parts: string[] = [];
  for (let i = 0; i < contentArr.length; i++) {
    const item = contentArr[i];
    if (item === null || typeof item !== 'object') {
      continue;
    }
    const o = item as JsonRec;
    if (String(o['type'] ?? '') !== 'text') {
      continue;
    }
    const t = String(o['text'] ?? '').trim();
    if (t.length > 0) {
      parts.push(t);
    }
  }
  if (parts.length === 0) {
    return null;
  }
  return parts.join('\n');
}

export type VoiceStateListener = (state: VoiceUiState) => void;

export class VoiceCoordinator {
  private prefs: SecurePrefs;
  private getChat: () => ChatController | null;
  private getGatewayConnected: () => boolean;
  private asr: HarmonySpeechRecognizer = new HarmonySpeechRecognizer();
  private tts: HarmonyTtsPlayer = new HarmonyTtsPlayer();
  private uiListener: VoiceStateListener | null = null;

  private micEnabled = false;
  private micCooldown = false;
  private speakerEnabled = true;
  private liveTranscript = '';
  private statusDetail = 'Mic off';
  private messageQueue: string[] = [];
  private sessionSegments: string[] = [];
  private lastFinalSegment: string | null = null;
  private conversation: VoiceConversationEntry[] = [];
  private isSending = false;
  private pendingRunId: string | null = null;
  private pendingAssistantEntryId: string | null = null;
  private voiceScreenActive = false;
  private drainTimer: number = -1;
  private pendingRunTimer: number = -1;
  private playbackToken = 0;
  /** Persisted across assistant turns when directives set voice/model without once: true (Android TalkMode parity). */
  private currentVoiceId: string | null = null;
  private currentModelId: string | null = null;

  constructor(
    prefs: SecurePrefs,
    getChat: () => ChatController | null,
    getGatewayConnected: () => boolean,
  ) {
    this.prefs = prefs;
    this.getChat = getChat;
    this.getGatewayConnected = getGatewayConnected;
    void this.prefs.getBooleanOr('voice.speakerEnabled', true).then((v) => {
      this.speakerEnabled = v;
      this.notifyUi();
    });
    this.applyRecognizerLanguage();
  }

  private applyRecognizerLanguage(): void {
    try {
      const preferred = i18n.System.getSystemLocale();
      const lower = (preferred ?? '').toLowerCase();
      if (lower.startsWith('zh')) {
        this.asr.setLanguageCode('zh-CN');
      } else if (lower.startsWith('en')) {
        this.asr.setLanguageCode('en-US');
      } else {
        this.asr.setLanguageCode('zh-CN');
      }
    } catch {
      this.asr.setLanguageCode('zh-CN');
    }
  }

  private ttsLanguage(): string {
    try {
      const preferred = i18n.System.getSystemLocale();
      const lower = (preferred ?? '').toLowerCase();
      if (lower.startsWith('en')) {
        return 'en-US';
      }
    } catch {
      // fall through
    }
    return 'zh-CN';
  }

  setUiListener(listener: VoiceStateListener | null): void {
    this.uiListener = listener;
    if (listener) {
      listener(this.snapshotUi());
    }
  }

  async setSpeakerEnabled(enabled: boolean): Promise<void> {
    this.speakerEnabled = enabled;
    await this.prefs.putBoolean('voice.speakerEnabled', enabled);
    if (!enabled) {
      this.playbackToken += 1;
      await this.tts.stop();
    }
    this.notifyUi();
  }

  getSpeakerEnabled(): boolean {
    return this.speakerEnabled;
  }

  /** When false (user left Voice tab), stop TTS so replies do not play in background. */
  setVoiceScreenActive(active: boolean): void {
    this.voiceScreenActive = active;
    if (!active) {
      this.playbackToken += 1;
      void this.tts.stop();
    }
  }

  onGatewayConnectionChanged(_connected: boolean): void {
    this.sendQueuedIfIdle();
    this.refreshStatusDetail();
    this.notifyUi();
  }

  handleGatewayEvent(event: string, payloadJson: string | null): void {
    if (event !== 'chat' || !payloadJson || payloadJson.trim().length === 0) {
      return;
    }
    let payload: JsonRec;
    try {
      payload = JSON.parse(payloadJson) as JsonRec;
    } catch {
      return;
    }
    const runId = String(payload['runId'] ?? '').trim();
    const pending = this.pendingRunId;
    if (!pending || runId.length === 0 || runId !== pending) {
      return;
    }
    const state = String(payload['state'] ?? '');
    if (state === 'delta') {
      const deltaText = parseAssistantChatText(payload);
      if (deltaText && deltaText.trim().length > 0) {
        this.upsertPendingAssistant(deltaText.trim(), true);
      }
      return;
    }
    if (state === 'final') {
      const finalText = parseAssistantChatText(payload)?.trim() ?? '';
      if (finalText.length > 0) {
        this.upsertPendingAssistant(finalText, false);
        void this.playAssistantReply(finalText);
      } else if (this.pendingAssistantEntryId !== null) {
        this.updateConversationEntry(this.pendingAssistantEntryId, null, false);
      }
      this.completePendingTurn();
      return;
    }
    if (state === 'error') {
      const err = String(payload['errorMessage'] ?? 'Voice request failed').trim() || 'Voice request failed';
      this.upsertPendingAssistant(err, false);
      this.completePendingTurn();
      return;
    }
    if (state === 'aborted') {
      this.upsertPendingAssistant('Response aborted', false);
      this.completePendingTurn();
    }
  }

  private async playAssistantReply(text: string): Promise<void> {
    if (!this.voiceScreenActive || !this.speakerEnabled) {
      return;
    }
    const spoken = text.trim();
    if (spoken.length === 0) {
      return;
    }
    const parsed = parseTalkDirective(spoken);
    const directive = parsed.directive;
    const cleaned = parsed.stripped.trim();
    if (cleaned.length === 0) {
      return;
    }

    if (directive !== null) {
      if (directive.voiceId !== null) {
        const requested = directive.voiceId.trim();
        const requestedVoice = requested.length > 0 ? requested : null;
        if (directive.once !== true) {
          this.currentVoiceId = requestedVoice;
        }
      }
      if (directive.modelId !== null) {
        const requested = directive.modelId.trim();
        const requestedModel = requested.length > 0 ? requested : null;
        if (directive.once !== true) {
          this.currentModelId = requestedModel;
        }
      }
    }

    this.playbackToken += 1;
    const token = this.playbackToken;
    await this.tts.stop();
    if (token !== this.playbackToken || !this.voiceScreenActive || !this.speakerEnabled) {
      return;
    }
    let spoke = false;
    const chat = this.getChat();
    if (chat) {
      try {
        const gatewaySpeech: TalkSpeakResult | null = await chat.requestTalkSpeak({
          text: cleaned,
          language: this.ttsLanguage(),
          directive: directive,
          persistentVoiceId: this.currentVoiceId,
          persistentModelId: this.currentModelId,
        });
        if (token !== this.playbackToken || !this.voiceScreenActive || !this.speakerEnabled) {
          return;
        }
        if (gatewaySpeech && gatewaySpeech.audioBase64.trim().length > 0) {
          spoke = await this.tts.speakGatewayAudioBase64(
            gatewaySpeech.audioBase64,
            gatewaySpeech.mimeType,
            gatewaySpeech.fileExtension,
            gatewaySpeech.outputFormat,
          );
        }
      } catch {
        // fall back to local TTS
      }
    }
    if (token !== this.playbackToken || !this.voiceScreenActive || !this.speakerEnabled) {
      return;
    }
    if (spoke) {
      return;
    }
    try {
      await this.tts.speak(cleaned, this.ttsLanguage());
    } catch {
      // ignore TTS failures
    }
  }

  async setMicEnabled(enabled: boolean): Promise<void> {
    if (enabled === this.micEnabled) {
      return;
    }
    this.micEnabled = enabled;
    if (enabled) {
      this.micCooldown = false;
      this.refreshStatusDetail();
      this.notifyUi();
      // Release playback before opening the mic — STT + TTS sharing audio trips some devices.
      this.playbackToken += 1;
      await this.tts.stop();
      const started = await this.asr.start(
        (text, isFinal) => {
          this.onRecognizerText(text, isFinal);
        },
        (err) => {
          this.statusDetail = err.length > 30 ? err.substring(0, 30) + '…' : err;
          this.notifyUi();
        },
      );
      if (!started) {
        this.micEnabled = false;
        this.refreshStatusDetail();
        this.notifyUi();
        return;
      }
      this.sendQueuedIfIdle();
    } else {
      this.micCooldown = true;
      if (this.drainTimer >= 0) {
        clearTimeout(this.drainTimer);
        this.drainTimer = -1;
      }
      await this.asr.stop();
      this.drainTimer = setTimeout(() => {
        this.drainTimer = -1;
        const partial = this.liveTranscript.trim();
        if (partial.length > 0 && this.sessionSegments.length === 0) {
          this.sessionSegments.push(partial);
        }
        this.liveTranscript = '';
        this.flushSessionToQueue();
        this.micCooldown = false;
        this.refreshStatusDetail();
        this.notifyUi();
        this.sendQueuedIfIdle();
      }, DRAIN_MS) as number;
    }
    this.refreshStatusDetail();
    this.notifyUi();
  }

  getMicEnabled(): boolean {
    return this.micEnabled;
  }

  getMicCooldown(): boolean {
    return this.micCooldown;
  }

  private onRecognizerText(text: string, isFinal: boolean): void {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      return;
    }
    if (!isFinal) {
      this.liveTranscript = trimmed;
      this.refreshStatusDetail();
      this.notifyUi();
      return;
    }
    this.liveTranscript = trimmed;
    if (this.lastFinalSegment === trimmed) {
      this.refreshStatusDetail();
      this.notifyUi();
      return;
    }
    this.lastFinalSegment = trimmed;
    this.sessionSegments.push(trimmed);
    this.liveTranscript = '';
    this.refreshStatusDetail();
    this.notifyUi();
  }

  private flushSessionToQueue(): void {
    const parts: string[] = [];
    for (let i = 0; i < this.sessionSegments.length; i++) {
      const trimmed = this.sessionSegments[i].trimEnd();
      if (trimmed.length > 0) {
        parts.push(trimmed);
      }
    }
    let message = parts.join('. ').trim();
    if (message.length > 0) {
      const lastCh = message.charAt(message.length - 1);
      if ('.!?'.indexOf(lastCh) < 0) {
        message = `${message}.`;
      }
    }
    this.sessionSegments = [];
    this.lastFinalSegment = null;
    this.liveTranscript = '';
    if (message.length === 0) {
      return;
    }
    this.appendConversation(VoiceConversationRole.User, message, false);
    this.messageQueue.push(message);
    this.notifyUi();
    this.sendQueuedIfIdle();
  }

  private sendQueuedIfIdle(): void {
    if (this.isSending) {
      return;
    }
    if (this.messageQueue.length === 0) {
      this.refreshStatusDetail();
      this.notifyUi();
      return;
    }
    if (!this.getGatewayConnected()) {
      this.refreshStatusDetail();
      this.notifyUi();
      return;
    }
    const chat = this.getChat();
    if (!chat) {
      return;
    }
    const next = this.messageQueue[0];
    const runKey = randomId();
    this.isSending = true;
    this.pendingRunId = runKey;
    this.armPendingRunTimeout(runKey);
    this.refreshStatusDetail();
    this.notifyUi();
    const thinking = chat.getThinkingLevel();
    void chat.sendMessage(next, thinking, undefined, runKey).then((canonicalRunId: string | null) => {
      if (!canonicalRunId || canonicalRunId.trim().length === 0) {
        this.clearPendingRunTimer();
        if (this.messageQueue.length > 0 && this.messageQueue[0] === next) {
          this.messageQueue.shift();
        }
        this.isSending = false;
        this.pendingRunId = null;
        this.pendingAssistantEntryId = null;
        this.refreshStatusDetail();
        this.notifyUi();
        this.sendQueuedIfIdle();
        return;
      }
      // Gateway chat.* events use runId from chat.send response, not always the idempotency key.
      if (canonicalRunId !== runKey) {
        this.pendingRunId = canonicalRunId;
        this.armPendingRunTimeout(canonicalRunId);
      }
    });
  }

  private armPendingRunTimeout(runId: string): void {
    this.clearPendingRunTimer();
    this.pendingRunTimer = setTimeout(() => {
      this.pendingRunTimer = -1;
      if (this.pendingRunId !== runId) {
        return;
      }
      this.pendingRunId = null;
      this.pendingAssistantEntryId = null;
      this.isSending = false;
      this.refreshStatusDetail();
      this.notifyUi();
      this.sendQueuedIfIdle();
    }, PENDING_RUN_TIMEOUT_MS) as number;
  }

  private clearPendingRunTimer(): void {
    if (this.pendingRunTimer >= 0) {
      clearTimeout(this.pendingRunTimer);
      this.pendingRunTimer = -1;
    }
  }

  private completePendingTurn(): void {
    this.clearPendingRunTimer();
    if (this.messageQueue.length > 0) {
      this.messageQueue.shift();
    }
    this.pendingRunId = null;
    this.pendingAssistantEntryId = null;
    this.isSending = false;
    this.sendQueuedIfIdle();
    this.refreshStatusDetail();
    this.notifyUi();
  }

  private queuedWaitingLabel(): string {
    const n = this.messageQueue.length;
    return `${n} queued · waiting for gateway`;
  }

  private refreshStatusDetail(): void {
    if (this.micCooldown) {
      this.statusDetail = 'Cooldown';
      return;
    }
    if (!this.getGatewayConnected() && this.messageQueue.length > 0) {
      this.statusDetail = this.queuedWaitingLabel();
      return;
    }
    if (this.isSending && this.micEnabled) {
      this.statusDetail = 'Listening · sending';
      return;
    }
    if (this.isSending) {
      this.statusDetail = 'Sending';
      return;
    }
    if (this.micEnabled) {
      if (this.messageQueue.length > 0) {
        this.statusDetail = `Listening · ${this.messageQueue.length} queued`;
      } else {
        this.statusDetail = 'Listening';
      }
      return;
    }
    this.statusDetail = 'Mic off';
  }

  private activityLabel(): string {
    if (this.messageQueue.length > 0) {
      return `${this.messageQueue.length} queued`;
    }
    if (this.isSending) {
      return 'Sending';
    }
    if (this.micCooldown) {
      return 'Cooldown';
    }
    if (this.micEnabled) {
      return 'Listening';
    }
    return 'Mic off';
  }

  private notifyUi(): void {
    this.uiListener?.(this.snapshotUi());
  }

  private snapshotUi(): VoiceUiState {
    const q = this.messageQueue.slice();
    const c = this.conversation.slice();
    const s: VoiceUiState = {
      micEnabled: this.micEnabled,
      micCooldown: this.micCooldown,
      speakerEnabled: this.speakerEnabled,
      liveTranscript: this.liveTranscript,
      queuedMessages: q,
      conversation: c,
      isSending: this.isSending,
      activityLabel: this.activityLabel(),
    };
    return s;
  }

  private appendConversation(role: VoiceConversationRole, text: string, isStreaming: boolean): string {
    const id = randomId();
    const entry: VoiceConversationEntry = { id, role, text, isStreaming };
    const next = this.conversation.concat([entry]);
    const trimmed = next.length > MAX_CONVERSATION ? next.slice(next.length - MAX_CONVERSATION) : next;
    this.conversation = trimmed;
    return id;
  }

  private updateConversationEntry(id: string, text: string | null, isStreaming: boolean): void {
    const current = this.conversation;
    if (current.length === 0) {
      return;
    }
    let targetIndex = -1;
    for (let i = current.length - 1; i >= 0; i--) {
      if (current[i].id === id) {
        targetIndex = i;
        break;
      }
    }
    if (targetIndex < 0) {
      return;
    }
    const entry = current[targetIndex];
    const updatedText = text !== null ? text : entry.text;
    if (updatedText === entry.text && entry.isStreaming === isStreaming) {
      return;
    }
    const copy = current.slice();
    const updated: VoiceConversationEntry = {
      id: entry.id,
      role: entry.role,
      text: updatedText,
      isStreaming: isStreaming,
    };
    copy[targetIndex] = updated;
    this.conversation = copy;
  }

  private upsertPendingAssistant(text: string, isStreaming: boolean): void {
    const currentId = this.pendingAssistantEntryId;
    if (currentId === null) {
      this.pendingAssistantEntryId = this.appendConversation(VoiceConversationRole.Assistant, text, isStreaming);
      this.notifyUi();
      return;
    }
    this.updateConversationEntry(currentId, text, isStreaming);
    this.notifyUi();
  }

  /** Stops capture/playback when the gateway session tears down (chat may still exist briefly). */
  async prepareDisconnect(): Promise<void> {
    this.setVoiceScreenActive(false);
    this.playbackToken += 1;
    this.micEnabled = false;
    this.micCooldown = false;
    if (this.drainTimer >= 0) {
      clearTimeout(this.drainTimer);
      this.drainTimer = -1;
    }
    this.clearPendingRunTimer();
    await this.asr.stop();
    await this.tts.stop();
    this.refreshStatusDetail();
    this.notifyUi();
  }
}
