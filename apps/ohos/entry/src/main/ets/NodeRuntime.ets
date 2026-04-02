/**
 * Node runtime: gateway, chat, invoke. Central app state.
 */
import { abilityAccessCtrl, common, Permissions } from "@kit.AbilityKit";
import { window } from "@kit.ArkUI";
import { deviceInfo } from "@kit.BasicServicesKit";
import {
  OpenClawCapability,
  OpenClawCalendarCommand,
  OpenClawCameraCommand,
  OpenClawCanvasA2UICommand,
  OpenClawCanvasCommand,
  OpenClawContactsCommand,
  OpenClawDeviceCommand,
  OpenClawLocationCommand,
  OpenClawMotionCommand,
  OpenClawNotificationsCommand,
  OpenClawPhotosCommand,
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
import { CameraHandler } from "./node/CameraHandler";
import { CalendarHandler } from "./node/CalendarHandler";
import { ContactsHandler } from "./node/ContactsHandler";
import { PhotosHandler } from "./node/PhotosHandler";
import { LocationHandler } from "./node/LocationHandler";
import { MotionHandler } from "./node/MotionHandler";
import { NotificationsHandler } from "./node/NotificationsHandler";
import { CanvasWebHost, OpenClawCanvasA2UIBridge } from "./canvas/CanvasWebHost";
import { CanvasInvokeHandler } from "./canvas/CanvasInvokeHandler";
import { isTrustedCanvasActionUrl } from "./canvas/CanvasActionTrust";
import {
  extractActionName,
  formatAgentMessage,
  jsDispatchA2UIActionStatus,
  type A2UIUserActionMap,
} from "./canvas/OpenClawCanvasA2UIAction";
import { VoiceCoordinator, type VoiceStateListener } from "./voice/VoiceCoordinator";
import { LocationMode, locationModeFromRaw } from "./LocationMode";

const CLIENT_ID = "openclaw-android";
const VERSION = "1.0.0";

interface HomeCanvasPayloadShape {
  gatewayState: string;
  eyebrow: string;
  title: string;
  subtitle: string;
  gatewayLabel: string;
  activeAgentName: string;
  activeAgentBadge: string;
  activeAgentCaption: string;
  agentCount: number;
  agents: object[];
  footer: string;
}

interface NodePermissionsShape {
  camera: boolean;
  location: boolean;
  microphone: boolean;
}

export type StatusListener = (status: NodeStatus) => void;

export interface NodeStatus {
  statusText: string;
  isConnected: boolean;
  remoteAddress: string;
}

export class NodeRuntime {
  private static readonly CAMERA_ENABLED_KEY = "camera.enabled";
  private static readonly LOCATION_MODE_KEY = "location.enabledMode";
  private static readonly LOCATION_PRECISE_ENABLED_KEY = "location.preciseEnabled";
  private static readonly PREVENT_SLEEP_KEY = "screen.preventSleep";
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
  private _cameraEnabled = true;
  private _locationMode: LocationMode = LocationMode.Off;
  private _locationPreciseEnabled = true;
  private _preventSleep = true;
  private _onboardingListener: ((completed: boolean) => void) | null = null;
  private foregroundActive = true;
  private mainWindow: window.Window | null = null;
  private canvasWebHost: CanvasWebHost = new CanvasWebHost();
  private a2uiBridge: OpenClawCanvasA2UIBridge;
  private voiceCoordinator: VoiceCoordinator;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.prefs = new SecurePrefs(context);
    this.identityStore = new DeviceIdentityStore(context);
    this.deviceAuthStore = new DeviceAuthStore(this.prefs);
    this.voiceCoordinator = new VoiceCoordinator(this.prefs, () => this.chatController, () => this._isConnected);
    this.a2uiBridge = new OpenClawCanvasA2UIBridge((payload: string) => {
      void this.handleCanvasA2UIActionFromWebView(payload);
    });
    this.prefs.getBoolean("onboarding.completed").then((v) => {
      this._onboardingCompleted = v;
      this._onboardingListener?.(v);
    });
    void this.hydrateFeaturePrefs();
  }

  private async hydrateFeaturePrefs(): Promise<void> {
    await Promise.all([
      this.getCameraEnabled(),
      this.getLocationMode(),
      this.getLocationPreciseEnabled(),
      this.getPreventSleep(),
    ]);
  }

  getCanvasWebHost(): CanvasWebHost {
    return this.canvasWebHost;
  }

  getCanvasA2UIBridge(): OpenClawCanvasA2UIBridge {
    return this.a2uiBridge;
  }

  private makeCanvasInvokeHandler(): CanvasInvokeHandler {
    return new CanvasInvokeHandler({
      canvas: this.canvasWebHost,
      getNodeCanvasHost: () => this.nodeSession?.getCanvasHostUrl() ?? null,
      getOperatorCanvasHost: () => this.operatorSession?.getCanvasHostUrl() ?? null,
      refreshNodeCanvasCapability: () => {
        const s = this.nodeSession;
        return s ? s.refreshNodeCanvasCapability() : Promise.resolve(false);
      },
      onA2uiPush: () => {},
      onA2uiReset: () => {},
    });
  }

  private resolveMainSessionKey(): string {
    const k = (this.operatorSession?.getMainSessionKey() ?? "").trim();
    return k.length > 0 ? k : "main";
  }

  private resolveA2uiHostUrl(): string | null {
    const nodeRaw = (this.nodeSession?.getCanvasHostUrl() ?? "").trim();
    const opRaw = (this.operatorSession?.getCanvasHostUrl() ?? "").trim();
    const raw = nodeRaw.length > 0 ? nodeRaw : opRaw;
    if (raw.length === 0) {
      return null;
    }
    return `${raw.replace(/\/+$/, "")}/__openclaw__/a2ui/?platform=harmony`;
  }

  private buildHomeCanvasPayloadJson(): string {
    let gatewayState: string;
    if (this._isConnected) {
      gatewayState = "connected";
    } else {
      const s = this._statusText.toLowerCase();
      if (s.includes("connecting") || s.includes("reconnecting")) {
        gatewayState = "connecting";
      } else if (s.includes("error") || s.includes("failed")) {
        gatewayState = "error";
      } else {
        gatewayState = "offline";
      }
    }
    const agents: object[] = [];
    const payload: HomeCanvasPayloadShape = {
      gatewayState,
      eyebrow: "OpenClaw",
      title: "Your phone stays quiet until it is needed",
      subtitle: "",
      gatewayLabel: "Gateway",
      activeAgentName: "Main",
      activeAgentBadge: "OC",
      activeAgentCaption: this._isConnected ? "Connected" : this._statusText,
      agentCount: 0,
      agents,
      footer: "",
    };
    return JSON.stringify(payload);
  }

  private updateHomeCanvasState(): void {
    this.canvasWebHost.setHomeStateJson(this.buildHomeCanvasPayloadJson());
  }

  async refreshHomeCanvasOverviewIfConnected(): Promise<void> {
    if (!this._isConnected) {
      return;
    }
    this.updateHomeCanvasState();
  }

  private randomActionId(): string {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === "x" ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    });
  }

  async handleCanvasA2UIActionFromWebView(payloadJson: string): Promise<void> {
    const trimmed = payloadJson.trim();
    if (trimmed.length === 0) {
      return;
    }
    let root: Record<string, object | string | number | boolean | null>;
    try {
      root = JSON.parse(trimmed) as Record<string, object | string | number | boolean | null>;
    } catch {
      return;
    }
    const userActionRaw = root["userAction"];
    const userActionObj: A2UIUserActionMap =
      typeof userActionRaw === "object" && userActionRaw !== null
        ? (userActionRaw as A2UIUserActionMap)
        : (root as A2UIUserActionMap);
    let actionId = String(userActionObj["id"] ?? "").trim();
    if (actionId.length === 0) {
      actionId = this.randomActionId();
    }
    const name = extractActionName(userActionObj);
    if (!name) {
      return;
    }
    const trustedBase = this.resolveA2uiHostUrl();
    const current = this.canvasWebHost.getCurrentUrl();
    const trustedList = trustedBase ? [trustedBase] : [];
    if (!isTrustedCanvasActionUrl(current, trustedList)) {
      return;
    }
    const surfaceId = String(userActionObj["surfaceId"] ?? "").trim() || "main";
    const sourceComponentId = String(userActionObj["sourceComponentId"] ?? "").trim() || "-";
    const ctxRaw = userActionObj["context"];
    const contextJson =
      typeof ctxRaw === "object" && ctxRaw !== null ? JSON.stringify(ctxRaw) : null;
    const sessionKey = this.resolveMainSessionKey();
    const displayName = await this.getDisplayName();
    const instanceId = (await this.getInstanceId()).toLowerCase();
    const message = formatAgentMessage(
      name,
      sessionKey,
      surfaceId,
      sourceComponentId,
      displayName,
      instanceId,
      contextJson,
    );
    const node = this.nodeSession;
    let error: string | null = null;
    if (node) {
      const payload = JSON.stringify({
        message,
        sessionKey,
        thinking: "low",
        deliver: false,
        key: actionId,
      });
      const sent = await node.sendNodeEvent("agent.request", payload);
      if (!sent) {
        error = "send failed";
      }
    } else {
      error = "gateway not connected";
    }
    const statusJs = jsDispatchA2UIActionStatus(actionId, error === null, error);
    try {
      await this.canvasWebHost.runJavaScript(statusJs);
    } catch {
      // ignore
    }
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
    this.voiceCoordinator.onGatewayConnectionChanged(this._isConnected);
    this.statusListener?.({
      statusText: this._statusText,
      isConnected: this._isConnected,
      remoteAddress: this._remoteAddress,
    });
    this.updateHomeCanvasState();
    void this.syncCanvasDebugOverlay();
  }

  private syncCanvasDebugOverlay(): void {
    void this.prefs.getBooleanOr("canvas.debug.enabled", false).then((en) => {
      if (en) {
        const sub = this._remoteAddress.trim().length > 0 ? this._remoteAddress : null;
        this.canvasWebHost.setDebugStatus(true, this._statusText, sub);
      } else {
        this.canvasWebHost.setDebugStatus(false, null, null);
      }
    });
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
        // Ignore permission names unsupported on this build.
      }
    }
    return false;
  }

  async getCanvasDebugEnabled(): Promise<boolean> {
    return this.prefs.getBooleanOr("canvas.debug.enabled", false);
  }

  async setCanvasDebugEnabled(enabled: boolean): Promise<void> {
    await this.prefs.putBoolean("canvas.debug.enabled", enabled);
    this.syncCanvasDebugOverlay();
  }

  async getCameraEnabled(): Promise<boolean> {
    const enabled = await this.prefs.getBooleanOr(NodeRuntime.CAMERA_ENABLED_KEY, true);
    this._cameraEnabled = enabled;
    return enabled;
  }

  getCameraEnabledSync(): boolean {
    return this._cameraEnabled;
  }

  async setCameraEnabled(enabled: boolean): Promise<void> {
    this._cameraEnabled = enabled;
    await this.prefs.putBoolean(NodeRuntime.CAMERA_ENABLED_KEY, enabled);
  }

  async getLocationMode(): Promise<LocationMode> {
    const raw = await this.prefs.getString(NodeRuntime.LOCATION_MODE_KEY);
    const mode = locationModeFromRaw(raw);
    this._locationMode = mode;
    if (raw !== mode) {
      await this.prefs.putString(NodeRuntime.LOCATION_MODE_KEY, mode);
    }
    return mode;
  }

  getLocationModeSync(): LocationMode {
    return this._locationMode;
  }

  async setLocationMode(mode: LocationMode): Promise<void> {
    this._locationMode = mode;
    await this.prefs.putString(NodeRuntime.LOCATION_MODE_KEY, mode);
  }

  async getLocationPreciseEnabled(): Promise<boolean> {
    const enabled = await this.prefs.getBooleanOr(NodeRuntime.LOCATION_PRECISE_ENABLED_KEY, true);
    this._locationPreciseEnabled = enabled;
    return enabled;
  }

  getLocationPreciseEnabledSync(): boolean {
    return this._locationPreciseEnabled;
  }

  async setLocationPreciseEnabled(enabled: boolean): Promise<void> {
    this._locationPreciseEnabled = enabled;
    await this.prefs.putBoolean(NodeRuntime.LOCATION_PRECISE_ENABLED_KEY, enabled);
  }

  async getPreventSleep(): Promise<boolean> {
    const enabled = await this.prefs.getBooleanOr(NodeRuntime.PREVENT_SLEEP_KEY, true);
    this._preventSleep = enabled;
    return enabled;
  }

  getPreventSleepSync(): boolean {
    return this._preventSleep;
  }

  async setPreventSleep(enabled: boolean): Promise<void> {
    this._preventSleep = enabled;
    await this.prefs.putBoolean(NodeRuntime.PREVENT_SLEEP_KEY, enabled);
    await this.applyPreventSleepToWindow();
  }

  bindMainWindow(mainWindow: window.Window): void {
    this.mainWindow = mainWindow;
    void this.applyPreventSleepToWindow();
  }

  unbindMainWindow(): void {
    this.mainWindow = null;
  }

  private async applyPreventSleepToWindow(): Promise<void> {
    const mainWindow = this.mainWindow;
    if (!mainWindow) {
      return;
    }
    try {
      await mainWindow.setWindowKeepScreenOn(this._preventSleep);
    } catch {
      // Best-effort only; keep the preference even if the API is unavailable on this build.
    }
  }

  setVoiceUiListener(listener: VoiceStateListener | null): void {
    this.voiceCoordinator.setUiListener(listener);
  }

  async setVoiceMicEnabled(enabled: boolean): Promise<void> {
    await this.voiceCoordinator.setMicEnabled(enabled);
  }

  async setVoiceSpeakerEnabled(enabled: boolean): Promise<void> {
    await this.voiceCoordinator.setSpeakerEnabled(enabled);
  }

  async cancelVoicePendingTurn(): Promise<void> {
    await this.voiceCoordinator.cancelPendingTurn();
  }

  getVoiceSpeakerEnabled(): boolean {
    return this.voiceCoordinator.getSpeakerEnabled();
  }

  setVoiceScreenActive(active: boolean): void {
    this.voiceCoordinator.setVoiceScreenActive(active);
  }

  setForegroundActive(active: boolean): void {
    this.foregroundActive = active;
  }

  getVoiceMicEnabled(): boolean {
    return this.voiceCoordinator.getMicEnabled();
  }

  getVoiceMicCooldown(): boolean {
    return this.voiceCoordinator.getMicCooldown();
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
          this.canvasWebHost.navigate("");
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
        this.canvasWebHost.navigate("");
        this.notifyStatus();
        this.chatController?.onDisconnected(message);
        const node = this.nodeSession;
        this.nodeSession = null;
        node?.disconnect();
      },
      (event, payloadJson) => {
        this.chatController?.handleGatewayEvent(event, payloadJson);
        this.voiceCoordinator.handleGatewayEvent(event, payloadJson);
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
          this.canvasWebHost.navigate("");
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
        this.canvasWebHost.navigate("");
        this.notifyStatus();
        this.chatController?.onDisconnected(message);
        const op = this.operatorSession;
        this.operatorSession = null;
        op?.disconnect();
      },
      () => {},
      async (req) => {
        const dispatcher = new InvokeDispatcher(
          new DeviceHandler(this.context),
          new SystemHandler(),
          new CameraHandler(this.context, () => this.foregroundActive),
          new CalendarHandler(this.context),
          new ContactsHandler(this.context),
          new PhotosHandler(this.context),
          new LocationHandler(
            this.context,
            () => this.foregroundActive,
            () => this.getLocationPreciseEnabledSync(),
          ),
          new MotionHandler(this.context),
          new NotificationsHandler(this.context),
          () => this.getCameraEnabledSync(),
          () => this.getLocationModeSync() !== LocationMode.Off,
          this.makeCanvasInvokeHandler(),
        );
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
      this.canvasWebHost.navigate("");
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
    const motionActivityAvailable = MotionHandler.isActivityAvailable();
    const motionPedometerAvailable = MotionHandler.isPedometerAvailable();
    const motionAvailable = motionActivityAvailable || motionPedometerAvailable;
    const cameraEnabled = await this.getCameraEnabled();
    const locationMode = await this.getLocationMode();
    const locationEnabled = locationMode !== LocationMode.Off;
    const caps: string[] = [
      OpenClawCapability.Device,
      OpenClawCapability.System,
      OpenClawCapability.Canvas,
      OpenClawCapability.Calendar,
      OpenClawCapability.Contacts,
      OpenClawCapability.Photos,
      OpenClawCapability.Notifications,
    ];
    if (cameraEnabled) {
      caps.push(OpenClawCapability.Camera);
    }
    if (locationEnabled) {
      caps.push(OpenClawCapability.Location);
    }
    if (motionAvailable) {
      caps.push(OpenClawCapability.Motion);
    }
    const commands: string[] = [
      OpenClawDeviceCommand.Status,
      OpenClawDeviceCommand.Info,
      OpenClawDeviceCommand.Permissions,
      OpenClawDeviceCommand.Health,
      OpenClawSystemCommand.Notify,
      OpenClawCalendarCommand.Events,
      OpenClawCalendarCommand.Add,
      OpenClawContactsCommand.Search,
      OpenClawContactsCommand.Add,
      OpenClawPhotosCommand.Latest,
      OpenClawNotificationsCommand.List,
      OpenClawCanvasCommand.Present,
      OpenClawCanvasCommand.Hide,
      OpenClawCanvasCommand.Navigate,
      OpenClawCanvasCommand.Eval,
      OpenClawCanvasCommand.Snapshot,
      OpenClawCanvasA2UICommand.Push,
      OpenClawCanvasA2UICommand.PushJSONL,
      OpenClawCanvasA2UICommand.Reset,
    ];
    if (cameraEnabled) {
      commands.push(
        OpenClawCameraCommand.List,
        OpenClawCameraCommand.Snap,
        OpenClawCameraCommand.Clip,
      );
    }
    if (locationEnabled) {
      commands.push(OpenClawLocationCommand.Get);
    }
    if (motionActivityAvailable) {
      commands.push(OpenClawMotionCommand.Activity);
    }
    if (motionPedometerAvailable) {
      commands.push(OpenClawMotionCommand.Pedometer);
    }
    const permissions: NodePermissionsShape = {
      camera: cameraEnabled && this.hasAnyPermission(["ohos.permission.CAMERA"]),
      location: locationEnabled && this.hasAnyPermission([
        "ohos.permission.APPROXIMATELY_LOCATION",
        "ohos.permission.LOCATION",
      ]),
      microphone: this.hasAnyPermission(["ohos.permission.MICROPHONE"]),
    };
    return {
      role: "node",
      scopes: [],
      caps,
      commands,
      permissions,
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

  async refreshGatewayConnection(): Promise<void> {
    const host = await this.getManualHost();
    const portStr = await this.getManualPort();
    const port = parseInt(portStr, 10) || 18789;
    const useTls = await this.getManualTls();
    const token = await this.getGatewayToken();
    const password = await this.getGatewayPassword();
    if (!host || host.trim().length === 0) {
      this._statusText = "Failed: no cached gateway endpoint";
      this.notifyStatus();
      return;
    }
    await this.connect(host.trim(), port, useTls, token, password);
  }

  /**
   * HarmonyOS may tear down WebSockets when the app backgrounds; reconnect when returning to foreground.
   * Only runs if the user had a successful manual gateway connection (see connect() -> setManualEnabled(true)).
   */
  async reconnectGatewayOnForeground(): Promise<void> {
    const enabled = await this.getManualEnabled();
    if (!enabled) {
      return;
    }
    await this.refreshGatewayConnection();
  }

  disconnect(): void {
    void this.voiceCoordinator.prepareDisconnect();
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
    this.canvasWebHost.navigate("");
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
