/**
 * HarmonyOS Core Speech Kit — text-to-speech for assistant replies on the Voice tab.
 * Gateway audio: try data URL first, then temp file under cache (Android TalkMode parity).
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { media } from '@kit.MediaKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';

function resolveGatewayAudioSuffix(
  mimeType: string | null,
  fileExtension: string | null,
  outputFormat: string | null,
): string {
  const ext = (fileExtension ?? '').trim();
  if (ext.length > 0) {
    return ext.startsWith('.') ? ext : `.${ext}`;
  }
  const mime = (mimeType ?? '').trim().toLowerCase();
  if (mime === 'audio/mpeg') {
    return '.mp3';
  }
  if (mime === 'audio/ogg') {
    return '.ogg';
  }
  if (mime === 'audio/wav') {
    return '.wav';
  }
  if (mime === 'audio/webm') {
    return '.webm';
  }
  const fmt = (outputFormat ?? '').trim().toLowerCase();
  if (fmt === 'mp3' || fmt.startsWith('mp3_') || fmt.endsWith('-mp3')) {
    return '.mp3';
  }
  if (fmt === 'opus' || fmt.startsWith('opus_')) {
    return '.ogg';
  }
  if (fmt.endsWith('-wav')) {
    return '.wav';
  }
  if (fmt.endsWith('-webm')) {
    return '.webm';
  }
  return '.audio';
}

function writeGatewayAudioTempFile(b64: string, cacheDir: string, suffix: string): string {
  const base = `${cacheDir}/openclaw_tts`;
  try {
    fs.accessSync(base);
  } catch {
    try {
      fs.mkdirSync(base, true);
    } catch {
      return '';
    }
  }
  const fullPath = `${base}/tts_${Date.now()}${suffix}`;
  let u8: Uint8Array;
  try {
    const helper = new util.Base64Helper();
    u8 = helper.decodeSync(b64);
  } catch {
    return '';
  }
  try {
    const opened = fs.openSync(fullPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(opened.fd, u8);
    } finally {
      fs.closeSync(opened);
    }
    return fullPath;
  } catch {
    try {
      fs.unlinkSync(fullPath);
    } catch {
      // ignore
    }
    return '';
  }
}

export class HarmonyTtsPlayer {
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private avPlayer: media.AVPlayer | null = null;

  private async stopGatewayAudio(): Promise<void> {
    const p = this.avPlayer;
    this.avPlayer = null;
    if (!p) {
      return;
    }
    try {
      p.stop();
    } catch {
      // best-effort
    }
    try {
      await p.release();
    } catch {
      // best-effort
    }
  }

  async stop(): Promise<void> {
    await this.stopGatewayAudio();
    const eng = this.engine;
    this.engine = null;
    if (!eng) {
      return;
    }
    try {
      eng.stop();
    } catch {
      // best-effort
    }
    try {
      eng.shutdown();
    } catch {
      // best-effort
    }
  }

  /**
   * Plays gateway TTS bytes. Tries data: URL first, then decodes to a cache file (AVPlayer file path).
   */
  async speakGatewayAudioBase64(
    audioBase64: string,
    mimeType: string | null,
    fileExtension: string | null,
    outputFormat: string | null,
  ): Promise<boolean> {
    const b64 = (audioBase64 ?? '').trim();
    if (b64.length === 0) {
      return false;
    }
    if (!canIUse('SystemCapability.Multimedia.Media.AVPlayer')) {
      return false;
    }
    await this.stopGatewayAudio();
    const mime = (mimeType ?? '').trim().length > 0 ? String(mimeType).trim() : 'audio/mpeg';
    const dataUrl = `data:${mime};base64,${b64}`;
    const suffix = resolveGatewayAudioSuffix(mimeType, fileExtension, outputFormat);

    let player: media.AVPlayer;
    try {
      player = await media.createAVPlayer();
    } catch {
      return false;
    }
    this.avPlayer = player;
    const okData = await this.playAvPlayerFromUrl(player, dataUrl);
    if (okData) {
      return true;
    }

    const ctx = AppStorage.get<common.UIAbilityContext>('abilityContext');
    let cacheDir = '';
    if (ctx !== undefined && ctx !== null) {
      cacheDir = ctx.cacheDir;
    }
    if (cacheDir.length === 0) {
      return false;
    }
    const tempPath = writeGatewayAudioTempFile(b64, cacheDir, suffix);
    if (tempPath.length === 0) {
      return false;
    }
    let player2: media.AVPlayer;
    try {
      player2 = await media.createAVPlayer();
    } catch {
      try {
        fs.unlinkSync(tempPath);
      } catch {
        // ignore
      }
      return false;
    }
    this.avPlayer = player2;
    try {
      return await this.playAvPlayerFromUrl(player2, tempPath);
    } finally {
      try {
        fs.unlinkSync(tempPath);
      } catch {
        // ignore
      }
    }
  }

  private playAvPlayerFromUrl(player: media.AVPlayer, url: string): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let settled = false;
      let timeoutId: number = -1;
      const done = (ok: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timeoutId >= 0) {
          clearTimeout(timeoutId);
          timeoutId = -1;
        }
        void this.stopGatewayAudio();
        resolve(ok);
      };
      try {
        player.on('stateChange', (state: string, _reason: media.StateChangeReason) => {
          if (state === 'completed') {
            done(true);
          }
        });
        player.on('error', (_err: BusinessError) => {
          done(false);
        });
        player.url = url;
        void player
          .prepare()
          .then(() => {
            player.play();
            timeoutId = setTimeout(() => {
              done(false);
            }, 15000) as number;
          })
          .catch(() => {
            done(false);
          });
      } catch {
        done(false);
      }
    });
  }

  /**
   * Speaks [text] and resolves when playback completes or fails (best-effort).
   * Uses a fresh engine per utterance for simple lifecycle management.
   */
  async speak(text: string, language: string = 'zh-CN'): Promise<void> {
    const trimmed = (text ?? '').trim();
    if (trimmed.length === 0) {
      return;
    }
    if (!canIUse('SystemCapability.AI.TextToSpeech')) {
      return;
    }
    await this.stop();
    return new Promise<void>((resolve) => {
      const initParams: textToSpeech.CreateEngineParams = {
        language: language.length > 0 ? language : 'zh-CN',
        person: 0,
        online: 1,
        extraParams: {},
      };
      textToSpeech.createEngine(initParams, (err: BusinessError, eng: textToSpeech.TextToSpeechEngine) => {
        if (err) {
          resolve();
          return;
        }
        this.engine = eng;
        const done = (): void => {
          void this.stop();
          resolve();
        };
        try {
          eng.setListener({
            onStart: (_requestId: string, _response: textToSpeech.StartResponse) => {},
            onComplete: (_requestId: string, _response: textToSpeech.CompleteResponse) => {
              done();
            },
            onStop: (_requestId: string, _response: textToSpeech.StopResponse) => {
              done();
            },
            onError: (_requestId: string, _errorCode: number, _errorMessage: string) => {
              done();
            },
          });
        } catch {
          done();
          return;
        }
        const requestId = `openclaw-tts-${Date.now()}`;
        try {
          eng.speak(trimmed, { requestId: requestId, extraParams: {} });
        } catch {
          done();
        }
      });
    });
  }
}
