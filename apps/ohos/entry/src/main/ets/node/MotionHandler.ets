/**
 * Motion invoke handler: best-effort parity with Android activity and pedometer sampling.
 */
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import sensor from '@ohos.sensor';
import type { InvokeErrorShape, InvokeResult } from '../gateway/GatewaySession';

const ACCELEROMETER_SAMPLE_TARGET = 20;
const ACCELEROMETER_SAMPLE_TIMEOUT_MS = 6000;

type JsonValue = object | string | number | boolean | null | undefined;

interface MotionActivityRequest {
  startISO: string | null;
  endISO: string | null;
  limit: number;
}

interface MotionPedometerRequest {
  startISO: string | null;
  endISO: string | null;
}

interface MotionActivityRecord {
  startISO: string;
  endISO: string;
  confidence: string;
  isWalking: boolean;
  isRunning: boolean;
  isCycling: boolean;
  isAutomotive: boolean;
  isStationary: boolean;
  isUnknown: boolean;
}

interface PedometerRecord {
  startISO: string;
  endISO: string;
  steps?: number;
  distanceMeters?: number;
  floorsAscended?: number;
  floorsDescended?: number;
}

interface AccelerometerResponseShape {
  x: number;
  y: number;
  z: number;
}

interface PedometerResponseShape {
  steps: number;
}

interface AccelerometerSample {
  samples: number;
  averageDelta: number;
}

function invokeErr(code: string, message: string): InvokeResult {
  const error: InvokeErrorShape = { code, message };
  return { ok: false, payloadJson: null, error };
}

function invokeOk(payloadJson: string): InvokeResult {
  return { ok: true, payloadJson, error: null };
}

export class MotionHandler {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  static isActivityAvailable(): boolean {
    try {
      sensor.getSingleSensorSync(sensor.SensorId.ACCELEROMETER);
      return true;
    } catch {
      return false;
    }
  }

  static isPedometerAvailable(): boolean {
    try {
      sensor.getSingleSensorSync(sensor.SensorId.PEDOMETER);
      return true;
    } catch {
      return false;
    }
  }

  static isAvailable(): boolean {
    return MotionHandler.isActivityAvailable() || MotionHandler.isPedometerAvailable();
  }

  async handleMotionActivity(paramsJson: string | null): Promise<InvokeResult> {
    if (!this.hasPermission(['ohos.permission.ACTIVITY_MOTION'])) {
      return invokeErr(
        'MOTION_PERMISSION_REQUIRED',
        'MOTION_PERMISSION_REQUIRED: grant Motion permission',
      );
    }
    const request = this.parseActivityRequest(paramsJson);
    if (request === null) {
      return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: expected JSON object');
    }
    try {
      const activity = await this.readActivity(request);
      return invokeOk(JSON.stringify({ activities: [activity] }));
    } catch (error) {
      return invokeErr('MOTION_UNAVAILABLE', `MOTION_UNAVAILABLE: ${this.errorMessage(error)}`);
    }
  }

  async handleMotionPedometer(paramsJson: string | null): Promise<InvokeResult> {
    if (!this.hasPermission(['ohos.permission.ACTIVITY_MOTION'])) {
      return invokeErr(
        'MOTION_PERMISSION_REQUIRED',
        'MOTION_PERMISSION_REQUIRED: grant Motion permission',
      );
    }
    const request = this.parsePedometerRequest(paramsJson);
    if (request === null) {
      return invokeErr('INVALID_REQUEST', 'INVALID_REQUEST: expected JSON object');
    }
    try {
      const payload = await this.readPedometer(request);
      return invokeOk(JSON.stringify(payload));
    } catch (error) {
      return invokeErr('MOTION_UNAVAILABLE', `MOTION_UNAVAILABLE: ${this.errorMessage(error)}`);
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

  private parseActivityRequest(paramsJson: string | null): MotionActivityRequest | null {
    if (!paramsJson || paramsJson.trim().length === 0) {
      return { startISO: null, endISO: null, limit: 200 };
    }
    try {
      const root = JSON.parse(paramsJson) as Record<string, JsonValue>;
      const limitRaw = root['limit'];
      const limit = typeof limitRaw === 'number' && Number.isFinite(limitRaw)
        ? Math.max(1, Math.min(1000, Math.floor(limitRaw)))
        : 200;
      return {
        startISO: this.trimString(root['startISO']),
        endISO: this.trimString(root['endISO']),
        limit,
      };
    } catch {
      return null;
    }
  }

  private parsePedometerRequest(paramsJson: string | null): MotionPedometerRequest | null {
    if (!paramsJson || paramsJson.trim().length === 0) {
      return { startISO: null, endISO: null };
    }
    try {
      const root = JSON.parse(paramsJson) as Record<string, JsonValue>;
      return {
        startISO: this.trimString(root['startISO']),
        endISO: this.trimString(root['endISO']),
      };
    } catch {
      return null;
    }
  }

  private async readActivity(request: MotionActivityRequest): Promise<MotionActivityRecord> {
    if (request.startISO || request.endISO) {
      throw new Error('historical activity range not supported on HarmonyOS');
    }
    if (!MotionHandler.isActivityAvailable()) {
      throw new Error('accelerometer not available');
    }
    const sample = await this.readAccelerometerSample();
    const endMs = Date.now();
    const startMs = endMs - 2000;
    const classification = this.classifyActivity(sample.averageDelta);
    return {
      startISO: new Date(startMs).toISOString(),
      endISO: new Date(endMs).toISOString(),
      confidence: this.classifyConfidence(sample.samples, sample.averageDelta),
      isWalking: classification === 'walking',
      isRunning: classification === 'running',
      isCycling: false,
      isAutomotive: false,
      isStationary: classification === 'stationary',
      isUnknown: classification === 'unknown',
    };
  }

  private async readPedometer(request: MotionPedometerRequest): Promise<PedometerRecord> {
    if (request.startISO || request.endISO) {
      throw new Error('historical pedometer range not supported on HarmonyOS');
    }
    if (!MotionHandler.isPedometerAvailable()) {
      throw new Error('step counting not supported');
    }
    const response = await this.readPedometerOnce();
    const nowIso = new Date().toISOString();
    return {
      startISO: nowIso,
      endISO: nowIso,
      steps: response.steps,
    };
  }

  private async readPedometerOnce(): Promise<PedometerResponseShape> {
    return await new Promise<PedometerResponseShape>((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        reject(new Error('no pedometer sample'));
      }, 1500);
      try {
        sensor.once(sensor.SensorId.PEDOMETER, (data: PedometerResponseShape) => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timer);
          resolve(data);
        });
      } catch (error) {
        clearTimeout(timer);
        reject(error);
      }
    });
  }

  private async readAccelerometerSample(): Promise<AccelerometerSample> {
    return await new Promise<AccelerometerSample>((resolve, reject) => {
      let count = 0;
      let sumDelta = 0;
      let settled = false;
      const callback = (data: AccelerometerResponseShape): void => {
        const magnitude = Math.sqrt((data.x * data.x) + (data.y * data.y) + (data.z * data.z));
        sumDelta += Math.abs(magnitude - 9.80665);
        count += 1;
        if (count >= ACCELEROMETER_SAMPLE_TARGET) {
          cleanup();
          const sample: AccelerometerSample = {
            samples: count,
            averageDelta: sumDelta / count,
          };
          resolve(sample);
        }
      };
      const cleanup = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        try {
          sensor.off(sensor.SensorId.ACCELEROMETER, callback);
        } catch {
          // ignore unsubscribe failures
        }
      };
      const timer = setTimeout(() => {
        if (count > 0) {
          cleanup();
          const sample: AccelerometerSample = {
            samples: count,
            averageDelta: sumDelta / count,
          };
          resolve(sample);
          return;
        }
        cleanup();
        reject(new Error('no accelerometer sample'));
      }, ACCELEROMETER_SAMPLE_TIMEOUT_MS);
      try {
        sensor.on(sensor.SensorId.ACCELEROMETER, callback);
      } catch (error) {
        clearTimeout(timer);
        settled = true;
        reject(error);
      }
    });
  }

  private classifyActivity(averageDelta: number): string {
    if (averageDelta <= 0.55) {
      return 'stationary';
    }
    if (averageDelta <= 1.8) {
      return 'walking';
    }
    if (averageDelta > 1.8) {
      return 'running';
    }
    return 'unknown';
  }

  private classifyConfidence(samples: number, averageDelta: number): string {
    if (samples < 6) {
      return 'low';
    }
    if (samples >= 14 && averageDelta > 0.4) {
      return 'high';
    }
    return 'medium';
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
      return error.message.trim().length > 0 ? error.message : 'motion request failed';
    }
    if (typeof error === 'object' && error !== null) {
      const root = error as Record<string, JsonValue>;
      const message = typeof root['message'] === 'string' ? root['message'].trim() : '';
      if (message.length > 0) {
        return message;
      }
    }
    return 'motion request failed';
  }
}
