@Component
export struct CameraFlashOverlay {
  @Prop token: number = 0;
  @State flashOpacity: number = 0;
  private lastToken: number = 0;
  private hideTimer: number = -1;

  aboutToAppear(): void {
    this.lastToken = this.token;
  }

  aboutToUpdate(): void {
    if (this.token === this.lastToken) {
      return;
    }
    this.lastToken = this.token;
    if (this.token <= 0) {
      return;
    }
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    this.flashOpacity = 0.85;
    this.hideTimer = setTimeout(() => {
      this.flashOpacity = 0;
      this.hideTimer = -1;
    }, 110);
  }

  aboutToDisappear(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  build() {
    Stack() {
      if (this.flashOpacity > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#FFFFFF')
          .opacity(this.flashOpacity)
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }
}
