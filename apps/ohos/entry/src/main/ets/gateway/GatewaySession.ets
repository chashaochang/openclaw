/**
 * Gateway WebSocket session: connect, RPC, events, invoke.
 *
 * Uses @ohos-rs/websocket (Rust/tokio-tungstenite) instead of @kit.NetworkKit
 * to avoid HarmonyOS platform forcing Origin header, which triggers gateway
 * origin check and causes "origin not allowed" rejection.
 */
import { WebSocket, WebSocketConfig } from '@ohos-rs/websocket';
import { i18n } from '@kit.LocalizationKit';
import { GATEWAY_PROTOCOL_VERSION } from '../protocol/OpenClawProtocol';
import { buildV3 } from './DeviceAuthPayload';
import { buildWsUrl, GatewayEndpoint } from './GatewayEndpoint';
import { normalizeCanvasHostUrl, replaceCanvasCapabilityInScopedHostUrl } from './CanvasHostUrl';
import { DeviceIdentityStore, DeviceIdentity } from './DeviceIdentityStore';
import { DeviceAuthStore } from './DeviceAuthStore';
import { DeviceAuthTokenStore } from './DeviceAuthStore';

const CONNECT_RPC_TIMEOUT_MS = 12000;
const ROLE = 'node';

export interface GatewayClientInfo {
  id: string;
  displayName?: string;
  version: string;
  platform: string;
  mode: string;
  instanceId?: string;
  deviceFamily?: string;
  modelIdentifier?: string;
}

export interface GatewayPermissions {
  camera?: boolean;
  location?: boolean;
  microphone?: boolean;
}

export interface GatewayConnectOptions {
  role: string;
  scopes: string[];
  caps: string[];
  commands: string[];
  permissions: GatewayPermissions;
  client: GatewayClientInfo;
  userAgent?: string;
}

export interface InvokeRequest {
  id: string;
  nodeId: string;
  command: string;
  paramsJson: string | null;
  timeoutMs?: number;
}

export interface InvokeErrorShape {
  code: string;
  message: string;
}

export interface InvokeResult {
  ok: boolean;
  payloadJson: string | null;
  error: InvokeErrorShape | null;
}

function invokeOk(payload: string | null): InvokeResult {
  const r: InvokeResult = { ok: true, payloadJson: payload, error: null };
  return r;
}

function invokeError(code: string, message: string): InvokeResult {
  const err: InvokeErrorShape = { code, message };
  const r: InvokeResult = { ok: false, payloadJson: null, error: err };
  return r;
}

type OnConnected = (serverName: string | null, remoteAddress: string, mainSessionKey: string | null) => void;
type OnDisconnected = (message: string) => void;
type OnEvent = (event: string, payloadJson: string | null) => void;
type OnInvoke = (req: InvokeRequest) => Promise<InvokeResult>;
type OnTlsFingerprint = (stableId: string, fingerprint: string) => void;

interface PendingRpc {
  resolve: (r: RpcResponse) => void;
  reject: (err: Error) => void;
  timeoutId: number;
}

interface RpcResponse {
  id: string;
  ok: boolean;
  payloadJson: string | null;
  error: InvokeErrorShape | null;
}

type JsonValue = string | number | boolean | object | null;
type JsonRecord = Record<string, JsonValue>;

interface DeviceJsonShape {
  id: string;
  publicKey: string;
  signature: string;
  signedAt: number;
  nonce: string;
}

interface ClientParamsShape {
  id: string;
  displayName?: string;
  version: string;
  platform: string;
  mode: string;
  instanceId?: string;
  deviceFamily?: string;
  modelIdentifier?: string;
}

interface ConnectParamsShape {
  minProtocol: number;
  maxProtocol: number;
  client: ClientParamsShape;
  role: string;
  scopes: string[];
  caps: string[];
  commands: string[];
  permissions: GatewayPermissions;
  locale: string;
  auth?: JsonRecord;
  device?: DeviceJsonShape;
  userAgent?: string;
}

interface ReqFrame {
  type: string;
  id: string;
  method: string;
  params?: JsonRecord;
}

function randomId(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

function arrayBufferToString(buf: ArrayBuffer): string {
  const arr = new Uint8Array(buf);
  let result = '';
  for (let i = 0; i < arr.length; i++) {
    result += String.fromCharCode(arr[i]);
  }
  return result;
}

export class GatewaySession {
  private ws: WebSocket | null = null;
  private pending = new Map<string, PendingRpc>();
  private connectNonceResolve: ((n: string) => void) | null = null;
  private connectNonceReject: ((e: Error) => void) | null = null;
  private connectDeferredResolve: (() => void) | null = null;
  private connectDeferredReject: ((e: Error) => void) | null = null;
  private closed = false;
  private connectSucceeded = false;
  private mainSessionKey: string | null = null;
  private canvasHostUrl: string | null = null;
  private runLoopAbort = false;
  private identityStore: DeviceIdentityStore;
  private deviceAuthStore: DeviceAuthTokenStore;
  private onConnected: OnConnected;
  private onDisconnected: OnDisconnected;
  private onEvent: OnEvent;
  private onInvoke: OnInvoke | null;
  private onTlsFingerprint: OnTlsFingerprint | null;

  constructor(
    identityStore: DeviceIdentityStore,
    deviceAuthStore: DeviceAuthTokenStore,
    onConnected: OnConnected,
    onDisconnected: OnDisconnected,
    onEvent: OnEvent,
    onInvoke: OnInvoke | null,
    onTlsFingerprint: OnTlsFingerprint | null,
  ) {
    this.identityStore = identityStore;
    this.deviceAuthStore = deviceAuthStore;
    this.onConnected = onConnected;
    this.onDisconnected = onDisconnected;
    this.onEvent = onEvent;
    this.onInvoke = onInvoke;
    this.onTlsFingerprint = onTlsFingerprint;
  }

  async connect(
    endpoint: GatewayEndpoint,
    token: string | null,
    password: string | null,
    options: GatewayConnectOptions,
    certPath: string | null = null,
  ): Promise<void> {
    this.runLoopAbort = false;
    this.connectSucceeded = false;
    const url = buildWsUrl(endpoint);
    const remoteAddress = endpoint.host.includes(':')
      ? `[${endpoint.host}]:${endpoint.port}`
      : `${endpoint.host}:${endpoint.port}`;

    return new Promise<void>((resolve, reject) => {
      this.connectDeferredResolve = resolve;
      this.connectDeferredReject = reject;

      try {
        // Empty headers: native Rust impl does not add Origin (unlike platform API).
        const headers: Record<string, string> = {};
        const config: WebSocketConfig = { headers };
        if (certPath && certPath.trim().length > 0) {
          config.certPath = certPath.trim();
        }
        this.ws = new WebSocket(url, config);
        this.ws.onOpen(() => {
          this.handleOpen(endpoint, token, password, options, remoteAddress)
            .then(() => {
              this.connectDeferredResolve?.();
              this.connectDeferredResolve = null;
              this.connectDeferredReject = null;
            })
            .catch((err: Error) => {
              this.connectDeferredReject?.(err);
              this.connectDeferredResolve = null;
              this.connectDeferredReject = null;
            });
        });
        this.ws.onMessage((data: string | ArrayBuffer) => {
          const text = typeof data === 'string' ? data : arrayBufferToString(data);
          if (text) this.handleMessage(text);
        });
        this.ws.onClose(() => {
          if (this.connectSucceeded) {
            this.handleClose('Offline');
          }
        });
        this.ws.onError((err: Error) => {
          this.handleClose(`Gateway error: ${err?.message ?? 'unknown'}`);
        });
        this.ws.connect().catch((err: Error) => {
          this.connectDeferredReject?.(new Error(err?.message ?? 'connect failed'));
          this.connectDeferredResolve = null;
          this.connectDeferredReject = null;
        });
      } catch (e) {
        reject(e instanceof Error ? e : new Error(String(e)));
      }
    });
  }

  private async handleOpen(
    endpoint: GatewayEndpoint,
    token: string | null,
    password: string | null,
    options: GatewayConnectOptions,
    remoteAddress: string
  ): Promise<void> {
    const nonce = await this.awaitConnectNonce();
    const identity = await this.identityStore.loadOrCreate();
    const storedToken = await this.deviceAuthStore.loadToken(identity.deviceId, options.role);
    const authToken = (token?.trim() ?? '').length > 0 ? token!.trim() : (storedToken ?? '');
    const payload = await this.buildConnectParams(identity, nonce, authToken, password?.trim() ?? null, options);

    const res = await this.request('connect', payload, CONNECT_RPC_TIMEOUT_MS);
    if (!res.ok) {
      throw new Error(res.error?.message ?? 'connect failed');
    }
    await this.handleConnectSuccess(res.payloadJson, endpoint, options.role, identity.deviceId);
    this.connectSucceeded = true;
    this.onConnected(null, remoteAddress, this.mainSessionKey);
  }

  private async handleConnectSuccess(
    payloadJson: string | null,
    endpoint: GatewayEndpoint,
    role: string,
    deviceId: string
  ): Promise<void> {
    if (!payloadJson) throw new Error('connect failed: missing payload');
    const obj = JSON.parse(payloadJson) as JsonRecord;
    const authObj = obj['auth'] as JsonRecord | null;
    const deviceToken = authObj ? (authObj['deviceToken'] as string) : '';
    if (deviceToken) {
      await this.deviceAuthStore.saveToken(deviceId, role, deviceToken);
    }
    const snapshot = obj['snapshot'] as JsonRecord | null;
    const sessionDefaults = snapshot ? (snapshot['sessionDefaults'] as JsonRecord) : null;
    this.mainSessionKey = sessionDefaults ? ((sessionDefaults['mainSessionKey'] as string) ?? null) : null;
    const rawCanvas = obj['canvasHostUrl'] as string | undefined;
    this.canvasHostUrl = normalizeCanvasHostUrl(rawCanvas ?? null, endpoint);
  }

  private async buildConnectParams(
    identity: DeviceIdentity,
    connectNonce: string,
    authToken: string,
    authPassword: string | null,
    options: GatewayConnectOptions,
    didRetry = false
  ): Promise<JsonRecord> {
    const client = options.client;
    const signedAtMs = Date.now();
    const payload = buildV3(
      identity.deviceId,
      client.id,
      client.mode,
      options.role,
      options.scopes,
      signedAtMs,
      authToken || null,
      connectNonce,
      client.platform,
      client.deviceFamily
    );
    const signature = await this.identityStore.signPayload(payload, identity);
    const publicKey = this.identityStore.publicKeyBase64Url(identity);

    if ((!signature || !publicKey) && !didRetry) {
      await this.identityStore.clearStored();
      const fresh = await this.identityStore.loadOrCreate();
      return this.buildConnectParams(fresh, connectNonce, authToken, authPassword, options, true);
    }

    let deviceJson: DeviceJsonShape | null = null;
    if (signature && publicKey) {
      const dev: DeviceJsonShape = {
        id: identity.deviceId,
        publicKey,
        signature,
        signedAt: signedAtMs,
        nonce: connectNonce,
      };
      deviceJson = dev;
    }

    let authJson: JsonRecord | null = null;
    if (authToken) {
      const a: JsonRecord = {};
      a['token'] = authToken;
      authJson = a;
    } else if (authPassword) {
      const a: JsonRecord = {};
      a['password'] = authPassword;
      authJson = a;
    }

    const clientParams: ClientParamsShape = {
      id: client.id,
      displayName: client.displayName,
      version: client.version,
      platform: client.platform,
      mode: client.mode,
      instanceId: client.instanceId,
      deviceFamily: client.deviceFamily,
      modelIdentifier: client.modelIdentifier,
    };
    let locale = 'zh-CN';
    try {
      locale = i18n.System.getSystemLocale();
    } catch (_) {
      // fallback if i18n unavailable
    }
    const out: JsonRecord = {};
    out['minProtocol'] = GATEWAY_PROTOCOL_VERSION;
    out['maxProtocol'] = GATEWAY_PROTOCOL_VERSION;
    out['client'] = clientParams;
    out['role'] = options.role;
    if (options.caps.length > 0) out['caps'] = options.caps;
    if (options.commands.length > 0) out['commands'] = options.commands;
    if (Object.keys(options.permissions).length > 0) out['permissions'] = options.permissions;
    if (options.scopes.length > 0) out['scopes'] = options.scopes;
    out['locale'] = locale;
    if (authJson) out['auth'] = authJson;
    if (deviceJson) out['device'] = deviceJson;
    const ua = options.userAgent?.trim();
    if (ua && ua.length > 0) out['userAgent'] = ua;
    return out;
  }

  private awaitConnectNonce(): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const t = setTimeout(() => {
        reject(new Error('connect challenge timeout'));
      }, 2000);
      this.connectNonceResolve = (n: string) => {
        clearTimeout(t);
        resolve(n);
      };
      this.connectNonceReject = (e: Error) => {
        clearTimeout(t);
        reject(e);
      };
    });
  }

  private handleMessage(text: string): void {
    try {
      const frame = JSON.parse(text) as JsonRecord;
      const type = frame['type'] as string;
      if (type === 'res') {
        this.handleResponse(frame);
      } else if (type === 'event') {
        this.handleEvent(frame);
      }
    } catch (_) {
      // ignore parse errors
    }
  }

  private handleResponse(frame: JsonRecord): void {
    const id = frame['id'] as string;
    if (!id) return;
    const ok = (frame['ok'] as boolean) ?? false;
    const payload = frame['payload'];
    const payloadJson = payload != null ? JSON.stringify(payload) : null;
    const errObj = frame['error'] as Record<string, JsonValue> | undefined;
    let error: InvokeErrorShape | null = null;
    if (errObj) {
      let message = (errObj['message'] as string) ?? 'request failed';
      const details = errObj['details'] as Record<string, JsonValue> | undefined;
      const requestId = details ? (details['requestId'] as string) : undefined;
      if (requestId && (message.includes('pairing required') || (errObj['code'] as string) === 'NOT_PAIRED')) {
        message = `pairing required (requestId: ${requestId})`;
      }
      error = { code: (errObj['code'] as string) ?? 'UNAVAILABLE', message };
    }
    const pending = this.pending.get(id);
    if (pending) {
      clearTimeout(pending.timeoutId);
      this.pending.delete(id);
      const rpcRes: RpcResponse = { id, ok, payloadJson, error };
      pending.resolve(rpcRes);
    }
  }

  private handleEvent(frame: JsonRecord): void {
    const event = frame['event'] as string;
    if (!event) return;
    const payload = frame['payload'];
    const payloadJSON = frame['payloadJSON'] as string | undefined;
    const payloadJson = payload != null ? JSON.stringify(payload) : payloadJSON ?? null;

    if (event === 'connect.challenge') {
      const nonce = this.extractConnectNonce(payloadJson);
      if (nonce && this.connectNonceResolve) {
        this.connectNonceResolve(nonce);
        this.connectNonceResolve = null;
        this.connectNonceReject = null;
      }
      return;
    }
    if (event === 'node.invoke.request' && payloadJson && this.onInvoke) {
      this.handleInvokeEvent(payloadJson);
      return;
    }
    this.onEvent(event, payloadJson);
  }

  private extractConnectNonce(payloadJson: string | null): string | null {
    if (!payloadJson?.trim()) return null;
    try {
      const obj = JSON.parse(payloadJson) as JsonRecord;
      const n = obj['nonce'] as string;
      return n?.trim() ?? null;
    } catch {
      return null;
    }
  }

  private async handleInvokeEvent(payloadJson: string): Promise<void> {
    try {
      const payload = JSON.parse(payloadJson) as JsonRecord;
      const id = payload['id'] as string;
      const nodeId = payload['nodeId'] as string;
      const command = payload['command'] as string;
      const paramsJSON = payload['paramsJSON'] as string;
      const params = payload['params'];
      const paramsJson = paramsJSON ?? (params != null ? JSON.stringify(params) : null);
      const timeoutMs = payload['timeoutMs'] as number;
      if (!id || !nodeId || !command) return;

      const result = await this.onInvoke!({
        id,
        nodeId,
        command,
        paramsJson,
        timeoutMs,
      });
      await this.sendInvokeResult(id, nodeId, result, timeoutMs);
    } catch (_) {
      // best-effort
    }
  }

  private async sendInvokeResult(
    id: string,
    nodeId: string,
    result: InvokeResult,
    invokeTimeoutMs?: number
  ): Promise<void> {
    const ackTimeoutMs = Math.min(120000, Math.max(15000, invokeTimeoutMs ?? 15000));
    const errShape: InvokeErrorShape | undefined = result.error ? { code: result.error.code, message: result.error.message } : undefined;
    const params: JsonRecord = {};
    params['id'] = id;
    params['nodeId'] = nodeId;
    params['ok'] = result.ok;
    if (result.payloadJson) {
      try {
        params['payload'] = JSON.parse(result.payloadJson) as object;
      } catch {
        params['payloadJSON'] = result.payloadJson;
      }
    }
    if (errShape) {
      params['error'] = errShape;
    }
    try {
      await this.request('node.invoke.result', params, ackTimeoutMs);
    } catch (_) {
      // best-effort
    }
  }

  async request(method: string, params: JsonRecord | null, timeoutMs: number = 15000): Promise<RpcResponse> {
    const id = randomId();
    return new Promise<RpcResponse>((resolve, reject) => {
      const timeoutId = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error('request timeout'));
        }
      }, timeoutMs) as number;

      this.pending.set(id, { resolve, reject, timeoutId });

      const frame: ReqFrame = {
        type: 'req',
        id,
        method,
      };
      if (params) frame.params = params;

      const json = JSON.stringify(frame);
      this.ws?.send(json).catch((err: Error) => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          clearTimeout(timeoutId);
          reject(new Error(err?.message ?? 'send failed'));
        }
      });
    });
  }

  async sendNodeEvent(event: string, payloadJson: string | null): Promise<boolean> {
    const params: JsonRecord = {};
    params['event'] = event;
    if (payloadJson) {
      try {
        params['payload'] = JSON.parse(payloadJson) as object;
      } catch {
        params['payloadJSON'] = payloadJson;
      }
    } else {
      params['payloadJSON'] = null;
    }
    try {
      const res = await this.request('node.event', params, 8000);
      return res.ok;
    } catch {
      return false;
    }
  }

  private handleClose(message: string): void {
    if (this.closed) return;
    this.closed = true;
    this.ws = null;
    this.canvasHostUrl = null;
    const err = new Error(message);
    this.pending.forEach((p: PendingRpc) => {
      clearTimeout(p.timeoutId);
      p.reject(err);
    });
    this.pending.clear();
    this.onDisconnected(message);
  }

  disconnect(): void {
    this.runLoopAbort = true;
    this.closed = true;
    if (this.ws) {
      this.ws.close().catch(() => {});
      this.ws = null;
    }
    const err = new Error('disconnected');
    this.pending.forEach((p: PendingRpc) => {
      clearTimeout(p.timeoutId);
      p.reject(err);
    });
    this.pending.clear();
    this.mainSessionKey = null;
    this.canvasHostUrl = null;
    this.onDisconnected('Offline');
  }

  getMainSessionKey(): string | null {
    return this.mainSessionKey;
  }

  getCanvasHostUrl(): string | null {
    return this.canvasHostUrl;
  }

  async refreshNodeCanvasCapability(timeoutMs: number = 8000): Promise<boolean> {
    try {
      const res = await this.request('node.canvas.capability.refresh', {}, timeoutMs);
      if (!res.ok || !res.payloadJson) {
        return false;
      }
      const payloadObj = JSON.parse(res.payloadJson) as JsonRecord;
      const refreshedCapability = String(payloadObj['canvasCapability'] ?? '').trim();
      if (refreshedCapability.length === 0) {
        return false;
      }
      const scoped = (this.canvasHostUrl ?? '').trim();
      if (scoped.length === 0) {
        return false;
      }
      const refreshedUrl = replaceCanvasCapabilityInScopedHostUrl(scoped, refreshedCapability);
      if (!refreshedUrl) {
        return false;
      }
      this.canvasHostUrl = refreshedUrl;
      return true;
    } catch {
      return false;
    }
  }
}
