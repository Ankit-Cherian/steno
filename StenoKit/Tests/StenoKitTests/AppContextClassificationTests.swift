import Testing
@testable import StenoKit

@Test("Editors and IDEs are classified by their bundle identifier")
func idesAreClassifiedByBundleIdentifier() {
    let ides = [
        ("com.microsoft.VSCode", "Code"),
        ("com.microsoft.VSCodeInsiders", "Code - Insiders"),
        ("com.jetbrains.intellij", "IntelliJ IDEA"),
        ("com.jetbrains.pycharm", "PyCharm"),
        ("com.todesktop.230313mzl4w4u92", "Editor"),
        ("com.apple.dt.Xcode", "Xcode"),
    ]
    for (bundleID, name) in ides {
        let context = AppContext.classified(bundleIdentifier: bundleID, appName: name)
        #expect(context.isIDE, "\(bundleID)")
        #expect(context.isRemoteDesktop == false, "\(bundleID)")
        #expect(context.bundleIdentifier == bundleID)
        #expect(context.appName == name)
    }
}

@Test("Remote-desktop and virtual-machine clients are classified by their bundle identifier")
func remoteDesktopsAreClassifiedByBundleIdentifier() {
    let remotes = [
        ("com.microsoft.rdc.macos", "Microsoft Remote Desktop"),
        ("com.microsoft.rdc.macos", "Windows App"),
        ("com.citrix.receiver.nomas", "Citrix Workspace"),
        ("com.vmware.horizon", "VMware Horizon Client"),
        ("com.vmware.fusion", "VMware Fusion"),
        ("com.parallels.desktop.console", "Parallels Desktop"),
        ("com.apple.RemoteDesktop", "Remote Desktop"),
    ]
    for (bundleID, name) in remotes {
        let context = AppContext.classified(bundleIdentifier: bundleID, appName: name)
        #expect(context.isRemoteDesktop, "\(bundleID) \(name)")
        #expect(context.isIDE == false, "\(bundleID)")
    }
}

@Test("Other apps are neither, whatever their name contains")
func otherAppsAreNeither() {
    let others = [
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.apple.Notes", "Notes"),
        ("com.automattic.wordpress", "WordPress"),
        ("com.example.notes", "Xcode Notes"),
        ("com.example.helper", "Remote Desktop Helper"),
        ("com.example.vscode-themes", "Themes"),
        ("unknown", "Unknown"),
    ]
    for (bundleID, name) in others {
        let context = AppContext.classified(bundleIdentifier: bundleID, appName: name)
        #expect(context.isIDE == false, "\(bundleID) \(name)")
        #expect(context.isRemoteDesktop == false, "\(bundleID) \(name)")
    }
}

@Test("Bundle identifier tokens match without regard to case")
func classificationIgnoresCase() {
    #expect(AppContext.classified(bundleIdentifier: "COM.MICROSOFT.VSCODE", appName: "").isIDE)
    #expect(AppContext.classified(bundleIdentifier: "com.Citrix.Receiver.nomas", appName: "").isRemoteDesktop)
}
