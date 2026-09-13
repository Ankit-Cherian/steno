import SwiftUI
import StenoKit

// Compatibility wrapper around the active HistoryTab sidebar destination.
struct HistoryView: View {
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        HistoryTab()
            .environmentObject(controller)
    }
}
