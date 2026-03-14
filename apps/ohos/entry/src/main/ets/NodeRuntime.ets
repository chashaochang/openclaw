/**
 * Node runtime: gateway, chat, invoke. Central app state.
 */
import { common } from "@kit.AbilityKit";
import { deviceInfo } from "@kit.BasicServicesKit";
import {
  OpenClawCapability,
  OpenClawDeviceCommand,
  OpenClawSystemCommand,
} from "./protocol/OpenClawProtocol";
import { SecurePrefs } from "./common/SecurePrefs";
import { DeviceIdentityStore } from "./gateway/DeviceIdentityStore";
import { DeviceAuthStore } from "./gateway/DeviceAuthStore";
import { GatewaySession, GatewayConnectOptions, GatewayClientInfo } from "./gateway/GatewaySession";
import { GatewayEndpoint } from "./gateway/GatewayEndpoint";
import { ChatController } from "./chat/ChatController";
import { DeviceHandler } from "./node/DeviceHandler";
import { SystemHandler } from "./node/SystemHandler";
import { InvokeDispatcher } from "./node/InvokeDispatcher";

const CLIENT_ID = "openclaw-android";
const VERSION = "1.0.0";

export type StatusListener = (status: NodeStatus) => void;

export interface NodeStatus {
  statusText: string;
  isConnected: boolean;
  remoteAddress: string;
}

export class NodeRuntime {
  private context: common.UIAbilityContext;
  private prefs: SecurePrefs;
  private identityStore: DeviceIdentityStore;
  private deviceAuthStore: DeviceAuthStore;
  private operatorSession: GatewaySession | null = null;
  private nodeSession: GatewaySession | null = null;
  private chatController: ChatController | null = null;
  private statusListener: StatusListener | null = null;
  private _statusText = "Offline";
  private _isConnected = false;
  private _remoteAddress = "";
  private _onboardingCompleted = false;
  private _onboardingListener: ((completed: boolean) => void) | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.prefs = new SecurePrefs(context);
    this.identityStore = new DeviceIdentityStore(context);
    this.deviceAuthStore = new DeviceAuthStore(this.prefs);
    this.prefs.getBoolean("onboarding.completed").then((v) => {
      this._onboardingCompleted = v;
      this._onboardingListener?.(v);
    });
  }

  setOnboardingListener(listener: ((completed: boolean) => void) | null): void {
    this._onboardingListener = listener;
    if (listener) {
      listener(this._onboardingCompleted);
    }
  }

  getOnboardingCompleted(): boolean {
    return this._onboardingCompleted;
  }

  async setOnboardingCompleted(completed: boolean): Promise<void> {
    this._onboardingCompleted = completed;
    await this.prefs.putBoolean("onboarding.completed", completed);
    this._onboardingListener?.(completed);
  }

  setStatusListener(listener: StatusListener | null): void {
    this.statusListener = listener;
  }

  private notifyStatus(): void {
    this.statusListener?.({
      statusText: this._statusText,
      isConnected: this._isConnected,
      remoteAddress: this._remoteAddress,
    });
  }

  getStatusText(): string {
    return this._statusText;
  }

  getIsConnected(): boolean {
    return this._isConnected;
  }

  getRemoteAddress(): string {
    return this._remoteAddress;
  }

  getVersion(): string {
    return VERSION;
  }

  getDeviceModel(): string {
    const parts = [deviceInfo.manufacture, deviceInfo.productModel]
      .filter((s) => (s ?? "").trim().length > 0);
    return parts.join(" ").trim() || "HarmonyOS";
  }

  async getInstanceId(): Promise<string> {
    try {
      const identity = await this.identityStore.loadOrCreate();
      return identity.deviceId;
    } catch {
      return "";
    }
  }

  async getDisplayName(): Promise<string> {
    const stored = await this.prefs.getString("display.name");
    if (stored && stored.trim().length > 0) return stored.trim();
    const fallback = (deviceInfo.marketName ?? deviceInfo.productModel ?? "").trim();
    return fallback || "";
  }

  async setDisplayName(name: string): Promise<void> {
    await this.prefs.putString("display.name", (name ?? "").trim());
  }

  getChatController(): ChatController | null {
    return this.chatController;
  }

  async connect(
    host: string,
    port: number,
    useTls: boolean,
    token: string,
    password: string,
  ): Promise<void> {
    this.disconnect();
    this._statusText = "Connecting…";
    this._isConnected = false;
    this.notifyStatus();

    const endpoint: GatewayEndpoint = { host: host.trim(), port, useTls };
    const tokenOrNull = token?.trim() ? token.trim() : null;
    const passwordOrNull = password?.trim() ? password.trim() : null;

    const operatorOpts = await this.buildOperatorConnectOptions();
    const nodeOpts = await this.buildNodeConnectOptions();

    let operatorConnected = false;
    let nodeConnected = false;
    let mainSessionKey: string | null = null;
    const remoteAddress =
      endpoint.host.includes(":") ? `[${endpoint.host}]:${endpoint.port}` : `${endpoint.host}:${endpoint.port}`;

    const operatorSession = new GatewaySession(
      this.identityStore,
      this.deviceAuthStore,
      (_, _remote, sessionKey) => {
        operatorConnected = true;
        if (sessionKey) mainSessionKey = sessionKey;
        if (operatorConnected && nodeConnected) {
          this._statusText = "Connected";
          this._isConnected = true;
          this._remoteAddress = remoteAddress;
          this.notifyStatus();
          if (mainSessionKey) {
            this.chatController?.applyMainSessionKey(mainSessionKey);
          }
          this.chatController?.bootstrap();
        }
      },
      (message) => {
        this._statusText = message;
        this._isConnected = false;
        this.notifyStatus();
        this.chatController?.onDisconnected(message);
        const node = this.nodeSession;
        this.nodeSession = null;
        node?.disconnect();
      },
      (event, payloadJson) => {
        this.chatController?.handleGatewayEvent(event, payloadJson);
      },
      null,
      null,
    );

    const nodeSession = new GatewaySession(
      this.identityStore,
      this.deviceAuthStore,
      () => {
        nodeConnected = true;
        if (operatorConnected && nodeConnected) {
          this._statusText = "Connected";
          this._isConnected = true;
          this._remoteAddress = remoteAddress;
          this.notifyStatus();
          if (mainSessionKey) {
            this.chatController?.applyMainSessionKey(mainSessionKey);
          }
          this.chatController?.bootstrap();
        }
      },
      (message) => {
        this._statusText = message;
        this._isConnected = false;
        this.notifyStatus();
        this.chatController?.onDisconnected(message);
        const op = this.operatorSession;
        this.operatorSession = null;
        op?.disconnect();
      },
      () => {},
      async (req) => {
        const dispatcher = new InvokeDispatcher(new DeviceHandler(), new SystemHandler());
        return dispatcher.handleInvoke(req);
      },
      null,
    );

    this.operatorSession = operatorSession;
    this.nodeSession = nodeSession;
    this.chatController = new ChatController(operatorSession);
    this.chatController.setListener(null);

    try {
      await Promise.all([
        operatorSession.connect(endpoint, tokenOrNull, passwordOrNull, operatorOpts),
        nodeSession.connect(endpoint, tokenOrNull, passwordOrNull, nodeOpts),
      ]);
      await this.setManualEnabled(true);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      this._statusText = msg.startsWith("Gateway ") ? msg : `Gateway error: ${msg}`;
      this._isConnected = false;
      this.notifyStatus();
      const op = this.operatorSession;
      const node = this.nodeSession;
      this.operatorSession = null;
      this.nodeSession = null;
      this.chatController = null;
      op?.disconnect();
      node?.disconnect();
      throw new Error(msg);
    }
  }

  private async buildClientInfo(mode: string): Promise<GatewayClientInfo> {
    const modelIdentifier =
      [deviceInfo.manufacture, deviceInfo.productModel]
        .filter((s) => (s ?? "").trim().length > 0)
        .join(" ")
        .trim() || undefined;
    const stored = await this.prefs.getString("display.name");
    const fallback = (deviceInfo.marketName ?? deviceInfo.productModel ?? "").trim();
    const displayName = (stored?.trim() || fallback) || undefined;
    return {
      id: CLIENT_ID,
      version: VERSION,
      platform: "android",
      mode,
      deviceFamily: "Android",
      displayName,
      modelIdentifier,
    };
  }

  private async buildNodeConnectOptions(): Promise<GatewayConnectOptions> {
    const caps: string[] = [OpenClawCapability.Device, OpenClawCapability.System];
    const commands: string[] = [
      OpenClawDeviceCommand.Status,
      OpenClawDeviceCommand.Info,
      OpenClawDeviceCommand.Permissions,
      OpenClawDeviceCommand.Health,
      OpenClawSystemCommand.Notify,
    ];
    return {
      role: "node",
      scopes: [],
      caps,
      commands,
      permissions: {},
      client: await this.buildClientInfo("node"),
      userAgent: `OpenClawAndroid/${VERSION} (Android 14; SDK 34)`,
    };
  }

  private async buildOperatorConnectOptions(): Promise<GatewayConnectOptions> {
    return {
      role: "operator",
      scopes: ["operator.read", "operator.write", "operator.talk.secrets"],
      caps: [],
      commands: [],
      permissions: {},
      client: await this.buildClientInfo("ui"),
      userAgent: `OpenClawAndroid/${VERSION} (Android 14; SDK 34)`,
    };
  }

  disconnect(): void {
    if (this.operatorSession) {
      this.operatorSession.disconnect();
      this.operatorSession = null;
    }
    if (this.nodeSession) {
      this.nodeSession.disconnect();
      this.nodeSession = null;
    }
    this.chatController = null;
    this._statusText = "Offline";
    this._isConnected = false;
    this._remoteAddress = "";
    this.notifyStatus();
  }

  async clearPairing(): Promise<void> {
    this.disconnect();
    await this.prefs.clear();
    this.identityStore.clearCache();
  }

  async saveManualConfig(
    host: string,
    port: number,
    tls: boolean,
    token: string,
    password: string,
  ): Promise<void> {
    await this.prefs.putString("manual.host", host.trim());
    await this.prefs.putString("manual.port", String(port));
    await this.prefs.putBoolean("manual.tls", tls);
    await this.prefs.putString("gateway.token", token.trim());
    await this.prefs.putString("gateway.password", password.trim());
  }

  async setManualEnabled(enabled: boolean): Promise<void> {
    await this.prefs.putBoolean("manual.enabled", enabled);
  }

  async getManualEnabled(): Promise<boolean> {
    return await this.prefs.getBoolean("manual.enabled");
  }

  async getManualHost(): Promise<string> {
    return (await this.prefs.getString("manual.host")) ?? "10.0.2.2";
  }

  async getManualPort(): Promise<string> {
    return (await this.prefs.getString("manual.port")) ?? "18789";
  }

  async getManualTls(): Promise<boolean> {
    return await this.prefs.getBoolean("manual.tls");
  }

  async getGatewayToken(): Promise<string> {
    return (await this.prefs.getString("gateway.token")) ?? "";
  }

  async getGatewayPassword(): Promise<string> {
    return (await this.prefs.getString("gateway.password")) ?? "";
  }
}
