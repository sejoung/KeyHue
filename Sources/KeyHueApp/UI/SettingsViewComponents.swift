import KeyHueCore
import SwiftUI

struct PermissionRow: View {
    let message: String
    var buttonTitle = L("Grant Access…")
    let action: () -> Void

    var body: some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Spacer()
            Button(buttonTitle, action: action)
        }
    }
}

/// ADR 0069: a section explains itself in one line; the details are behind ⓘ.
struct Hint: View {
    let summary: String
    let details: String
    @State private var showsDetails = false

    init(_ summary: String, details: String) {
        self.summary = summary
        self.details = details
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            FooterText(summary).frame(maxWidth: nil)
            Button { showsDetails.toggle() } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help(L("More Information"))
            .accessibilityLabel(L("More Information"))
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                Text(details)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 360, alignment: .leading)
                    .padding()
            }
            Spacer(minLength: 0)
        }
    }
}

/// ADR 0069: "Experimental" once, as a small badge next to the title.
struct ExperimentalLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(L("Experimental"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
    }
}

/// Form 섹션 footer. 여러 줄일 때 오른쪽 정렬되지 않도록 왼쪽에 맞춘다.
struct FooterText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true) // 긴 문장이 한 줄로 잘리지 않도록
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsModel {
    /// Colors as the bar shows them: detours gray while integrated (ADR 0082).
    var displaySettings: KeyHueSettings {
        InputMethodIntegration.displaySettings(settings, integrated: settings.integrateInputMethod && InputMethodIntegration.isAvailable(in: sources))
    }
}
