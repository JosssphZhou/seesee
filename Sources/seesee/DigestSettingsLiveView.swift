import Combine
import SwiftUI

/// 设置窗观察 QueueStore，把片库路径、未连接、搬移进度和旧位置同步进设置页模型。
/// 必须订 `$published`（赋值之后的值），不能订 `objectWillChange` 再立刻读——那时新值还没写上。
struct DigestSettingsLiveView: View {
    @ObservedObject var store: QueueStore
    @StateObject private var model: DigestSettingsModel

    init(store: QueueStore) {
        self.store = store
        _model = StateObject(wrappedValue: DigestSettingsModel(mediaFolder: store.mediaFolder))
    }

    var body: some View {
        DigestSettingsView(model: model)
            .onAppear {
                bindActions()
                store.refreshPreviousMediaFolder()
            }
            .onReceive(store.$mediaFolder) { model.mediaFolder = $0 }
            .onReceive(store.$isMediaFolderDisconnected) { model.isMediaFolderDisconnected = $0 }
            .onReceive(store.$mediaFolderMoveProgress) { model.mediaFolderMoveProgress = $0 }
            .onReceive(store.$mediaFolderMoveMessage) { model.mediaFolderMoveFailure = $0 }
            .onReceive(store.$previousMediaFolder) { model.previousMediaFolder = $0 }
    }

    private func bindActions() {
        model.onChangeMediaFolder = { [store] in
            store.presentMediaFolderPicker()
        }
    }
}
