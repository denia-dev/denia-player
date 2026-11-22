import SwiftUI

struct ServersView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.servers) { server in
                    Button {
                        store.setActive(id: server.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).font(.headline)
                                Text(server.baseURL).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if server.id == store.activeServer?.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                            }
                            Text(server.isLoggedIn ? "已登录" : "未登录")
                                .font(.caption2)
                                .foregroundStyle(server.isLoggedIn ? .green : .orange)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.remove(id: server.id) } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("服务器")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddServerView() }
            .overlay {
                if store.servers.isEmpty {
                    ContentUnavailableView("还没有服务器", systemImage: "server.rack",
                                           description: Text("点右上角 + 添加你的 Emby 服务器"))
                }
            }
        }
    }
}

struct AddServerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("名称（可空）", text: $name)
                    TextField("地址，只填域名即可，如 emby.example.com", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("账号") {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("添加服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("登录") { Task { await login() } }
                        .disabled(busy || address.isEmpty || username.isEmpty)
                }
            }
            .overlay { if busy { ProgressView("连接中…") } }
        }
    }

    private func login() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let config = try await EmbyClient.authenticate(
                address: address, name: name, username: username, password: password)
            store.add(config)
            dismiss()
        } catch {
            errorText = "登录失败：\(error.localizedDescription)"
        }
    }
}
