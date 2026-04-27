/**
 * Notification forwarding policy helpers shared by runtime and settings UI.
 */

export interface NotificationForwardingPolicy {
  enabled: boolean;
  mode: NotificationPackageFilterMode;
  packages: string[];
  quietHoursEnabled: boolean;
  quietStart: string;
  quietEnd: string;
  maxEventsPerMinute: number;
  sessionKey: string | null;
}

export enum NotificationPackageFilterMode {
  Allowlist = 'allowlist',
  Blocklist = 'blocklist',
}

export function notificationPackageFilterModeFromRaw(raw: string | null | undefined): NotificationPackageFilterMode {
  const normalized = (raw ?? '').trim().toLowerCase();
  return normalized === NotificationPackageFilterMode.Allowlist
    ? NotificationPackageFilterMode.Allowlist
    : NotificationPackageFilterMode.Blocklist;
}

export function normalizeLocalHourMinute(raw: string): string | null {
  const match = raw.trim().match(/^(\d{1,2}):(\d{2})$/);
  if (!match) {
    return null;
  }
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (!Number.isInteger(hour) || !Number.isInteger(minute) || hour < 0 || hour > 23 || minute < 0 || minute > 59) {
    return null;
  }
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

function minutesSinceMidnight(raw: string): number | null {
  const normalized = normalizeLocalHourMinute(raw);
  if (!normalized) {
    return null;
  }
  const parts = normalized.split(':');
  const hours = parts[0];
  const minutes = parts[1];
  return Number(hours) * 60 + Number(minutes);
}

export function isWithinQuietHours(
  enabled: boolean,
  start: string,
  end: string,
  nowEpochMs: number,
): boolean {
  if (!enabled) {
    return false;
  }
  const startMinutes = minutesSinceMidnight(start);
  const endMinutes = minutesSinceMidnight(end);
  if (startMinutes === null || endMinutes === null) {
    return false;
  }
  const now = new Date(nowEpochMs);
  const currentMinutes = now.getHours() * 60 + now.getMinutes();
  if (startMinutes === endMinutes) {
    return true;
  }
  if (startMinutes < endMinutes) {
    return currentMinutes >= startMinutes && currentMinutes < endMinutes;
  }
  return currentMinutes >= startMinutes || currentMinutes < endMinutes;
}

export function allowsNotificationPackage(
  policy: NotificationForwardingPolicy,
  packageName: string,
): boolean {
  const normalized = packageName.trim();
  if (normalized.length === 0) {
    return false;
  }
  const configured = new Set<string>();
  for (let i = 0; i < policy.packages.length; i++) {
    const value = policy.packages[i].trim();
    if (value.length > 0) {
      configured.add(value);
    }
  }
  if (policy.mode === NotificationPackageFilterMode.Allowlist) {
    return configured.has(normalized);
  }
  return !configured.has(normalized);
}
