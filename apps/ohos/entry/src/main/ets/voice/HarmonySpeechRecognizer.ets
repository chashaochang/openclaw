/**
 * HarmonyOS Core Speech Kit — streaming recognition using the device microphone.
 * See Core Speech Kit guide (SpeechRecognizer).
 */
import { audio } from '@kit.AudioKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'VoiceAsr';
const AUDIO_CHUNK_BYTES = 1280;

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
  private capturer: audio.AudioCapturer | null = null;
  private sessionSeq = 0;
  private currentSessionId = '';
  private continueListening = false;
  private acceptResults = false;
  private onText: SpeechTextCallback | null = null;
  private onError: SpeechErrorCallback | null = null;
  private language = 'zh-CN';
  private restartTimer: number = -1;
  private pendingAudio: Uint8Array = new Uint8Array(0);
  private audioBytesSent = 0;
  private readDataCallback: ((buffer: ArrayBuffer) => void) | null = null;
  private sessionStarted = false;
  private shuttingDownSession = false;

  private clearRestartTimer(): void {
    if (this.restartTimer >= 0) {
      clearTimeout(this.restartTimer);
      this.restartTimer = -1;
    }
  }

  setLanguageCode(lang: string): void {
    const t = (lang ?? '').trim().toLowerCase();
    // HarmonyOS CoreSpeechKit currently supports zh-CN offline recognition only.
    this.language = t === 'zh-cn' ? 'zh-CN' : 'zh-CN';
  }

  /**
   * @returns false if recognition could not start (caller should turn mic UI off).
   */
  async start(onText: SpeechTextCallback, onError: SpeechErrorCallback): Promise<boolean> {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'start requested, language=%{public}s', this.language);
    this.continueListening = true;
    this.acceptResults = true;
    if (!canIUse('SystemCapability.AI.SpeechRecognizer')) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'SpeechRecognizer syscap unavailable');
      onError('Speech recognition not supported on this device');
      this.continueListening = false;
      this.acceptResults = false;
      return false;
    }
    await this.tearDownEngine();
    this.onText = onText;
    this.onError = onError;
    try {
      this.engine = await this.createEngineWithModeFallback();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'engine created');
      this.attachListener();
      this.shuttingDownSession = false;
      await this.beginListeningSession();
      return true;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'start failed: %{public}s', msg);
      onError(`Speech start failed: ${msg}`);
      await this.stop();
      return false;
    }
  }

  private async createEngineWithModeFallback(): Promise<speechRecognizer.SpeechRecognitionEngine> {
    const createParams: speechRecognizer.CreateEngineParams = {
      language: 'zh-CN',
      // CoreSpeechKit currently supports offline recognition only.
      online: 1,
      extraParams: {
        locate: Object('CN'),
        recognizerMode: Object('short'),
      },
    };
    hilog.info(LOG_DOMAIN, LOG_TAG, 'createEngine language=%{public}s online=%{public}d', 'zh-CN', 1);
    return await speechRecognizer.createEngine(createParams);
  }

  private async createAudioCapturer(): Promise<audio.AudioCapturer> {
    const capturerOptions: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      capturerInfo: {
        // Use the plain microphone source instead of VOICE_RECOGNITION.
        // Some devices return capturable PCM for VOICE_RECOGNITION but ASR still
        // produces empty final text, while MIC is the more standard STT feed.
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0,
      },
    };
    const capturer = await audio.createAudioCapturer(capturerOptions);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'audio capturer created source=%{public}d', audio.SourceType.SOURCE_TYPE_MIC);
    return capturer;
  }

  private appendPendingAudio(chunk: Uint8Array): void {
    if (chunk.length === 0) {
      return;
    }
    if (this.pendingAudio.length === 0) {
      this.pendingAudio = chunk;
      return;
    }
    const merged = new Uint8Array(this.pendingAudio.length + chunk.length);
    merged.set(this.pendingAudio, 0);
    merged.set(chunk, this.pendingAudio.length);
    this.pendingAudio = merged;
  }

  private drainPendingAudio(forceTail: boolean): void {
    const eng = this.engine;
    const sid = this.currentSessionId;
    if (!eng || sid.length === 0) {
      return;
    }
    if (!this.sessionStarted) {
      if (this.pendingAudio.length > 0) {
        hilog.info(
          LOG_DOMAIN,
          LOG_TAG,
          'drainPendingAudio waiting for onStart sid=%{public}s buffered=%{public}d',
          sid,
          this.pendingAudio.length,
        );
      }
      return;
    }
    let offset = 0;
    while (this.pendingAudio.length - offset >= AUDIO_CHUNK_BYTES) {
      const chunk = this.pendingAudio.slice(offset, offset + AUDIO_CHUNK_BYTES);
      try {
        eng.writeAudio(sid, chunk);
        this.audioBytesSent += chunk.length;
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'writeAudio failed sid=%{public}s err=%{public}s', sid, msg);
        break;
      }
      offset += AUDIO_CHUNK_BYTES;
    }
    const remaining = this.pendingAudio.length - offset;
    if (forceTail && remaining > 0) {
      const paddedSize = remaining <= 640 ? 640 : AUDIO_CHUNK_BYTES;
      const padded = new Uint8Array(paddedSize);
      padded.set(this.pendingAudio.slice(offset), 0);
      try {
        eng.writeAudio(sid, padded);
        this.audioBytesSent += padded.length;
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        hilog.error(LOG_DOMAIN, LOG_TAG, 'writeAudio tail failed sid=%{public}s err=%{public}s', sid, msg);
      }
      this.pendingAudio = new Uint8Array(0);
      return;
    }
    this.pendingAudio = remaining > 0 ? this.pendingAudio.slice(offset) : new Uint8Array(0);
  }

  private attachCapturerReadData(capturer: audio.AudioCapturer): void {
    this.readDataCallback = (buffer: ArrayBuffer) => {
      if (!this.acceptResults || this.currentSessionId.length === 0) {
        return;
      }
      const chunk = new Uint8Array(buffer);
      this.appendPendingAudio(chunk);
      this.drainPendingAudio(false);
      if (this.audioBytesSent === 0) {
        let nonZero = 0;
        for (let i = 0; i < chunk.length; i++) {
          if (chunk[i] !== 0) {
            nonZero += 1;
          }
        }
        hilog.info(
          LOG_DOMAIN,
          LOG_TAG,
          'readData first buffer bytes=%{public}d nonZero=%{public}d',
          chunk.length,
          nonZero,
        );
      } else if (this.audioBytesSent % (AUDIO_CHUNK_BYTES * 25) === 0) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'readData progress sid=%{public}s bytes=%{public}d', this.currentSessionId, this.audioBytesSent);
      }
    };
    capturer.on('readData', this.readDataCallback);
  }

  private async startAudioCapturer(): Promise<void> {
    await this.stopAudioCapturer();
    const capturer = await this.createAudioCapturer();
    this.pendingAudio = new Uint8Array(0);
    this.audioBytesSent = 0;
    this.sessionStarted = false;
    this.attachCapturerReadData(capturer);
    await capturer.start();
    this.capturer = capturer;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'audio capturer started');
  }

  private async stopAudioCapturer(clearBufferedAudio: boolean = true): Promise<void> {
    const capturer = this.capturer;
    this.capturer = null;
    if (!capturer) {
      if (clearBufferedAudio) {
        this.pendingAudio = new Uint8Array(0);
        this.audioBytesSent = 0;
      }
      this.readDataCallback = null;
      return;
    }
    try {
      if (this.readDataCallback) {
        capturer.off('readData', this.readDataCallback);
      } else {
        capturer.off('readData');
      }
    } catch {
      // best-effort
    }
    this.readDataCallback = null;
    try {
      await capturer.stop();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'audio capturer stopped');
    } catch {
      // best-effort
    }
    try {
      await capturer.release();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'audio capturer released');
    } catch {
      // best-effort
    }
    if (clearBufferedAudio) {
      this.pendingAudio = new Uint8Array(0);
      this.audioBytesSent = 0;
    }
  }

  private attachListener(): void {
    const eng = this.engine;
    if (!eng) {
      return;
    }
    eng.setListener({
      onStart: (sessionId: string, eventMessage: string) => {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'onStart sid=%{public}s msg=%{public}s', sessionId, eventMessage);
        if (sessionId === this.currentSessionId) {
          this.sessionStarted = true;
          this.drainPendingAudio(false);
        }
      },
      onEvent: (sessionId: string, eventCode: number, eventMessage: string) => {
        hilog.info(
          LOG_DOMAIN,
          LOG_TAG,
          'onEvent sid=%{public}s code=%{public}d msg=%{public}s',
          sessionId,
          eventCode,
          eventMessage,
        );
      },
      onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
        if (!this.acceptResults) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'onResult ignored because acceptResults=false sid=%{public}s', sessionId);
          return;
        }
        const text = recognizedTextFromResult(result);
        const isFinal = result.isFinal === true;
        const isLast = result.isLast === true;
        hilog.info(
          LOG_DOMAIN,
          LOG_TAG,
          'onResult sid=%{public}s final=%{public}s last=%{public}s text=%{public}s',
          sessionId,
          String(isFinal),
          String(isLast),
          text,
        );
        if (text.length > 0 && this.onText) {
          this.onText(text, isFinal);
        }
        if (isLast && this.continueListening) {
          this.scheduleListenAgain();
        }
      },
      onComplete: (sessionId: string, eventMessage: string) => {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'onComplete sid=%{public}s msg=%{public}s', sessionId, eventMessage);
        if (sessionId === this.currentSessionId) {
          this.sessionStarted = false;
        }
      },
      onError: (sessionId: string, errorCode: number, errorMessage: string) => {
        if (!this.acceptResults) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'onError ignored because acceptResults=false sid=%{public}s', sessionId);
          return;
        }
        if (sessionId === this.currentSessionId && (!this.continueListening || this.shuttingDownSession)) {
          hilog.info(
            LOG_DOMAIN,
            LOG_TAG,
            'onError ignored during shutdown sid=%{public}s continueListening=%{public}s shuttingDown=%{public}s',
            sessionId,
            String(this.continueListening),
            String(this.shuttingDownSession),
          );
          this.sessionStarted = false;
          return;
        }
        const detail = `${errorMessage} (${errorCode})`;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'onError sid=%{public}s detail=%{public}s', sessionId, detail);
        if (sessionId === this.currentSessionId) {
          this.sessionStarted = false;
        }
        if (this.onError) {
          this.onError(detail);
        }
        this.scheduleListenAgain(900);
      },
    });
  }

  private scheduleListenAgain(delayMs: number = 380): void {
    this.clearRestartTimer();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'scheduleListenAgain delay=%{public}d', delayMs);
    this.restartTimer = setTimeout(() => {
      this.restartTimer = -1;
      if (!this.continueListening) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'restart skipped because continueListening=false');
        return;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'restart beginListeningSession');
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
    this.sessionStarted = false;
    this.shuttingDownSession = false;
    const audioInfo: speechRecognizer.AudioInfo = {
      audioType: 'pcm',
      sampleRate: 16000,
      soundChannel: 1,
      sampleBit: 16,
    };
    const startParams: speechRecognizer.StartParams = {
      sessionId: this.currentSessionId,
      audioInfo: audioInfo,
      extraParams: {
        // Explicitly stream our own PCM so we don't depend on CoreSpeechKit's
        // device-side microphone capture behavior, which has been unreliable.
        recognitionMode: Object(1),
      },
    };
    try {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'startListening sid=%{public}s', this.currentSessionId);
      eng.startListening(startParams);
      await this.startAudioCapturer();
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'startListening failed sid=%{public}s err=%{public}s', this.currentSessionId, msg);
      await this.stopAudioCapturer();
      if (this.onError) {
        this.onError(`listen: ${msg}`);
      }
      this.scheduleListenAgain(1200);
    }
  }

  private async graceFinishSession(): Promise<void> {
    const eng = this.engine;
    const sid = this.currentSessionId;
    if (!eng || sid.length === 0) {
      return;
    }
    this.shuttingDownSession = true;
    try {
      await this.stopAudioCapturer(false);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'finish sid=%{public}s', sid);
      this.drainPendingAudio(true);
      eng.finish(sid);
    } catch {
      // best-effort
    }
    await new Promise<void>((resolve) => {
      setTimeout(() => resolve(), 1200);
    });
  }

  private async tearDownEngine(): Promise<void> {
    this.clearRestartTimer();
    await this.stopAudioCapturer();
    const eng = this.engine;
    const sid = this.currentSessionId;
    this.engine = null;
    this.currentSessionId = '';
    this.sessionStarted = false;
    this.shuttingDownSession = false;
    if (!eng) {
      return;
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
    hilog.info(LOG_DOMAIN, LOG_TAG, 'stop requested sid=%{public}s', this.currentSessionId);
    this.continueListening = false;
    this.clearRestartTimer();
    await this.graceFinishSession();
    await this.stopAudioCapturer();
    this.acceptResults = false;
    const eng = this.engine;
    this.engine = null;
    this.currentSessionId = '';
    this.sessionStarted = false;
    this.shuttingDownSession = false;
    if (eng) {
      try {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'shutdown engine');
        eng.shutdown();
      } catch {
        // best-effort
      }
    }
    this.onText = null;
    this.onError = null;
  }
}
