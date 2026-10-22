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
  static let green = Color(red: 0.14, green: 0.34, blue: 0.28)
  static let paper = Color(uiColor: .systemGroupedBackground)
}
