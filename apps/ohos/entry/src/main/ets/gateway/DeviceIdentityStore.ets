/**
 * Device identity store: Ed25519 keypair, deviceId, sign payload.
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'DeviceIdentity';

const IDENTITY_PREF = 'openclaw_identity';
const KEY_DEVICE_ID = 'deviceId';
const KEY_PUBLIC_B64 = 'publicKeyRawBase64';
const KEY_PRIVATE_B64 = 'privateKeyPkcs8Base64';
const KEY_CREATED = 'createdAtMs';

export interface DeviceIdentity {
  deviceId: string;
  publicKeyRawBase64: string;
  privateKeyPkcs8Base64: string;
  createdAtMs: number;
}

function bytesToHex(data: Uint8Array): string {
  const hex = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < data.length; i++) {
    const b = data[i];
    const hi = (b >> 4) & 0x0f;
    const lo = b & 0x0f;
    out += hex.charAt(hi) + hex.charAt(lo);
  }
  return out;
}

/** deviceId = SHA256(rawPub).digest('hex') — must match gateway deriveDeviceIdFromPublicKey */
function sha256Hex(data: Uint8Array): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: data });
  const digest = md.digestSync();
  return bytesToHex(digest.data);
}

function base64UrlEncode(data: Uint8Array): string {
  const base64Helper = new util.Base64Helper();
  const base64 = base64Helper.encodeToStringSync(data);
  return base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export class DeviceIdentityStore {
  private prefs: preferences.Preferences | null = null;
  private cachedIdentity: DeviceIdentity | null = null;
  private context: common.UIAbilityContext;

  constructor(ctx: common.UIAbilityContext) {
    this.context = ctx;
  }

  private async ensurePrefs(): Promise<preferences.Preferences> {
    if (this.prefs) {
      return this.prefs;
    }
    const opts: preferences.Options = { name: IDENTITY_PREF };
    this.prefs = await preferences.getPreferences(this.context, opts);
    return this.prefs;
  }

  async loadOrCreate(): Promise<DeviceIdentity> {
    if (this.cachedIdentity) {
      return this.cachedIdentity;
    }
    const existing = await this.load();
    if (existing) {
      const derivedId = this.deriveDeviceIdFromPublicKey(existing.publicKeyRawBase64);
      if (derivedId && derivedId !== existing.deviceId) {
        const fixed: DeviceIdentity = {
          deviceId: derivedId,
          publicKeyRawBase64: existing.publicKeyRawBase64,
          privateKeyPkcs8Base64: existing.privateKeyPkcs8Base64,
          createdAtMs: existing.createdAtMs,
        };
        await this.save(fixed);
        this.cachedIdentity = fixed;
        return fixed;
      }
      this.cachedIdentity = existing;
      return existing;
    }
    const fresh = await this.generate();
    await this.save(fresh);
    this.cachedIdentity = fresh;
    return fresh;
  }

  private deriveDeviceIdFromPublicKey(publicKeyRawBase64: string): string | null {
    try {
      const base64Helper = new util.Base64Helper();
      const decoded = base64Helper.decodeSync(publicKeyRawBase64);
      const rawPub = decoded.length === 32 ? decoded : this.extractRawEd25519PublicKey(decoded);
      return rawPub && rawPub.length === 32 ? sha256Hex(rawPub) : null;
    } catch {
      return null;
    }
  }

  private async load(): Promise<DeviceIdentity | null> {
    try {
      const p = await this.ensurePrefs();
      const deviceId = p.getSync(KEY_DEVICE_ID, '') as string;
      const publicKeyRawBase64 = p.getSync(KEY_PUBLIC_B64, '') as string;
      const privateKeyPkcs8Base64 = p.getSync(KEY_PRIVATE_B64, '') as string;
      const createdAtMs = p.getSync(KEY_CREATED, 0) as number;
      if (!deviceId || !publicKeyRawBase64 || !privateKeyPkcs8Base64) {
        return null;
      }
      const result: DeviceIdentity = {
        deviceId,
        publicKeyRawBase64,
        privateKeyPkcs8Base64,
        createdAtMs,
      };
      return result;
    } catch {
      return null;
    }
  }

  private async save(identity: DeviceIdentity): Promise<void> {
    const p = await this.ensurePrefs();
    p.putSync(KEY_DEVICE_ID, identity.deviceId);
    p.putSync(KEY_PUBLIC_B64, identity.publicKeyRawBase64);
    p.putSync(KEY_PRIVATE_B64, identity.privateKeyPkcs8Base64);
    p.putSync(KEY_CREATED, identity.createdAtMs);
    await p.flush();
  }

  private async generate(): Promise<DeviceIdentity> {
    const keyGenerator = cryptoFramework.createAsyKeyGenerator('Ed25519');
    const keyPair = await keyGenerator.generateKeyPair();
    const pubKey = keyPair.pubKey;
    const priKey = keyPair.priKey;
    const pubKeyBlob = pubKey.getEncoded();
    const priKeyBlob = priKey.getEncoded();
    const pubBytes: Uint8Array = pubKeyBlob.data;
    const priBytes: Uint8Array = priKeyBlob.data;
    const base64Helper = new util.Base64Helper();
    const rawPub = this.extractRawEd25519PublicKey(pubBytes);
    const deviceId = rawPub ? sha256Hex(rawPub) : '';
    const pubB64 = rawPub
      ? base64Helper.encodeToStringSync(rawPub)
      : base64Helper.encodeToStringSync(pubBytes);
    const priB64 = base64Helper.encodeToStringSync(priBytes);
    const result: DeviceIdentity = {
      deviceId: deviceId || `ohos-${Date.now()}`,
      publicKeyRawBase64: pubB64,
      privateKeyPkcs8Base64: priB64,
      createdAtMs: Date.now(),
    };
    return result;
  }

  private extractRawEd25519PublicKey(der: Uint8Array): Uint8Array | null {
    if (der.length === 32) return der;
    if (der.length < 38) return null;
    // Ed25519 SPKI: ... 06 03 2b 65 70 03 21 00 [32 bytes]. OID 2b6570 at i, BIT STRING 03 at i+3.
    for (let i = 0; i < der.length - 36; i++) {
      const a = der[i];
      const b = der[i + 1];
      const c = der[i + 2];
      if (a === 0x2b && b === 0x65 && c === 0x70) {
        const bitStringStart = i + 3; // 03 (BIT STRING tag) follows OID
        const t0 = der[bitStringStart];
        const t1 = der[bitStringStart + 1];
        if (t0 === 0x03 && t1 === 33) {
          // 03 21 00 [32 bytes]: key at +3
          return der.slice(bitStringStart + 3, bitStringStart + 35);
        }
        if (t0 === 0x03 && t1 === 34) {
          return der.slice(bitStringStart + 4, bitStringStart + 36);
        }
      }
    }
    if (der.length >= 44) {
      return der.slice(der.length - 32, der.length);
    }
    return null;
  }

  private buildSpkiFromRaw(raw32: Uint8Array): Uint8Array {
    const prefix = new Uint8Array([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]);
    const out = new Uint8Array(prefix.length + raw32.length);
    out.set(prefix);
    out.set(raw32, prefix.length);
    return out;
  }

  async signPayload(payload: string, identity: DeviceIdentity): Promise<string | null> {
    try {
      const base64Helper = new util.Base64Helper();
      const priBytes = base64Helper.decodeSync(identity.privateKeyPkcs8Base64);
      const priKeyBlob: cryptoFramework.DataBlob = { data: priBytes };
      let pubBytes = base64Helper.decodeSync(identity.publicKeyRawBase64);
      if (pubBytes.length === 32) {
        pubBytes = this.buildSpkiFromRaw(pubBytes);
      }
      const pubKeyBlob: cryptoFramework.DataBlob = { data: pubBytes };
      const keyGenerator = cryptoFramework.createAsyKeyGenerator('Ed25519');
      const keyPair = await keyGenerator.convertKey(pubKeyBlob, priKeyBlob);
      const encoder = new util.TextEncoder();
      const payloadBytes = encoder.encodeInto(payload);
      const signData: cryptoFramework.DataBlob = { data: payloadBytes };
      let signResult: cryptoFramework.DataBlob;
      try {
        const signer = cryptoFramework.createSign('Ed25519/NoDigest');
        await signer.init(keyPair.priKey);
        signResult = await signer.sign(signData);
      } catch {
        const signer = cryptoFramework.createSign('Ed25519');
        await signer.init(keyPair.priKey);
        signResult = await signer.sign(signData);
      }
      return base64UrlEncode(signResult.data);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'signPayload failed: %{public}s', String(e));
      return null;
    }
  }

  publicKeyBase64Url(identity: DeviceIdentity): string | null {
    try {
      const base64Helper = new util.Base64Helper();
      const decoded = base64Helper.decodeSync(identity.publicKeyRawBase64);
      const rawPub = decoded.length === 32 ? decoded : this.extractRawEd25519PublicKey(decoded);
      if (!rawPub || rawPub.length !== 32) return null;
      return base64UrlEncode(rawPub);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'publicKeyBase64Url failed: %{public}s', String(e));
      return null;
    }
  }

  clearCache(): void {
    this.cachedIdentity = null;
  }

  /** Clear stored identity so next loadOrCreate generates fresh keys. */
  async clearStored(): Promise<void> {
    this.cachedIdentity = null;
    try {
      const p = await this.ensurePrefs();
      p.putSync(KEY_DEVICE_ID, '');
      p.putSync(KEY_PUBLIC_B64, '');
      p.putSync(KEY_PRIVATE_B64, '');
      p.putSync(KEY_CREATED, 0);
      await p.flush();
    } catch {
      // best-effort
    }
  }
}
