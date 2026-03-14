import { PostOnboardingTabs } from '../ui/PostOnboardingTabs';
import { OnboardingFlow } from '../ui/OnboardingFlow';
import { NodeRuntime } from '../NodeRuntime';

@Entry
@Component
struct Index {
  @State onboardingCompleted: boolean = false;
  private nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;

  aboutToAppear(): void {
    this.nodeRuntime.setOnboardingListener((completed) => {
      this.onboardingCompleted = completed;
    });
  }

  build() {
    Column() {
      if (this.onboardingCompleted) {
        PostOnboardingTabs()
      } else {
        OnboardingFlow()
      }
    }
    .width('100%')
    .height('100%')
  }
}
