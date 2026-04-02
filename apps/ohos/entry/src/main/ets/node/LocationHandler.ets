/**
 * Location invoke handler: matches Android location.get behavior as closely as HarmonyOS allows.
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import type { InvokeErrorShape, InvokeResult } from '../gateway/GatewaySession';

type JsonRec = Record<string, object | string | number | boolean | null>;
type SafeValue = object | string | number | boolean | null | undefined;

interface ParsedLocationParams {
  maxAgeMs: number | null;
  timeoutMs: number;
  desiredAccuracy: string | null;
}

interface LocationFixShape {
  latitude?: number;
  longitude?: number;
  accuracy?: number;
  altitude?: number;
  speed?: number;
  direction?: number;
  timeStamp?: number;
  timestamp?: number;
}

interface LocationPayloadShape {
  lat: number;
  lon: number;
  accuracyMeters: number;
  timestamp: string;
  isPrecise: boolean;
  source: string;
  altitudeMeters?: number;
  speedMps?: number;
  headingDeg?: number;
}

interface CurrentLocationRequestShape {
  priority: number;
  scenario: number;
  maxAccuracy: number;
  timeoutMs: number;
}

interface ErrorLikeShape {
  message?: string;
  code?: string | number;
}

function invokeErr(code: string, message: string): InvokeResult {
  const error: InvokeErrorShape = { code, message };
  return { ok: false, payloadJson: null, error };
}

function invokeOk(payloadJson: string): InvokeResult {
  return { ok: true, payloadJson, error: null };
}

function isoTimestamp(epochMs: number): string {
  try {
    return new Date(epochMs).toISOString();
  } catch {
    return new Date().toISOString();
  }
}

function toFiniteNumber(value: SafeValue): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

export class LocationHandler {
  private context: common.UIAbilityContext;
  private isForeground: () => boolean;
  private locationPreciseEnabled: () => boolean;

  constructor(
    context: common.UIAbilityContext,
    isForeground: () => boolean,
    locationPreciseEnabled: () => boolean,
  ) {
    this.context = context;
    this.isForeground = isForeground;
    this.locationPreciseEnabled = locationPreciseEnabled;
  }

  hasFineLocationPermission(): boolean {
    return this.hasAnyPermission(['ohos.permission.LOCATION']);
  }

  hasCoarseLocationPermission(): boolean {
    return this.hasAnyPermission(['ohos.permission.APPROXIMATELY_LOCATION']);
  }

  async handleLocationGet(paramsJson: string | null): Promise<InvokeResult> {
    if (!this.isForeground()) {
      return invokeErr(
        'LOCATION_BACKGROUND_UNAVAILABLE',
        'LOCATION_BACKGROUND_UNAVAILABLE: location requires OpenClaw to stay open',
      );
    }
    const fineGranted = this.hasFineLocationPermission();
    const coarseGranted = this.hasCoarseLocationPermission();
    if (!fineGranted && !coarseGranted) {
      return invokeErr(
        'LOCATION_PERMISSION_REQUIRED',
        'LOCATION_PERMISSION_REQUIRED: grant Location permission',
      );
    }

    const parsed = this.parseLocationParams(paramsJson);
    const isPrecise = this.resolvePreciseMode(
      parsed.desiredAccuracy,
      fineGranted,
      this.locationPreciseEnabled(),
    );
    const request = this.buildLocationRequest(parsed.timeoutMs, isPrecise);

    try {
      const raw = await geoLocationManager.getCurrentLocation(request) as LocationFixShape;
      const lat = toFiniteNumber(raw?.latitude);
      const lon = toFiniteNumber(raw?.longitude);
      const accuracyMeters = toFiniteNumber(raw?.accuracy);
      if (lat === null || lon === null || accuracyMeters === null) {
        return invokeErr(
          'LOCATION_UNAVAILABLE',
          'LOCATION_UNAVAILABLE: invalid location fix',
        );
      }
      const timestampMs =
        toFiniteNumber(raw?.timeStamp) ??
        toFiniteNumber(raw?.timestamp) ??
        Date.now();
      const payload: LocationPayloadShape = {
        lat,
        lon,
        accuracyMeters,
        timestamp: isoTimestamp(timestampMs),
        isPrecise,
        source: 'harmony',
      };
      const altitudeMeters = toFiniteNumber(raw?.altitude);
      if (altitudeMeters !== null) {
        payload.altitudeMeters = altitudeMeters;
      }
      const speedMps = toFiniteNumber(raw?.speed);
      if (speedMps !== null) {
        payload.speedMps = speedMps;
      }
      const headingDeg = toFiniteNumber(raw?.direction);
      if (headingDeg !== null) {
        payload.headingDeg = headingDeg;
      }
      return invokeOk(JSON.stringify(payload));
    } catch (error) {
      const message = this.errorMessage(error);
      const upper = message.toUpperCase();
      if (upper.includes('TIMEOUT')) {
        return invokeErr('LOCATION_TIMEOUT', 'LOCATION_TIMEOUT: no fix in time');
      }
      if (upper.includes('PERMISSION')) {
        return invokeErr(
          'LOCATION_PERMISSION_REQUIRED',
          'LOCATION_PERMISSION_REQUIRED: grant Location permission',
        );
      }
      if (upper.includes('SWITCH') || upper.includes('PROVIDER') || upper.includes('DISABLED')) {
        return invokeErr(
          'LOCATION_UNAVAILABLE',
          'LOCATION_UNAVAILABLE: no location providers enabled',
        );
      }
      return invokeErr(
        'LOCATION_UNAVAILABLE',
        `LOCATION_UNAVAILABLE: ${message}`,
      );
    }
  }

  private hasAnyPermission(permissionNames: Permissions[]): boolean {
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

  private parseLocationParams(paramsJson: string | null): ParsedLocationParams {
    const fallback: ParsedLocationParams = {
      maxAgeMs: null,
      timeoutMs: 10_000,
      desiredAccuracy: null,
    };
    if (!paramsJson || paramsJson.trim().length === 0) {
      return fallback;
    }
    try {
      const root = JSON.parse(paramsJson) as JsonRec;
      const timeoutRaw = root['timeoutMs'];
      const maxAgeRaw = root['maxAgeMs'];
      const desiredAccuracyRaw = root['desiredAccuracy'];
      return {
        maxAgeMs: typeof maxAgeRaw === 'number' && Number.isFinite(maxAgeRaw) ? maxAgeRaw : null,
        timeoutMs: typeof timeoutRaw === 'number' && Number.isFinite(timeoutRaw)
          ? Math.max(1000, Math.min(60_000, Math.floor(timeoutRaw)))
          : 10_000,
        desiredAccuracy: typeof desiredAccuracyRaw === 'string'
          ? desiredAccuracyRaw.trim().toLowerCase()
          : null,
      };
    } catch {
      return fallback;
    }
  }

  private resolvePreciseMode(
    desiredAccuracy: string | null,
    fineGranted: boolean,
    preciseEnabled: boolean,
  ): boolean {
    if (desiredAccuracy === 'coarse') {
      return false;
    }
    if (desiredAccuracy === 'precise') {
      return preciseEnabled && fineGranted;
    }
    return preciseEnabled && fineGranted;
  }

  private buildLocationRequest(timeoutMs: number, isPrecise: boolean): geoLocationManager.CurrentLocationRequest {
    const request: CurrentLocationRequestShape = {
      priority: geoLocationManager.LocationRequestPriority.FIRST_FIX as number,
      scenario: geoLocationManager.LocationRequestScenario.UNSET as number,
      maxAccuracy: isPrecise ? 100 : 5000,
      timeoutMs,
    };
    return request as geoLocationManager.CurrentLocationRequest;
  }

  private errorMessage(error: SafeValue): string {
    if (error instanceof Error) {
      return error.message.trim().length > 0 ? error.message : 'location unavailable';
    }
    if (typeof error === 'object' && error !== null) {
      const root = error as ErrorLikeShape;
      const message = typeof root.message === 'string' ? root.message : '';
      if (message.trim().length > 0) {
        return message;
      }
      const code = root.code;
      if (typeof code === 'number' || typeof code === 'string') {
        return String(code);
      }
    }
    return String(error ?? 'location unavailable');
  }
}
