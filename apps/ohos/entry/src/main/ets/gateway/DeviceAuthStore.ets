/**
 * Device auth token store for gateway pairing.
 */
import { SecurePrefs } from '../common/SecurePrefs';

function tokenKey(deviceId: string, role: string): string {
  const d = deviceId.trim().toLowerCase();
  const r = role.trim().toLowerCase();
  return `gateway.deviceToken.${d}.${r}`;
}

export interface DeviceAuthTokenStore {
  loadToken(deviceId: string, role: string): Promise<string | null>;
  saveToken(deviceId: string, role: string, token: string): Promise<void>;
  clearToken(deviceId: string, role: string): Promise<void>;
}

export class DeviceAuthStore implements DeviceAuthTokenStore {
  private prefs: SecurePrefs;

  constructor(prefs: SecurePrefs) {
    this.prefs = prefs;
  }

  async loadToken(deviceId: string, role: string): Promise<string | null> {
    const key = tokenKey(deviceId, role);
    const val = await this.prefs.getString(key);
    return val?.trim() && val.length > 0 ? val : null;
  }

  async saveToken(deviceId: string, role: string, token: string): Promise<void> {
    const key = tokenKey(deviceId, role);
    await this.prefs.putString(key, token.trim());
  }

  async clearToken(deviceId: string, role: string): Promise<void> {
    const key = tokenKey(deviceId, role);
    await this.prefs.remove(key);
  }
}
