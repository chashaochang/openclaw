import { OnboardingFlow } from '../ui/OnboardingFlow';
import { NodeRuntime } from '../NodeRuntime';
import { AttributeUpdater } from '@kit.ArkUI';
import { HMDefaultGlobalAnimator, HMNavigation } from '@hadss/hmrouter';
import { HMRouterMgr } from '@hadss/hmrouter';

@Entry
@Component
struct Index {
  @State onboardingCompleted: boolean = false;
  private nodeRuntime: NodeRuntime = AppStorage.get<NodeRuntime>('nodeRuntime') as NodeRuntime;
  modifier: MyNavModifier = new MyNavModifier();


  aboutToAppear(): void {
    this.nodeRuntime.setOnboardingListener((completed) => {
      this.onboardingCompleted = completed;
    });
  }

  onBackPress(): boolean {
    // Let HMRouter manage route back stack.
    // If there's no route to pop, fall through to default system behavior.
    try {
      HMRouterMgr.pop();
      return true;
    } catch {
      return false;
    }
  }

  build() {
    Column() {
      if (this.onboardingCompleted) {
        // 使用HMNavigation容器
        HMNavigation({
          navigationId: 'MainNavigation', homePageUrl: 'PostOnboardingTabs',
          options: {
            standardAnimator: HMDefaultGlobalAnimator.STANDARD_ANIMATOR,
            dialogAnimator: HMDefaultGlobalAnimator.DIALOG_ANIMATOR,
            modifier: this.modifier
          }
        })
      } else {
        OnboardingFlow()
      }
    }
    .width('100%')
    .height('100%')
  }
}

class MyNavModifier extends AttributeUpdater<NavigationAttribute> {
  initializeModifier(instance: NavigationAttribute): void {
    instance.hideNavBar(true);
  }
}
