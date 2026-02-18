import SwiftUI
import StenoKit

// HistoryView is replaced by HistoryTab in the new tab-based UI.
// This file is kept to avoid stale Xcode project references.
struct HistoryView: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        HistoryTab()
            .environmentObject(controller)
    }
}
