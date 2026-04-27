import type { CameraHudState } from '../NodeRuntime';

interface CameraHudPalette {
  background: string;
  border: string;
  text: string;
  accent: string;
  symbol: Resource;
}

@Component
export struct CameraHudOverlay {
  @Prop hud: CameraHudState | null;

  private palette(): CameraHudPalette {
    if (this.hud === null) {
      return {
        background: '#17181C',
        border: '#2A2C33',
        text: '#FFFFFF',
        accent: '#FFFFFF',
        symbol: $r('sys.symbol.camera_fill'),
      };
    }
    if (this.hud.kind === 'success') {
      return {
        background: '#EAF7EF',
        border: '#CFE9D8',
        text: '#1D6B43',
        accent: '#2F8C5A',
        symbol: $r('sys.symbol.checkmark_circle_fill'),
      };
    }
    if (this.hud.kind === 'error') {
      return {
        background: '#FDEEEE',
        border: '#F5CACA',
        text: '#A3363A',
        accent: '#D84D57',
        symbol: $r('sys.symbol.xmark_circle_fill'),
      };
    }
    if (this.hud.kind === 'recording') {
      return {
        background: '#FFF1F1',
        border: '#F7D7D7',
        text: '#B63D46',
        accent: '#E34B55',
        symbol: $r('sys.symbol.video_fill'),
      };
    }
    return {
      background: '#EEF4FF',
      border: '#D8E4FA',
      text: '#1D5DD8',
      accent: '#1D5DD8',
      symbol: $r('sys.symbol.camera_fill'),
    };
  }

  build() {
    Stack() {
      if (this.hud !== null) {
        Row({ space: 12 }) {
          SymbolGlyph(this.palette().symbol)
            .fontSize(22)
            .fontColor([this.palette().accent])
          Column({ space: 2 }) {
            Text(this.hud.kind === 'recording' ? 'Camera Recording' : 'Camera')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor('#6B7280')
            Text(this.hud.message)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.palette().text)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor(this.palette().background)
        .borderRadius(20)
        .border({ width: 1, color: this.palette().border })
        .shadow({ radius: 16, color: '#22000000', offsetX: 0, offsetY: 8 })
        .margin({ left: 16, right: 16, bottom: 98 })
      }
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Bottom)
    .hitTestBehavior(HitTestMode.None)
  }
}
