/**
 * Calendar invoke handler: read upcoming events using Harmony calendar APIs.
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import calendarManager from '@ohos.calendarManager';
import type { InvokeErrorShape, InvokeResult } from '../gateway/GatewaySession';

const DEFAULT_CALENDAR_LIMIT = 50;
const DEFAULT_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

type JsonValue = object | string | number | boolean | null | undefined;

interface CalendarEventsRequest {
  startMs: number;
  endMs: number;
  limit: number;
}

interface CalendarAddRequest {
  title: string;
  startMs: number;
  endMs: number;
  isAllDay: boolean;
  location: string | null;
  notes: string | null;
  calendarId: number | null;
  calendarTitle: string | null;
}

interface CalendarEventRecord {
  identifier: string;
  title: string;
  startMs: number;
  endMs: number;
  isAllDay: boolean;
  location: string | null;
  calendarTitle: string | null;
}

interface CalendarEventPayload {
  identifier: string;
  title: string;
  startISO: string;
  endISO: string;
  isAllDay: boolean;
  location?: string;
  calendarTitle?: string;
}

interface CalendarAccountShape {
  name?: string;
  displayName?: string;
}

interface CalendarLike {
  id: number;
  getAccount(): CalendarAccountShape;
  addEvent(event: CalendarWriteEventShape): Promise<number>;
  getEvents(eventFilter?: object, eventKey?: string[]): Promise<CalendarEventShape[]>;
  queryEventInstances?: (
    start: number,
    end: number,
    ids?: number[],
    eventKey?: string[],
  ) => Promise<CalendarEventShape[]>;
}

interface CalendarEventShape {
  id?: number;
  identifier?: string;
  title?: string;
  location?: CalendarLocationShape;
  startTime: number;
  endTime: number;
  instanceStartTime?: number;
  instanceEndTime?: number;
  isAllDay?: boolean;
}

interface CalendarLocationShape {
  location?: string;
}

interface CalendarWriteEventShape {
  type: number;
  title?: string;
  location?: CalendarLocationShape;
  startTime: number;
  endTime: number;
  isAllDay?: boolean;
  timeZone?: string;
  description?: string;
}

interface CalendarTargetSelection {
  calendar: CalendarLike;
  title: string | null;
}

function invokeErr(code: string, message: string): InvokeResult {
  const error: InvokeErrorShape = { code, message };
  return { ok: false, payloadJson: null, error };
}

function invokeOk(payloadJson: string): InvokeResult {
  return { ok: true, payloadJson, error: null };
}

function clampLimit(limit: number): number {
  return Math.max(1, Math.min(500, Math.floor(limit)));
}

function isoTimestamp(epochMs: number): string {
  try {
    return new Date(epochMs).toISOString();
  } catch {
    return new Date().toISOString();
  }
}

function parseIsoMs(raw: JsonValue): number | null {
  if (typeof raw !== 'string') {
    return null;
  }
  const value = raw.trim();
  if (value.length === 0) {
    return null;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function eventToPayload(event: CalendarEventRecord): CalendarEventPayload {
  const payload: CalendarEventPayload = {
    identifier: event.identifier,
    title: event.title,
    startISO: isoTimestamp(event.startMs),
    endISO: isoTimestamp(event.endMs),
    isAllDay: event.isAllDay,
  };
  if (event.location) {
    payload.location = event.location;
  }
  if (event.calendarTitle) {
    payload.calendarTitle = event.calendarTitle;
  }
  return payload;
}

export class CalendarHandler {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async handleCalendarEvents(paramsJson: string | null): Promise<InvokeResult> {
    if (!this.hasPermission(['ohos.permission.READ_CALENDAR'])) {
      return invokeErr(
        'CALENDAR_PERMISSION_REQUIRED',
        'CALENDAR_PERMISSION_REQUIRED: grant Calendar permission',
      );
    }

    const request = this.parseEventsRequest(paramsJson);
    if (request === null) {
      return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: expected JSON object');
    }
    if (request.endMs <= request.startMs) {
      return invokeErr(
        'CALENDAR_INVALID',
        'CALENDAR_INVALID: endISO must be after startISO',
      );
    }

    try {
      const events = await this.queryEvents(request);
      return invokeOk(JSON.stringify({
        events: events.map((item) => eventToPayload(item)),
      }));
    } catch (error) {
      const message = this.errorMessage(error);
      return invokeErr('CALENDAR_UNAVAILABLE', `CALENDAR_UNAVAILABLE: ${message}`);
    }
  }

  async handleCalendarAdd(paramsJson: string | null): Promise<InvokeResult> {
    if (!this.hasPermission(['ohos.permission.WRITE_CALENDAR'])) {
      return invokeErr(
        'CALENDAR_PERMISSION_REQUIRED',
        'CALENDAR_PERMISSION_REQUIRED: grant Calendar permission',
      );
    }

    const request = this.parseAddRequest(paramsJson);
    if (request === null) {
      return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: expected JSON object');
    }
    if (request.title.length === 0) {
      return invokeErr('CALENDAR_INVALID', 'CALENDAR_INVALID: title required');
    }
    if (request.endMs <= request.startMs) {
      return invokeErr(
        'CALENDAR_INVALID',
        'CALENDAR_INVALID: endISO must be after startISO',
      );
    }

    try {
      const event = await this.addEvent(request);
      return invokeOk(JSON.stringify({ event: eventToPayload(event) }));
    } catch (error) {
      const message = this.errorMessage(error);
      const code = message.startsWith('CALENDAR_NOT_FOUND') ? 'CALENDAR_NOT_FOUND' : 'CALENDAR_UNAVAILABLE';
      return invokeErr(code, `${code}: ${message}`);
    }
  }

  private hasPermission(permissionNames: Permissions[]): boolean {
    const atManager = abilityAccessCtrl.createAtManager();
    const tokenId = this.context.applicationInfo.accessTokenId;
    for (let i = 0; i < permissionNames.length; i++) {
      try {
        const status = atManager.checkAccessTokenSync(tokenId, permissionNames[i]);
        if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          return true;
        }
      } catch {
        // Ignore unsupported permission names on some builds.
      }
    }
    return false;
  }

  private parseEventsRequest(paramsJson: string | null): CalendarEventsRequest | null {
    const now = Date.now();
    if (!paramsJson || paramsJson.trim().length === 0) {
      return {
        startMs: now,
        endMs: now + DEFAULT_WINDOW_MS,
        limit: DEFAULT_CALENDAR_LIMIT,
      };
    }
    try {
      const root = JSON.parse(paramsJson) as Record<string, JsonValue>;
      const startMs = parseIsoMs(root['startISO']) ?? now;
      const endMs = parseIsoMs(root['endISO']) ?? (startMs + DEFAULT_WINDOW_MS);
      const limitRaw = root['limit'];
      const limit = typeof limitRaw === 'number' && Number.isFinite(limitRaw)
        ? clampLimit(limitRaw)
        : DEFAULT_CALENDAR_LIMIT;
      return {
        startMs,
        endMs,
        limit,
      };
    } catch {
      return null;
    }
  }

  private parseAddRequest(paramsJson: string | null): CalendarAddRequest | null {
    try {
      const root = JSON.parse(paramsJson ?? '') as Record<string, JsonValue>;
      const startMs = parseIsoMs(root['startISO']);
      const endMs = parseIsoMs(root['endISO']);
      if (startMs === null || endMs === null) {
        return null;
      }
      const calendarIdRaw = root['calendarId'];
      return {
        title: this.trimString(root['title']) ?? '',
        startMs,
        endMs,
        isAllDay: root['isAllDay'] === true,
        location: this.trimString(root['location']),
        notes: this.trimString(root['notes']),
        calendarId: typeof calendarIdRaw === 'number' && Number.isFinite(calendarIdRaw)
          ? Math.floor(calendarIdRaw)
          : null,
        calendarTitle: this.trimString(root['calendarTitle']),
      };
    } catch {
      return null;
    }
  }

  private async queryEvents(request: CalendarEventsRequest): Promise<CalendarEventRecord[]> {
    const manager = calendarManager.getCalendarManager(this.context);
    const calendars = (await manager.getAllCalendars()) as CalendarLike[];
    if (calendars.length === 0) {
      return [];
    }

    const records: CalendarEventRecord[] = [];
    for (let i = 0; i < calendars.length; i++) {
      const calendar = calendars[i];
      const account = calendar.getAccount();
      const calendarTitle = this.normalizeCalendarTitle(account);
      const items = await this.queryCalendarInstances(calendar, request.startMs, request.endMs);
      for (let j = 0; j < items.length; j++) {
        const mapped = this.mapEvent(items[j], calendar.id, calendarTitle);
        if (mapped === null) {
          continue;
        }
        if (mapped.endMs <= request.startMs || mapped.startMs >= request.endMs) {
          continue;
        }
        records.push(mapped);
      }
    }

    records.sort((a, b) => {
      if (a.startMs !== b.startMs) {
        return a.startMs - b.startMs;
      }
      if (a.endMs !== b.endMs) {
        return a.endMs - b.endMs;
      }
      return a.title.localeCompare(b.title);
    });

    const deduped: CalendarEventRecord[] = [];
    const seen = new Set<string>();
    for (let i = 0; i < records.length; i++) {
      const item = records[i];
      const key = `${item.identifier}#${item.startMs}#${item.endMs}`;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      deduped.push(item);
      if (deduped.length >= request.limit) {
        break;
      }
    }
    return deduped;
  }

  private async addEvent(request: CalendarAddRequest): Promise<CalendarEventRecord> {
    const manager = calendarManager.getCalendarManager(this.context);
    const calendars = (await manager.getAllCalendars()) as CalendarLike[];
    const target = this.resolveTargetCalendar(calendars, request);
    let location: CalendarLocationShape | undefined = undefined;
    if (request.location) {
      const shape: CalendarLocationShape = { location: request.location };
      location = shape;
    }
    const event: CalendarWriteEventShape = {
      type: calendarManager.EventType.NORMAL,
      title: request.title,
      startTime: request.startMs,
      endTime: request.endMs,
      isAllDay: request.isAllDay,
      location,
      description: request.notes ?? undefined,
      timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    };
    const eventId = await target.calendar.addEvent(event);
    return {
      identifier: String(eventId),
      title: request.title,
      startMs: request.startMs,
      endMs: request.endMs,
      isAllDay: request.isAllDay,
      location: request.location,
      calendarTitle: target.title,
    };
  }

  private async queryCalendarInstances(
    calendar: CalendarLike,
    startMs: number,
    endMs: number,
  ): Promise<CalendarEventShape[]> {
    if (calendar.queryEventInstances) {
      return await calendar.queryEventInstances(startMs, endMs);
    }
    const filter = calendarManager.EventFilter.filterByTime(startMs, endMs);
    return await calendar.getEvents(filter);
  }

  private mapEvent(
    raw: CalendarEventShape,
    calendarId: number,
    calendarTitle: string | null,
  ): CalendarEventRecord | null {
    const startMs = Number.isFinite(raw.instanceStartTime) ? raw.instanceStartTime as number : raw.startTime;
    const endMs = Number.isFinite(raw.instanceEndTime) ? raw.instanceEndTime as number : raw.endTime;
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs)) {
      return null;
    }
    const title = (raw.title ?? '').trim() || '(untitled)';
    const location = (raw.location?.location ?? '').trim() || null;
    const baseIdentifier = (raw.identifier ?? '').trim();
    const identifier = baseIdentifier.length > 0
      ? baseIdentifier
      : `${calendarId}:${String(raw.id ?? startMs)}:${String(endMs)}`;
    return {
      identifier,
      title,
      startMs,
      endMs,
      isAllDay: raw.isAllDay === true,
      location,
      calendarTitle,
    };
  }

  private normalizeCalendarTitle(account: CalendarAccountShape): string | null {
    const displayName = (account.displayName ?? '').trim();
    if (displayName.length > 0) {
      return displayName;
    }
    const name = (account.name ?? '').trim();
    return name.length > 0 ? name : null;
  }

  private resolveTargetCalendar(
    calendars: CalendarLike[],
    request: CalendarAddRequest,
  ): CalendarTargetSelection {
    if (calendars.length === 0) {
      throw new Error('CALENDAR_NOT_FOUND: no default calendar');
    }
    if (request.calendarId !== null) {
      for (let i = 0; i < calendars.length; i++) {
        if (calendars[i].id === request.calendarId) {
          const resolved: CalendarTargetSelection = {
            calendar: calendars[i],
            title: this.normalizeCalendarTitle(calendars[i].getAccount()),
          };
          return resolved;
        }
      }
      throw new Error(`CALENDAR_NOT_FOUND: no calendar id ${String(request.calendarId)}`);
    }
    if (request.calendarTitle) {
      const needle = request.calendarTitle.toLowerCase();
      for (let i = 0; i < calendars.length; i++) {
        const title = this.normalizeCalendarTitle(calendars[i].getAccount());
        if (title && title.toLowerCase() === needle) {
          const resolved: CalendarTargetSelection = { calendar: calendars[i], title };
          return resolved;
        }
      }
      throw new Error(`CALENDAR_NOT_FOUND: no calendar named ${request.calendarTitle}`);
    }
    const fallback: CalendarTargetSelection = {
      calendar: calendars[0],
      title: this.normalizeCalendarTitle(calendars[0].getAccount()),
    };
    return fallback;
  }

  private trimString(raw: JsonValue): string | null {
    if (typeof raw !== 'string') {
      return null;
    }
    const value = raw.trim();
    return value.length > 0 ? value : null;
  }

  private errorMessage(error: JsonValue): string {
    if (error instanceof Error) {
      return error.message.trim().length > 0 ? error.message : 'calendar query failed';
    }
    if (typeof error === 'object' && error !== null) {
      const root = error as Record<string, JsonValue>;
      const message = typeof root['message'] === 'string' ? root['message'].trim() : '';
      if (message.length > 0) {
        return message;
      }
      const code = root['code'];
      if (typeof code === 'number' || typeof code === 'string') {
        return String(code);
      }
    }
    return 'calendar query failed';
  }
}
