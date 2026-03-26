/**
 * Secure preferences wrapper using @kit.ArkData preferences.
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME = 'openclaw_secure_prefs';

export class SecurePrefs {
  private store: preferences.Preferences | null = null;
  private initPromise: Promise<void> | null = null;
  private context: common.UIAbilityContext;

  constructor(ctx: common.UIAbilityContext) {
    this.context = ctx;
  }

  private async ensureStore(): Promise<preferences.Preferences> {
    if (this.store) {
      return this.store;
    }
    if (this.initPromise) {
      await this.initPromise;
      return this.store!;
    }
    const opts: preferences.Options = { name: PREF_NAME };
    this.initPromise = preferences.getPreferences(this.context, opts)
      .then((prefs: preferences.Preferences) => {
        this.store = prefs;
        return;
      });
    await this.initPromise;
    return this.store!;
  }

  async getString(key: string): Promise<string | undefined> {
    const store = await this.ensureStore();
    const val = store.getSync(key, '');
    return val === '' ? undefined : String(val);
  }

  async getBoolean(key: string): Promise<boolean> {
    const store = await this.ensureStore();
    const val = store.getSync(key, false);
    return val === true;
  }

  /** When the key is absent, returns [defaultValue] (plain [getBoolean] defaults missing keys to false). */
  async getBooleanOr(key: string, defaultValue: boolean): Promise<boolean> {
    const store = await this.ensureStore();
    if (!store.hasSync(key)) {
      return defaultValue;
    }
    return store.getSync(key, false) === true;
  }

  async putBoolean(key: string, value: boolean): Promise<void> {
    const store = await this.ensureStore();
    store.putSync(key, value);
    await store.flush();
  }

  async putString(key: string, value: string): Promise<void> {
    const store = await this.ensureStore();
    store.putSync(key, value);
    await store.flush();
  }

  async remove(key: string): Promise<void> {
    const store = await this.ensureStore();
    store.deleteSync(key);
    await store.flush();
  }

  async clear(): Promise<void> {
    const store = await this.ensureStore();
    store.clearSync();
    await store.flush();
  }
}
