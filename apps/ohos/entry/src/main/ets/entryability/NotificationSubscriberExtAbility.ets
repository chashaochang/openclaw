/**
 * Notification subscriber extension: persists incoming notifications for node reads.
 */
import {
  NotificationSubscriberExtensionAbility,
} from '@kit.NotificationKit';
import { NotificationStore, sanitizeNotificationText, type StoredNotificationEntry } from '../node/NotificationStore';

interface NotificationContentShape {
  title: string;
  text: string;
}

interface NotificationInfoShape {
  hashCode: string;
  bundleName: string;
  content: NotificationContentShape;
  appName?: string;
  deliveryTime?: number;
  notificationSlotType: number;
}

function categoryForBundle(bundleName: string): string | undefined {
  const trimmed = bundleName.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

export default class NotificationSubscriberExtAbility extends NotificationSubscriberExtensionAbility {
  onReceiveMessage(notificationInfo: NotificationInfoShape): void {
    void this.upsertNotification(notificationInfo);
  }

  onCancelMessages(hashCodes: Array<string>): void {
    void this.removeNotifications(hashCodes);
  }

  private async upsertNotification(notificationInfo: NotificationInfoShape): Promise<void> {
    const store = new NotificationStore(this.context);
    const snapshot = await store.readSnapshot();
    const key = notificationInfo.hashCode.trim();
    const packageName = notificationInfo.bundleName.trim();
    if (key.length === 0 || packageName.length === 0) {
      return;
    }
    const nextEntry: StoredNotificationEntry = {
      key,
      packageName,
      title: sanitizeNotificationText(notificationInfo.content.title),
      text: sanitizeNotificationText(notificationInfo.content.text),
      subText: sanitizeNotificationText(notificationInfo.appName),
      category: categoryForBundle(packageName),
      channelId: sanitizeNotificationText(String(notificationInfo.notificationSlotType)),
      postTimeMs: notificationInfo.deliveryTime ?? Date.now(),
      isOngoing: false,
      isClearable: true,
    };
    const nextList = snapshot.notifications.filter((entry) => entry.key !== key);
    nextList.unshift(nextEntry);
    await store.writeSnapshot({
      enabled: true,
      connected: true,
      notifications: nextList,
    });
  }

  private async removeNotifications(hashCodes: Array<string>): Promise<void> {
    const keys: string[] = [];
    for (let i = 0; i < hashCodes.length; i++) {
      const key = hashCodes[i].trim();
      if (key.length > 0) {
        keys.push(key);
      }
    }
    if (keys.length === 0) {
      return;
    }
    const store = new NotificationStore(this.context);
    const snapshot = await store.readSnapshot();
    const nextList = snapshot.notifications.filter((entry) => !keys.includes(entry.key));
    await store.writeSnapshot({
      enabled: true,
      connected: true,
      notifications: nextList,
    });
  }
}
