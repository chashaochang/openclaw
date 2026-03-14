/**
 * Settings tab: matches Android SettingsSheet structure and styling.
 * Section header, Name field, instance ID/device/version, Clear pairing row, Run onboarding.
 */
import { NodeRuntime } from "../NodeRuntime";

@Component
export struct SettingsTabScreen {
  @StorageLink("nodeRuntime") nodeRuntime: NodeRuntime =
    AppStorage.get<NodeRuntime>("nodeRuntime") as NodeRuntime;
  @State instanceId: string = "";
  @State displayName: string = "";

  aboutToAppear(): void {
    this.nodeRuntime.getInstanceId().then((id: string) => {
      this.instanceId = id || "—";
    });
    this.nodeRuntime.getDisplayName().then((name: string) => {
      this.displayName = name;
    });
  }

  build() {
    Scroll() {
      Column({ space: 8 }) {
        Column({ space: 6 }) {
          Text($r("app.string.settings_section_settings"))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor("#1D5DD8")
          Text($r("app.string.settings_device_configuration_title"))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor("#17181C")
          Text($r("app.string.settings_device_configuration_subtitle"))
            .fontSize(14)
            .fontColor("#4D5563")
        }
        .alignItems(HorizontalAlign.Start)
        .width("100%")

        Divider()
          .strokeWidth(1)
          .color("#E5E7EC")
          .width("100%")

        Text($r("app.string.settings_section_node"))
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor("#1D5DD8")

        Column({ space: 4 }) {
          Text($r("app.string.settings_name_label"))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor("#4D5563")
          TextInput({
            placeholder: $r("app.string.settings_name_label"),
            text: this.displayName
          })
            .onChange((v: string) => {
              this.displayName = v;
              this.nodeRuntime.setDisplayName(v);
            })
            .width("100%")
            .backgroundColor("#FFFFFF")
            .borderRadius(14)
            .border({ width: 1, color: "#E5E7EC" })
        }
        .width("100%")
        .alignItems(HorizontalAlign.Start)

        Text(this.instanceId ? `Instance ID: ${this.instanceId}` : "Instance ID: —")
          .fontSize(14)
          .fontFamily("monospace")
          .fontColor("#4D5563")
          .width("100%")
          .alignSelf(ItemAlign.Start)

        Text(`Device: ${this.nodeRuntime.getDeviceModel()}`)
          .fontSize(14)
          .fontColor("#4D5563")
          .width("100%")
          .alignSelf(ItemAlign.Start)

        Text(`Version: ${this.nodeRuntime.getVersion()}`)
          .fontSize(14)
          .fontColor("#4D5563")
          .width("100%")
          .alignSelf(ItemAlign.Start)

        Divider()
          .strokeWidth(1)
          .color("#E5E7EC")
          .width("100%")

        Row() {
          Column({ space: 2 }) {
            Text($r("app.string.settings_clear_pairing"))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor("#17181C")
            Text($r("app.string.settings_clear_pairing_subtitle"))
              .fontSize(14)
              .fontColor("#4D5563")
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Blank()
          Button($r("app.string.settings_clear_pairing_button"))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .backgroundColor("#1D5DD8")
            .fontColor("#FFFFFF")
            .borderRadius(14)
            .height(36)
            .onClick(async () => {
              await this.nodeRuntime.clearPairing();
            })
        }
        .width("100%")
        .padding(14)
        .backgroundColor("#FFFFFF")
        .borderRadius(14)
        .border({ width: 1, color: "#E5E7EC" })

        Button($r("app.string.connect_run_onboarding_again"))
          .width("100%")
          .backgroundColor(Color.Transparent)
          .fontColor("#1D5DD8")
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .borderRadius(12)
          .onClick(async () => {
            await this.nodeRuntime.setOnboardingCompleted(false);
          })

        Column()
          .height(24)
      }
      .width("100%")
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
    }
    .width("100%")
    .height("100%")
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
    .backgroundColor("#F7F8FA")
  }
}
