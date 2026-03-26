/**
 * Notification snapshot store shared by the UI ability and subscriber extension.
 */
import { common } from '@kit.AbilityKit';
import type { NotificationSubscriberExtensionContext } from '@kit.NotificationKit';
import { preferences } from '@kit.ArkData';

const PREF_NAME = 'openclaw_notifications';
const SNAPSHOT_KEY = 'snapshot.json';
const MAX_NOTIFICATION_TEXT_CHARS = 512;
const MAX_STORED_NOTIFICATIONS = 64;

type NotificationStoreContext = common.Context | NotificationSubscriberExtensionContext;

export interface StoredNotificationEntry {
  key: string;
  packageName: string;
  title?: string;
  text?: string;
  subText?: string;
  category?: string;
  channelId?: string;
  postTimeMs: number;
  isOngoing: boolean;
  isClearable: boolean;
}

export interface StoredNotificationSnapshot {
  enabled: boolean;
  connected: boolean;
  notifications: StoredNotificationEntry[];
}

interface StoredNotificationSnapshotJsonShape {
  enabled?: boolean;
  connected?: boolean;
  notifications?: StoredNotificationEntry[];
}

export function sanitizeNotificationText(value: string | undefined | null): string | undefined {
  const normalized = (value ?? '').trim();
  if (normalized.length === 0) {
    return undefined;
  }
  return normalized.substring(0, MAX_NOTIFICATION_TEXT_CHARS);
}

export class NotificationStore {
  private context: NotificationStoreContext;
  private store: preferences.Preferences | null = null;
  private initPromise: Promise<void> | null = null;

  constructor(context: NotificationStoreContext) {
    this.context = context;
  }

  async readSnapshot(): Promise<StoredNotificationSnapshot> {
    const store = await this.ensureStore();
    const raw = store.getSync(SNAPSHOT_KEY, '');
    if (typeof raw !== 'string' || raw.trim().length === 0) {
      return this.emptySnapshot(false, false);
    }
    try {
      const parsed = JSON.parse(raw) as StoredNotificationSnapshotJsonShape;
      const notifications = this.normalizeEntries(parsed.notifications);
      return {
        enabled: parsed.enabled === true,
        connected: parsed.connected === true,
        notifications,
      };
    } catch {
      return this.emptySnapshot(false, false);
    }
  }

  async writeSnapshot(snapshot: StoredNotificationSnapshot): Promise<void> {
    const store = await this.ensureStore();
    const normalized: StoredNotificationSnapshot = {
      enabled: snapshot.enabled === true,
      connected: snapshot.connected === true,
      notifications: this.normalizeEntries(snapshot.notifications),
    };
    store.putSync(SNAPSHOT_KEY, JSON.stringify(normalized));
    await store.flush();
  }

  async clear(): Promise<void> {
    const store = await this.ensureStore();
    store.deleteSync(SNAPSHOT_KEY);
    await store.flush();
  }

  emptySnapshot(enabled: boolean, connected: boolean): StoredNotificationSnapshot {
    return {
      enabled,
      connected,
      notifications: [],
    };
  }

  private normalizeEntries(entries: StoredNotificationEntry[] | undefined): StoredNotificationEntry[] {
    if (!entries || entries.length === 0) {
      return [];
    }
    const normalized: StoredNotificationEntry[] = [];
    for (let i = 0; i < entries.length && normalized.length < MAX_STORED_NOTIFICATIONS; i++) {
      const entry = entries[i];
      const key = (entry.key ?? '').trim();
      const packageName = (entry.packageName ?? '').trim();
      if (key.length === 0 || packageName.length === 0) {
        continue;
      }
      normalized.push({
        key,
        packageName,
        title: sanitizeNotificationText(entry.title),
        text: sanitizeNotificationText(entry.text),
        subText: sanitizeNotificationText(entry.subText),
        category: sanitizeNotificationText(entry.category),
        channelId: sanitizeNotificationText(entry.channelId),
        postTimeMs: Number.isFinite(entry.postTimeMs) ? entry.postTimeMs : Date.now(),
        isOngoing: entry.isOngoing === true,
        isClearable: entry.isClearable === true,
      });
    }
    normalized.sort((left, right) => right.postTimeMs - left.postTimeMs);
    return normalized;
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
}
