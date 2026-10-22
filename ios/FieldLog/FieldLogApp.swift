import SwiftUI

@main struct FieldLogApp: App {
  @StateObject private var model = WorkspaceModel()
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      WorkspaceView().environmentObject(model).tint(FieldStyle.green).task { await model.open() }
        .onChange(of: scenePhase) { _, phase in
          if phase == .background {
            let token = UIApplication.shared.beginBackgroundTask(withName: "Save FieldLog drafts")
            Task {
              await model.flush()
              if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
            }
          }
        }
    }
  }
}

enum FieldStyle {
  // Text and system control tints need a lighter accent on dark surfaces.
  static let green = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 0.48, green: 0.82, blue: 0.69, alpha: 1)
      : UIColor(red: 0.14, green: 0.34, blue: 0.28, alpha: 1)
  })
  static let filledButton = Color(red: 0.14, green: 0.34, blue: 0.28)
  static let paper = Color(uiColor: .systemGroupedBackground)
}
