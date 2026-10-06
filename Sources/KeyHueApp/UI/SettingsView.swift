import AppKit
import KeyHueCore
import SwiftUI

// MARK: - Views

/// 탭마다 내용 길이를 비슷하게 맞춘다. 한 탭이 길어져 스크롤되지 않게 표시 관련 항목은 "모양"에 모은다(ADR 0038).
/// 입력기와 단어 고침, 한/영 경고는 "입력기"에 모은다(ADR 0069).
enum SettingsTab: String, CaseIterable {
    case general
    case appearance
    case sources
    case automation
    case inputMethod
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var tab: SettingsTab { model.selectedTab }

    init(model: SettingsModel) {
        self.model = model
    }

    static let size = CGSize(width: 540, height: 640)

    /// SwiftUI TabView는 내용 둘레에 테두리 상자를 그려, 탭이 제목 막대에 붙고 탭 아래에 배경색이 다른 띠가 생긴다.
    /// 탭은 분할 컨트롤로 직접 그리고, 탭과 내용이 같은 창 배경을 쓰게 한다(ADR 0038).
    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $model.selectedTab)
                .frame(width: 500)
                .padding(.top, 14)
                .padding(.bottom, 4)

            Group {
                switch tab {
                case .general: GeneralSettingsView(model: model, updates: model.updates)
                case .appearance: AppearanceSettingsView(model: model)
                case .sources: InputSourcesSettingsView(model: model)
                case .automation: AutomationSettingsView(model: model)
                case .inputMethod: InputMethodSettingsView(model: model)
                }
            }
            .scrollContentBackground(.hidden)
            // macOS hides scroll bars until scrolling; a section cut at the bottom edge
            // would not show that more follows (ADR 0069).
            .scrollIndicators(.visible)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    }
}

/// 설정 탭 막대. SwiftUI의 분할 컨트롤은 칸을 글자 길이에 맞춰 나눠 긴 이름이 비좁아 보이므로,
/// AppKit 분할 컨트롤로 칸을 같은 너비로 나눈다.
private struct SettingsTabBar: NSViewRepresentable {
    @Binding var selection: SettingsTab

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: SettingsTab.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        control.segmentDistribution = .fillEqually
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        // 언어를 바꾸면 다시 그려지므로 제목도 여기서 갱신한다.
        for (index, tab) in SettingsTab.allCases.enumerated() {
            control.setLabel(tab.title, forSegment: index)
        }
        control.selectedSegment = SettingsTab.allCases.firstIndex(of: selection) ?? 0
    }

    final class Coordinator: NSObject {
        var selection: Binding<SettingsTab>

        init(selection: Binding<SettingsTab>) {
            self.selection = selection
        }

        @MainActor @objc func changed(_ sender: NSSegmentedControl) {
            let tabs = SettingsTab.allCases
            guard tabs.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = tabs[sender.selectedSegment]
        }
    }
}

extension SettingsTab {
    var title: String {
        switch self {
        case .general: return L("General")
        case .appearance: return L("Appearance")
        case .sources: return L("Input Sources")
        case .automation: return L("Automation")
        case .inputMethod: return L("Input Method")
        }
    }
}
