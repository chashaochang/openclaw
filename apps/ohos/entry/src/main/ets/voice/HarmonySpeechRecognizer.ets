/**
 * HarmonyOS Core Speech Kit — streaming recognition using the device microphone.
 * See Core Speech Kit guide (SpeechRecognizer).
 */
import { speechRecognizer } from '@kit.CoreSpeechKit';

function recognizedTextFromResult(result: speechRecognizer.SpeechRecognitionResult): string {
  const primary = String(result.result ?? '').trim();
  if (primary.length > 0) {
    return primary;
  }
  try {
    const raw = JSON.stringify(result);
    const o = JSON.parse(raw) as Record<string, string>;
    const alt = o['text'] ?? o['msg'] ?? '';
    return String(alt).trim();
  } catch {
    return '';
  }
}

export type SpeechTextCallback = (text: string, isFinal: boolean) => void;
export type SpeechErrorCallback = (message: string) => void;

export class HarmonySpeechRecognizer {
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private sessionSeq = 0;
  private currentSessionId = '';
  private continueListening = false;
  private onText: SpeechTextCallback | null = null;
  private onError: SpeechErrorCallback | null = null;
  private language = 'zh-CN';
  private restartTimer: number = -1;

  setLanguageCode(lang: string): void {
    const t = (lang ?? '').trim();
    this.language = t.length > 0 ? t : 'zh-CN';
  }

  /**
   * @returns false if recognition could not start (caller should turn mic UI off).
   */
  async start(onText: SpeechTextCallback, onError: SpeechErrorCallback): Promise<boolean> {
    this.continueListening = true;
    if (!canIUse('SystemCapability.AI.SpeechRecognizer')) {
      onError('Speech recognition not supported on this device');
      this.continueListening = false;
      return false;
    }
    await this.tearDownEngine();
    this.onText = onText;
    this.onError = onError;
    try {
      this.engine = await this.createEngineWithModeFallback();
      this.attachListener();
      await this.beginListeningSession();
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      onError(`Speech start failed: ${msg}`);
      await this.stop();
      return false;
    }
  }

  /** Try offline/online in device-friendly order (zh-CN offline is commonly available on HarmonyOS). */
  private async createEngineWithModeFallback(): Promise<speechRecognizer.SpeechRecognitionEngine> {
    const lang = this.language.toLowerCase();
    const prefersOfflineFirst = lang.startsWith('zh');
    const modes: number[] = prefersOfflineFirst ? [0, 1] : [1, 0];
    let lastErr: Error | null = null;
    for (let i = 0; i < modes.length; i++) {
      try {
        const createParams: speechRecognizer.CreateEngineParams = {
          language: this.language,
          online: modes[i],
          extraParams: {},
        };
        return await speechRecognizer.createEngine(createParams);
      } catch (e) {
        lastErr = e instanceof Error ? e : new Error(String(e));
      }
    }
    throw lastErr ?? new Error('createEngine failed');
  }

  private attachListener(): void {
    const eng = this.engine;
    if (!eng) {
      return;
    }
    eng.setListener({
      onStart: (_sessionId: string, _eventMessage: string) => {},
      onEvent: (_sessionId: string, _eventCode: number, _eventMessage: string) => {},
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
        if (!this.continueListening) {
          return;
        }
        const text = recognizedTextFromResult(result);
        const isLast = result.isLast === true;
        if (text.length > 0 && this.onText) {
          this.onText(text, isLast);
        }
        if (isLast && this.continueListening) {
          this.scheduleListenAgain();
        }
      },
      onComplete: (_sessionId: string, _eventMessage: string) => {},
      onError: (sessionId: string, errorCode: number, errorMessage: string) => {
        if (!this.continueListening) {
          return;
        }
        const detail = `${errorMessage} (${errorCode})`;
        if (this.onError) {
          this.onError(detail);
        }
        this.scheduleListenAgain(900);
      },
    });
  }

  private scheduleListenAgain(delayMs: number = 380): void {
    if (this.restartTimer >= 0) {
      clearTimeout(this.restartTimer);
      this.restartTimer = -1;
    }
    this.restartTimer = setTimeout(() => {
      this.restartTimer = -1;
      if (!this.continueListening) {
        return;
      }
      void this.beginListeningSession();
    }, delayMs) as number;
  }

  private async beginListeningSession(): Promise<void> {
    const eng = this.engine;
    if (!eng || !this.continueListening) {
      return;
    }
    this.sessionSeq += 1;
    this.currentSessionId = `openclaw-asr-${Date.now()}-${this.sessionSeq}`;
    const audioInfo: speechRecognizer.AudioInfo = {
      audioType: 'pcm',
      sampleRate: 16000,
      soundChannel: 1,
      sampleBit: 16,
    };
    const emptyExtra: Record<string, Object> = {};
    const startParams: speechRecognizer.StartParams = {
      sessionId: this.currentSessionId,
      audioInfo: audioInfo,
      extraParams: emptyExtra,
    };
    try {
      eng.startListening(startParams);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (this.onError) {
        this.onError(`listen: ${msg}`);
      }
      this.scheduleListenAgain(1200);
    }
  }

  private async tearDownEngine(): Promise<void> {
    if (this.restartTimer >= 0) {
      clearTimeout(this.restartTimer);
      this.restartTimer = -1;
    }
    const eng = this.engine;
    const sid = this.currentSessionId;
    this.engine = null;
    this.currentSessionId = '';
    if (!eng) {
      return;
    }
    try {
      if (sid.length > 0) {
        eng.finish(sid);
      }
    } catch {
      // best-effort
    }
    try {
      if (sid.length > 0) {
        eng.cancel(sid);
      }
    } catch {
      // best-effort
    }
    try {
      eng.shutdown();
    } catch {
      // best-effort
    }
  }

  async stop(): Promise<void> {
    this.continueListening = false;
    await this.tearDownEngine();
    this.onText = null;
    this.onError = null;
  }
}
