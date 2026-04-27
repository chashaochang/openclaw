import { hilog } from '@kit.PerformanceAnalysisKit';
import { HarmonySpeechRecognizer } from './HarmonySpeechRecognizer';
import { VoiceWakeCommandExtractor } from './VoiceWakeCommandExtractor';
import { defaultWakeWords, sanitizeWakeWords } from './WakeWords';

const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'VoiceWake';
const DUPLICATE_WINDOW_MS = 4000;

export class VoiceWakeManager {
  private asr: HarmonySpeechRecognizer = new HarmonySpeechRecognizer();
  private triggerWords: string[] = defaultWakeWords();
  private onCommand: (command: string) => Promise<void>;
  private listening = false;
  private statusText = 'Off';
  private lastDispatchedCommand = '';
  private lastDispatchedAt = 0;
  private statusResetTimer = -1;

  constructor(onCommand: (command: string) => Promise<void>) {
    this.onCommand = onCommand;
  }

  setTriggerWords(words: string[]): void {
    this.triggerWords = sanitizeWakeWords(words);
  }

  getTriggerWords(): string[] {
    return this.triggerWords.slice();
  }

  isListening(): boolean {
    return this.listening;
  }

  getStatusText(): string {
    return this.statusText;
  }

  async start(): Promise<void> {
    if (this.listening) {
      return;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'start requested');
    this.clearStatusResetTimer();
    this.statusText = 'Starting';
    const started = await this.asr.start(
      (text: string, _isFinal: boolean) => {
        this.handleTranscript(text);
      },
      (message: string) => {
        const trimmed = message.trim();
        this.statusText = trimmed.length > 0 ? trimmed : 'Speech recognition failed';
      },
    );
    if (!started) {
      this.listening = false;
      this.statusText = 'Speech recognizer unavailable';
      return;
    }
    this.listening = true;
    this.statusText = 'Listening';
  }

  async stop(statusText: string = 'Off'): Promise<void> {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'stop requested reason=%{public}s', statusText);
    this.clearStatusResetTimer();
    this.listening = false;
    this.statusText = statusText;
    await this.asr.stop();
  }

  private handleTranscript(text: string): void {
    if (!this.listening) {
      return;
    }
    const command = VoiceWakeCommandExtractor.extractCommand(text, this.triggerWords);
    if (!command) {
      return;
    }
    const now = Date.now();
    if (
      this.lastDispatchedCommand === command &&
      now - this.lastDispatchedAt < DUPLICATE_WINDOW_MS
    ) {
      return;
    }
    this.lastDispatchedCommand = command;
    this.lastDispatchedAt = now;
    this.statusText = `Triggered: ${command}`;
    this.clearStatusResetTimer();
    this.statusResetTimer = setTimeout(() => {
      this.statusResetTimer = -1;
      if (this.listening) {
        this.statusText = 'Listening';
      }
    }, 1600) as number;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'triggered command=%{public}s', command);
    void this.onCommand(command).catch((err: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'command dispatch failed: %{public}s', err.message);
      this.statusText = `Dispatch failed: ${err.message}`;
    });
  }

  private clearStatusResetTimer(): void {
    if (this.statusResetTimer >= 0) {
      clearTimeout(this.statusResetTimer);
      this.statusResetTimer = -1;
    }
  }
}
