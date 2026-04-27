/**
 * Voice flow shared by chat detail voice controls and wake-word dispatch.
 */
import { i18n } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatController } from '../chat/ChatController';
import type { TalkSpeakResult } from '../chat/ChatController';
import type { SecurePrefs } from '../common/SecurePrefs';
import { HarmonySpeechRecognizer } from './HarmonySpeechRecognizer';
import { HarmonyTtsPlayer } from './HarmonyTtsPlayer';
import { parseTalkDirective } from './TalkDirectiveParser';
import { VoiceConversationEntry, VoiceConversationRole, VoiceUiState } from './VoiceModels';

type JsonRec = Record<string, object | string | number | boolean | null>;

interface TalkConfigState {
  silenceTimeoutMs: number;
  interruptOnSpeech: boolean;
}

const MAX_CONVERSATION = 40;
const DRAIN_MS = 1400;
const DEFAULT_SILENCE_TIMEOUT_MS = 700;
const PENDING_RUN_TIMEOUT_MS = 45000;
const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'VoiceFlow';

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

function resolveTalkConfigState(payloadJson: string | null): TalkConfigState {
  if (!payloadJson || payloadJson.trim().length === 0) {
    return {
      silenceTimeoutMs: DEFAULT_SILENCE_TIMEOUT_MS,
      interruptOnSpeech: false,
    };
  }
  try {
    const root = JSON.parse(payloadJson) as JsonRec;
    const configRaw = root['config'];
    const config = configRaw !== null && typeof configRaw === 'object' ? configRaw as JsonRec : root;
    const talkRaw = config['talk'];
    if (talkRaw === null || typeof talkRaw !== 'object') {
      return {
        silenceTimeoutMs: DEFAULT_SILENCE_TIMEOUT_MS,
        interruptOnSpeech: false,
      };
    }
    const talk = talkRaw as JsonRec;
    const timeoutRaw = talk['silenceTimeoutMs'];
    let silenceTimeoutMs = DEFAULT_SILENCE_TIMEOUT_MS;
    if (typeof timeoutRaw === 'number' && Number.isFinite(timeoutRaw) && timeoutRaw > 0 &&
      Math.floor(timeoutRaw) === timeoutRaw) {
      silenceTimeoutMs = timeoutRaw;
    }
    const interruptRaw = talk['interruptOnSpeech'];
    return {
      silenceTimeoutMs: silenceTimeoutMs,
      interruptOnSpeech: interruptRaw === true,
    };
  } catch {
    return {
      silenceTimeoutMs: DEFAULT_SILENCE_TIMEOUT_MS,
      interruptOnSpeech: false,
    };
  }
}

function safeElapsedSeconds(startedAtMs: number): number | null {
  if (!Number.isFinite(startedAtMs) || startedAtMs <= 0) {
    return null;
  }
  const elapsedMs = Date.now() - startedAtMs;
  if (!Number.isFinite(elapsedMs) || elapsedMs < 0) {
    return null;
  }
  const rounded = Math.round(elapsedMs / 100) / 10;
  if (!Number.isFinite(rounded) || rounded < 0) {
    return null;
  }
  return rounded;
}

function buildInterruptedPlaybackNote(seconds: number | null): string | null {
  if (seconds === null) {
    return null;
  }
  return `Assistant speech interrupted at ${seconds.toFixed(1)}s.`;
}

function buildTalkModePrompt(transcript: string, interruptedNote: string | null = null): string {
  const trimmed = transcript.trim();
  if (trimmed.length === 0) {
    return '';
  }
  const lines: string[] = [
    'Talk Mode active. Reply in a concise, spoken tone.',
    'You may optionally prefix the response with JSON (first line) to set ElevenLabs voice (id or alias), e.g. {"voice":"<id>","once":true}.',
  ];
  if (interruptedNote !== null && interruptedNote.trim().length > 0) {
    lines.push(interruptedNote.trim());
  }
  lines.push('');
  lines.push(trimmed);
  return lines.join('\n');
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
  private isSpeaking = false;
  private speakerEnabled = true;
  private talkModeEnabled = false;
  private interruptOnSpeech = false;
  private liveTranscript = '';
  private statusDetail = 'Mic off';
  private messageQueue: string[] = [];
  private queuedConversationEntryIds: string[] = [];
  private queuedSpeakReplies: boolean[] = [];
  private activeUserEntryId: string | null = null;
  private sessionSegments: string[] = [];
  private lastFinalSegment: string | null = null;
  private conversation: VoiceConversationEntry[] = [];
  private isSending = false;
  private pendingRunId: string | null = null;
  private pendingAssistantEntryId: string | null = null;
  private voiceScreenActive = false;
  private drainTimer: number = -1;
  private silenceTimer: number = -1;
  private pendingRunTimer: number = -1;
  private resumeListeningTimer: number = -1;
  private playbackToken = 0;
  private activeSpeakReply = false;
  private replyPlaybackActive = false;
  private replyPlaybackStartedAtMs = 0;
  private pendingInterruptedPlaybackNote: string | null = null;
  private silenceTimeoutMs = DEFAULT_SILENCE_TIMEOUT_MS;
  /** Persisted across assistant turns when directives set voice/model without once: true (Android TalkMode parity). */
  private currentVoiceId: string | null = null;
  private currentModelId: string | null = null;
  private activityListener: (() => void) | null = null;

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

  setActivityListener(listener: (() => void) | null): void {
    this.activityListener = listener;
  }

  async setSpeakerEnabled(enabled: boolean): Promise<void> {
    this.speakerEnabled = enabled;
    await this.prefs.putBoolean('voice.speakerEnabled', enabled);
    if (!enabled) {
      this.playbackToken += 1;
      this.isSpeaking = false;
      this.replyPlaybackActive = false;
      this.replyPlaybackStartedAtMs = 0;
      await this.tts.stop();
    }
    this.refreshStatusDetail();
    this.notifyUi();
  }

  getSpeakerEnabled(): boolean {
    return this.speakerEnabled;
  }

  private clearResumeListeningTimer(): void {
    if (this.resumeListeningTimer >= 0) {
      clearTimeout(this.resumeListeningTimer);
      this.resumeListeningTimer = -1;
    }
  }

  private scheduleResumeListening(delayMs: number = 280): void {
    this.clearResumeListeningTimer();
    if (!this.talkModeEnabled || !this.voiceScreenActive || !this.getGatewayConnected()) {
      this.refreshStatusDetail();
      this.notifyUi();
      return;
    }
    if (this.micEnabled || this.micCooldown || this.isSending || this.replyPlaybackActive) {
      return;
    }
    this.refreshStatusDetail();
    this.notifyUi();
    this.resumeListeningTimer = setTimeout(() => {
      this.resumeListeningTimer = -1;
      if (!this.talkModeEnabled || !this.voiceScreenActive || !this.getGatewayConnected()) {
        this.refreshStatusDetail();
        this.notifyUi();
        return;
      }
      if (this.micEnabled || this.micCooldown || this.isSending || this.replyPlaybackActive) {
        return;
      }
      void this.setMicEnabled(true);
    }, delayMs) as number;
  }

  private markInterruptedPlayback(): void {
    const elapsed = safeElapsedSeconds(this.replyPlaybackStartedAtMs);
    const note = buildInterruptedPlaybackNote(elapsed);
    this.pendingInterruptedPlaybackNote = note;
  }

  async cancelPendingTurn(): Promise<void> {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'cancelPendingTurn requested');
    const chat = this.getChat();
    const shouldAbortRun = this.pendingRunId !== null || this.isSending;
    const shouldStopRecognizer = this.micEnabled || this.micCooldown;

    if (this.drainTimer >= 0) {
      clearTimeout(this.drainTimer);
      this.drainTimer = -1;
    }
    this.clearSilenceTimer();
    this.clearPendingRunTimer();
    this.clearResumeListeningTimer();

    const idsToRemove: string[] = [];
    if (this.activeUserEntryId !== null) {
      idsToRemove.push(this.activeUserEntryId);
    }
    for (let i = 0; i < this.queuedConversationEntryIds.length; i++) {
      idsToRemove.push(this.queuedConversationEntryIds[i]);
    }
    if (this.pendingAssistantEntryId !== null) {
      idsToRemove.push(this.pendingAssistantEntryId);
    }

    this.playbackToken += 1;
    this.micEnabled = false;
    this.micCooldown = false;
    this.isSpeaking = false;
    this.talkModeEnabled = false;
    this.liveTranscript = '';
    this.sessionSegments = [];
    this.lastFinalSegment = null;
    this.messageQueue = [];
    this.queuedConversationEntryIds = [];
    this.queuedSpeakReplies = [];
    this.activeUserEntryId = null;
    this.pendingRunId = null;
    this.pendingAssistantEntryId = null;
    this.isSending = false;
    this.activeSpeakReply = false;
    this.replyPlaybackActive = false;
    this.replyPlaybackStartedAtMs = 0;
    this.pendingInterruptedPlaybackNote = null;

    if (shouldStopRecognizer) {
      await this.asr.stop();
    }
    await this.tts.stop();
    if (shouldAbortRun && chat) {
      try {
        chat.abort();
      } catch {
        // best-effort
      }
    }
    this.removeConversationEntries(idsToRemove);
    this.refreshStatusDetail();
    this.notifyUi();
  }

  private async reloadTalkConfig(): Promise<void> {
    const chat = this.getChat();
    if (!chat || !this.getGatewayConnected()) {
      this.silenceTimeoutMs = DEFAULT_SILENCE_TIMEOUT_MS;
      this.interruptOnSpeech = false;
      return;
    }
    try {
      const payloadJson = await chat.requestTalkConfig();
      const config = resolveTalkConfigState(payloadJson);
      this.silenceTimeoutMs = config.silenceTimeoutMs;
      this.interruptOnSpeech = config.interruptOnSpeech;
      hilog.info(
        LOG_DOMAIN,
        LOG_TAG,
        'talk.config loaded silenceTimeoutMs=%{public}d interruptOnSpeech=%{public}s',
        this.silenceTimeoutMs,
        String(this.interruptOnSpeech),
      );
    } catch (err) {
      this.silenceTimeoutMs = DEFAULT_SILENCE_TIMEOUT_MS;
      this.interruptOnSpeech = false;
      hilog.warn(
        LOG_DOMAIN,
        LOG_TAG,
        'talk.config load failed, using defaults err=%{public}s',
        err instanceof Error ? err.message : String(err),
      );
    }
  }

  /** When false (user left Voice tab), stop TTS so replies do not play in background. */
  setVoiceScreenActive(active: boolean): void {
    this.voiceScreenActive = active;
    if (!active) {
      this.talkModeEnabled = false;
      this.clearResumeListeningTimer();
      this.playbackToken += 1;
      this.isSpeaking = false;
      this.replyPlaybackActive = false;
      this.replyPlaybackStartedAtMs = 0;
      void this.tts.stop();
    }
    this.refreshStatusDetail();
    this.notifyUi();
  }

  onGatewayConnectionChanged(_connected: boolean): void {
    if (!this.getGatewayConnected()) {
      this.clearResumeListeningTimer();
    } else if (this.talkModeEnabled && !this.micEnabled && !this.micCooldown && !this.isSending && !this.replyPlaybackActive) {
      this.scheduleResumeListening(0);
    }
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
      const shouldResume = this.talkModeEnabled;
      const allowBackgroundSpeak = this.activeSpeakReply;
      if (finalText.length > 0) {
        this.upsertPendingAssistant(finalText, false);
        void this.playAssistantReply(finalText, allowBackgroundSpeak).finally(() => {
          if (shouldResume) {
            this.scheduleResumeListening();
          }
        });
      }
      this.completePendingTurn();
      if (finalText.length === 0) {
        if (this.pendingAssistantEntryId !== null) {
          this.updateConversationEntry(this.pendingAssistantEntryId, null, false);
        }
        if (shouldResume) {
          this.scheduleResumeListening();
        }
      }
      return;
    }
    if (state === 'error') {
      const err = String(payload['errorMessage'] ?? 'Voice request failed').trim() || 'Voice request failed';
      const shouldResume = this.talkModeEnabled;
      this.upsertPendingAssistant(err, false);
      this.completePendingTurn();
      if (shouldResume) {
        this.scheduleResumeListening(900);
      }
      return;
    }
    if (state === 'aborted') {
      const shouldResume = this.talkModeEnabled;
      this.upsertPendingAssistant('Response aborted', false);
      this.completePendingTurn();
      if (shouldResume) {
        this.scheduleResumeListening(420);
      }
    }
  }

  private async playAssistantReply(text: string, allowBackgroundSpeak: boolean = false): Promise<void> {
    if (!this.speakerEnabled || (!this.voiceScreenActive && !allowBackgroundSpeak)) {
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

    this.replyPlaybackActive = true;
    this.isSpeaking = true;
    this.replyPlaybackStartedAtMs = Date.now();
    this.refreshStatusDetail();
    this.notifyUi();
    try {
      this.playbackToken += 1;
      const token = this.playbackToken;
      await this.tts.stop();
      if (token !== this.playbackToken || !this.speakerEnabled || (!this.voiceScreenActive && !allowBackgroundSpeak)) {
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
          if (token !== this.playbackToken || !this.speakerEnabled || (!this.voiceScreenActive && !allowBackgroundSpeak)) {
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
      if (token !== this.playbackToken || !this.speakerEnabled || (!this.voiceScreenActive && !allowBackgroundSpeak)) {
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
    } finally {
      this.isSpeaking = false;
      this.replyPlaybackActive = false;
      this.replyPlaybackStartedAtMs = 0;
      this.refreshStatusDetail();
      this.notifyUi();
    }
  }

  async setMicEnabled(enabled: boolean): Promise<void> {
    if (enabled === this.micEnabled) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'setMicEnabled no-op enabled=%{public}s', String(enabled));
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'setMicEnabled enabled=%{public}s', String(enabled));
    this.micEnabled = enabled;
    if (enabled) {
      this.talkModeEnabled = true;
      this.micCooldown = false;
      this.clearSilenceTimer();
      this.clearResumeListeningTimer();
      this.refreshStatusDetail();
      this.notifyUi();
      // Release playback before opening the mic — STT + TTS sharing audio trips some devices.
      if (this.replyPlaybackActive && this.interruptOnSpeech) {
        this.markInterruptedPlayback();
      }
      this.playbackToken += 1;
      this.isSpeaking = false;
      this.replyPlaybackActive = false;
      this.replyPlaybackStartedAtMs = 0;
      await this.tts.stop();
      void this.reloadTalkConfig();
      const started = await this.asr.start(
        (text, isFinal) => {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'asr callback final=%{public}s text=%{public}s', String(isFinal), text);
          this.onRecognizerText(text, isFinal);
        },
        (err) => {
          hilog.error(LOG_DOMAIN, LOG_TAG, 'asr error %{public}s', err);
          this.statusDetail = err.trim().length > 0 ? err.trim() : 'Speech recognition failed';
          this.notifyUi();
        },
      );
      if (!started) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'asr start returned false');
        this.micEnabled = false;
        this.talkModeEnabled = false;
        this.refreshStatusDetail();
        this.notifyUi();
        return;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'asr started successfully');
      this.sendQueuedIfIdle();
    } else {
      this.micCooldown = true;
      this.clearSilenceTimer();
      this.clearResumeListeningTimer();
      if (this.drainTimer >= 0) {
        clearTimeout(this.drainTimer);
        this.drainTimer = -1;
      }
      await this.asr.stop();
      this.drainTimer = setTimeout(() => {
        this.drainTimer = -1;
        const partial = this.liveTranscript.trim();
        hilog.info(
          LOG_DOMAIN,
          LOG_TAG,
          'drain firing partial=%{public}s segments=%{public}d',
          partial,
          this.sessionSegments.length,
        );
        if (
          partial.length > 0 &&
          (this.sessionSegments.length === 0 || this.sessionSegments[this.sessionSegments.length - 1] !== partial)
        ) {
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

  isBusyForVoiceWake(): boolean {
    return this.canCancel() || this.replyPlaybackActive;
  }

  async speakWakeCommand(command: string): Promise<void> {
    const trimmed = command.trim();
    if (trimmed.length === 0) {
      return;
    }
    this.playbackToken += 1;
    this.isSpeaking = false;
    this.replyPlaybackActive = false;
    this.replyPlaybackStartedAtMs = 0;
    await this.tts.stop();
    this.refreshStatusDetail();
    this.notifyUi();
    this.enqueueMessage(trimmed, true);
  }

  private onRecognizerText(text: string, isFinal: boolean): void {
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'onRecognizerText ignored empty');
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onRecognizerText final=%{public}s text=%{public}s', String(isFinal), trimmed);
    if (!isFinal) {
      this.liveTranscript = trimmed;
      if (this.micEnabled) {
        this.scheduleSilenceFinalize();
      }
      this.refreshStatusDetail();
      this.notifyUi();
      return;
    }
    this.liveTranscript = trimmed;
    if (this.lastFinalSegment === trimmed) {
      if (this.micEnabled) {
        this.scheduleSilenceFinalize();
      }
      this.refreshStatusDetail();
      this.notifyUi();
      return;
    }
    this.lastFinalSegment = trimmed;
    this.sessionSegments.push(trimmed);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'sessionSegments appended count=%{public}d', this.sessionSegments.length);
    this.liveTranscript = '';
    if (!this.micEnabled && this.micCooldown) {
      if (this.drainTimer >= 0) {
        clearTimeout(this.drainTimer);
        this.drainTimer = -1;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'final result arrived during cooldown; flushing immediately');
      this.flushSessionToQueue();
      this.micCooldown = false;
      this.sendQueuedIfIdle();
    } else if (this.micEnabled) {
      this.scheduleSilenceFinalize();
    }
    this.refreshStatusDetail();
    this.notifyUi();
  }

  private scheduleSilenceFinalize(): void {
    if (!this.micEnabled) {
      return;
    }
    const partial = this.liveTranscript.trim();
    if (partial.length === 0 && this.sessionSegments.length === 0) {
      return;
    }
    this.clearSilenceTimer();
    const timeoutMs = this.silenceTimeoutMs > 0 ? this.silenceTimeoutMs : DEFAULT_SILENCE_TIMEOUT_MS;
    this.silenceTimer = setTimeout(() => {
      this.silenceTimer = -1;
      if (!this.micEnabled) {
        return;
      }
      const currentPartial = this.liveTranscript.trim();
      if (currentPartial.length === 0 && this.sessionSegments.length === 0) {
        return;
      }
      hilog.info(
        LOG_DOMAIN,
        LOG_TAG,
        'silence timeout reached; auto-stopping mic timeoutMs=%{public}d partial=%{public}s segments=%{public}d',
        timeoutMs,
        currentPartial,
        this.sessionSegments.length,
      );
      void this.setMicEnabled(false);
    }, timeoutMs) as number;
  }

  private clearSilenceTimer(): void {
    if (this.silenceTimer >= 0) {
      clearTimeout(this.silenceTimer);
      this.silenceTimer = -1;
    }
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
      hilog.info(LOG_DOMAIN, LOG_TAG, 'flushSessionToQueue skipped empty message');
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'flushSessionToQueue message=%{public}s', message);
    this.enqueueMessage(message, false);
  }

  private enqueueMessage(message: string, speakReply: boolean): void {
    const conversationId = this.appendConversation(VoiceConversationRole.User, message, false);
    this.messageQueue.push(message);
    this.queuedConversationEntryIds.push(conversationId);
    this.queuedSpeakReplies.push(speakReply);
    hilog.info(
      LOG_DOMAIN,
      LOG_TAG,
      'messageQueue size=%{public}d speakReply=%{public}s',
      this.messageQueue.length,
      String(speakReply),
    );
    this.notifyUi();
    this.sendQueuedIfIdle();
  }

  private sendQueuedIfIdle(): void {
    if (this.isSending) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'sendQueuedIfIdle skipped because isSending=true');
      return;
    }
    if (this.messageQueue.length === 0) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'sendQueuedIfIdle skipped because queue empty');
      this.refreshStatusDetail();
      this.notifyUi();
      return;
    }
    if (!this.getGatewayConnected()) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'sendQueuedIfIdle waiting for gateway queue=%{public}d', this.messageQueue.length);
      this.refreshStatusDetail();
      this.notifyUi();
      return;
    }
    const chat = this.getChat();
    if (!chat) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'sendQueuedIfIdle missing chat controller');
      return;
    }
    const next = this.messageQueue[0];
    hilog.info(LOG_DOMAIN, LOG_TAG, 'sendQueuedIfIdle sending message=%{public}s', next);
    const outboundMessage = buildTalkModePrompt(next, this.pendingInterruptedPlaybackNote);
    this.pendingInterruptedPlaybackNote = null;
    const runKey = randomId();
    this.activeUserEntryId = this.queuedConversationEntryIds.length > 0 ? this.queuedConversationEntryIds.shift() ?? null : null;
    this.activeSpeakReply = this.queuedSpeakReplies.length > 0 ? this.queuedSpeakReplies.shift() === true : false;
    this.isSending = true;
    this.pendingRunId = runKey;
    this.armPendingRunTimeout(runKey);
    this.refreshStatusDetail();
    this.notifyUi();
    const thinking = chat.getThinkingLevel();
    void chat.sendMessage(outboundMessage.length > 0 ? outboundMessage : next, thinking, undefined, runKey).then((canonicalRunId: string | null) => {
      hilog.info(
        LOG_DOMAIN,
        LOG_TAG,
        'chat.send resolved canonicalRunId=%{public}s runKey=%{public}s',
        canonicalRunId ?? 'null',
        runKey,
      );
      if (!canonicalRunId || canonicalRunId.trim().length === 0) {
        this.clearPendingRunTimer();
        if (this.messageQueue.length > 0 && this.messageQueue[0] === next) {
          this.messageQueue.shift();
        }
        this.isSending = false;
        this.pendingRunId = null;
        this.pendingAssistantEntryId = null;
        this.activeUserEntryId = null;
        this.activeSpeakReply = false;
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
    }).catch((err: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'chat.send rejected: %{public}s', err.message);
      this.clearPendingRunTimer();
      if (this.messageQueue.length > 0 && this.messageQueue[0] === next) {
        this.messageQueue.shift();
      }
      this.isSending = false;
      this.pendingRunId = null;
      this.pendingAssistantEntryId = null;
      this.activeUserEntryId = null;
      this.activeSpeakReply = false;
      this.statusDetail = `Send failed: ${err.message}`;
      this.refreshStatusDetail();
      this.notifyUi();
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
      this.activeSpeakReply = false;
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
    this.activeUserEntryId = null;
    this.isSending = false;
    this.activeSpeakReply = false;
    this.sendQueuedIfIdle();
    this.refreshStatusDetail();
    this.notifyUi();
  }

  private queuedWaitingLabel(): string {
    const n = this.messageQueue.length;
    return `${n} queued · waiting for gateway`;
  }

  private refreshStatusDetail(): void {
    if (this.replyPlaybackActive || this.isSpeaking) {
      this.statusDetail = this.interruptOnSpeech ? 'Speaking · tap mic to interrupt' : 'Speaking';
      return;
    }
    if (this.micCooldown) {
      this.statusDetail = 'Cooldown';
      return;
    }
    if (!this.getGatewayConnected() && this.messageQueue.length > 0) {
      this.statusDetail = this.queuedWaitingLabel();
      return;
    }
    if (!this.getGatewayConnected() && this.talkModeEnabled) {
      this.statusDetail = 'Talk mode · gateway offline';
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
    if (this.talkModeEnabled) {
      this.statusDetail = 'Ready for next turn';
      return;
    }
    this.statusDetail = 'Mic off';
  }

  private activityLabel(): string {
    if (this.replyPlaybackActive || this.isSpeaking) {
      return 'Speaking';
    }
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
    if (this.talkModeEnabled) {
      return 'Talk mode';
    }
    return 'Mic off';
  }

  private notifyUi(): void {
    this.uiListener?.(this.snapshotUi());
    this.activityListener?.();
  }

  private canCancel(): boolean {
    return this.micEnabled ||
      this.micCooldown ||
      this.isSending ||
      this.replyPlaybackActive ||
      this.talkModeEnabled ||
      this.liveTranscript.trim().length > 0 ||
      this.sessionSegments.length > 0 ||
      this.messageQueue.length > 0 ||
      this.pendingRunId !== null;
  }

  private snapshotUi(): VoiceUiState {
    const q = this.messageQueue.slice();
    const c = this.conversation.slice();
    const s: VoiceUiState = {
      micEnabled: this.micEnabled,
      micCooldown: this.micCooldown,
      isSpeaking: this.replyPlaybackActive || this.isSpeaking,
      speakerEnabled: this.speakerEnabled,
      canCancel: this.canCancel(),
      liveTranscript: this.liveTranscript,
      queuedMessages: q,
      conversation: c,
      isSending: this.isSending,
      activityLabel: this.activityLabel(),
      statusDetail: this.statusDetail,
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

  private removeConversationEntries(ids: string[]): void {
    if (ids.length === 0 || this.conversation.length === 0) {
      return;
    }
    const removeSet = new Set<string>();
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i];
      if (id && id.length > 0) {
        removeSet.add(id);
      }
    }
    if (removeSet.size === 0) {
      return;
    }
    const next: VoiceConversationEntry[] = [];
    for (let i = 0; i < this.conversation.length; i++) {
      const entry = this.conversation[i];
      if (!removeSet.has(entry.id)) {
        next.push(entry);
      }
    }
    this.conversation = next;
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
    this.isSpeaking = false;
    this.talkModeEnabled = false;
    this.activeSpeakReply = false;
    this.replyPlaybackActive = false;
    this.replyPlaybackStartedAtMs = 0;
    if (this.drainTimer >= 0) {
      clearTimeout(this.drainTimer);
      this.drainTimer = -1;
    }
    this.clearSilenceTimer();
    this.clearPendingRunTimer();
    this.clearResumeListeningTimer();
    await this.asr.stop();
    await this.tts.stop();
    this.refreshStatusDetail();
    this.notifyUi();
  }
}
