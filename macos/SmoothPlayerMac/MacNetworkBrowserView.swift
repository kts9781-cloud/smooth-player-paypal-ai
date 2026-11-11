import SwiftUI

@MainActor
struct MacNetworkBrowserView: View {
    @ObservedObject var model: MacNetworkBrowserModel
    let onPlay: (MacNetworkPlaybackSelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingEditor = false
    @State private var editing: NASConnection?
    @State private var editorPassword = ""
    @State private var editorIdentity = UUID()
    @State private var removing: NASConnection?

    private let amber = Color(red: 214 / 255, green: 179 / 255, blue: 95 / 255)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "network").font(.title2).foregroundStyle(amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SPText("NAS 연결")).font(.headline)
                    Text(SPText("서버의 동영상을 복사하지 않고 바로 재생합니다."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(SPText("닫기")) { model.close(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                servers.frame(width: 220)
                Divider()
                VStack(spacing: 0) {
                    if let message = model.errorMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.circle")
                            Text(message).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel(SPText("오류 안내 닫기"))
                        }.font(.caption).foregroundStyle(.orange).padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.06))
                    }
                    if showingEditor {
                        MacFTPServerEditor(connection: editing, password: editorPassword,
                            onCancel: { showingEditor = false; editorPassword = "" },
                            onSave: save).id(editorIdentity)
                    } else if model.currentConnection != nil { directory }
                    else {
                        ContentUnavailableView(SPText("NAS 서버를 선택하세요"), systemImage: "externaldrive.connected.to.line.below",
                            description: Text(SPText("저장한 서버를 선택하거나 새 서버를 추가하세요.")))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(SPText("SMB · FTP(패시브 모드) · FTPS/SFTP 미지원")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                    Text(SPText("연결 중…")).font(.caption).foregroundStyle(.secondary)
                    Button(SPText("취소")) { model.close() }.controlSize(.small)
                }
            }.padding(.horizontal, 20).frame(height: 42)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 610)
        .background(Color(red: 27 / 255, green: 29 / 255, blue: 31 / 255))
        .tint(amber).preferredColorScheme(.dark)
        .onAppear { if model.connections.isEmpty { edit(nil) } }
        .onDisappear { editorPassword = "" }
        .confirmationDialog(SPText("NAS 서버 등록을 삭제할까요?"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button(SPText("등록 삭제"), role: .destructive) {
                    guard let value = removing else { return }
                    do { try model.remove(value) } catch { model.errorMessage = MacNetworkBrowserModel.message(error) }
                    removing = nil
                }
                Button(SPText("취소"), role: .cancel) { removing = nil }
            } message: { Text(SPText("로그인 중이면 다른 기기에서도 연결 정보와 비밀번호가 삭제됩니다. 서버의 파일은 유지됩니다.")) }
    }

    private var servers: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(SPText("저장한 서버")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { edit(nil) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help(SPText("NAS 서버 추가")).accessibilityLabel(SPText("NAS 서버 추가"))
            }.padding(16)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.visibleConnections) { connection in
                        HStack(spacing: 4) {
                            Button {
                                showingEditor = false; editorPassword = ""
                                perform { try await model.connect(connection) }
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(amber)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(connection.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text("\(connection.host):\(connection.port)").font(.system(size: 10))
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 10).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.isLoading)
                            Menu {
                                Button(SPText("편집")) { edit(connection) }
                                Button(SPText("등록 삭제"), role: .destructive) { removing = connection }
                            } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).frame(width: 20).disabled(model.isLoading)
                                .accessibilityLabel(SPText("\(connection.name) 서버 메뉴"))
                        }.padding(.horizontal, 10)
                            .background(model.currentConnection?.id == connection.id ? amber.opacity(0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    }
                }.padding(.horizontal, 8)
            }
            Button { edit(nil) } label: { Label(SPText("NAS 서버 추가"), systemImage: "plus") }
                .frame(maxWidth: .infinity).padding(16)
        }.background(.white.opacity(0.02))
    }

    private var directory: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { perform { try await model.goBack() } } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack).help(SPText("상위 폴더")).accessibilityLabel(SPText("상위 폴더"))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.currentConnection?.name ?? "FTP").font(.system(size: 13, weight: .semibold))
                    Text(model.currentPath).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button { perform { try await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isLoading).help(SPText("새로고침")).accessibilityLabel(SPText("폴더 새로고침"))
            }.padding(16)
            Divider()
            if model.visibleEntries.isEmpty {
                ContentUnavailableView(SPText("재생할 동영상이 없습니다"), systemImage: "folder",
                    description: Text(SPText("폴더와 지원하는 확장자의 동영상만 표시합니다.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.visibleEntries) { entry in
                            Button {
                                if entry.isDirectory { perform { try await model.enter(entry) } }
                                else {
                                    do {
                                        let selection = try model.selection(for: entry)
                                        onPlay(selection); dismiss()
                                    } catch { model.errorMessage = MacNetworkBrowserModel.message(error) }
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: entry.isDirectory ? "folder.fill" : "play.rectangle")
                                        .font(.system(size: 22, weight: .light)).foregroundStyle(entry.isDirectory ? amber : .secondary)
                                        .frame(width: 30)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entry.name).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                                        if !entry.isDirectory {
                                            Text(fileDetails(entry)).font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: entry.isDirectory ? "chevron.right" : "play.fill")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }.padding(.horizontal, 18).padding(.vertical, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.isLoading)
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
    }

    private func fileDetails(_ entry: NASEntry) -> String {
        let size = entry.size >= 0 ? ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file) : ""
        let hasSubtitle = !ExternalSubtitleFormat.matching(videoName: entry.name,
            names: model.entries.filter { !$0.isDirectory }.map(\.name)).isEmpty
        return [size, hasSubtitle ? SPText("자막 있음") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func edit(_ connection: NASConnection?) {
        do {
            editorPassword = try connection.map { try model.password(for: $0) } ?? ""
            editing = connection; editorIdentity = UUID(); showingEditor = true
            model.errorMessage = nil
        } catch { model.errorMessage = MacNetworkBrowserModel.message(error) }
    }

    private func save(_ value: NASConnection, password: String, connect: Bool) {
        do {
            let saved = try model.save(value, password: password)
            showingEditor = false; editorPassword = ""
            if connect { perform { try await model.connect(saved) } }
        } catch { model.errorMessage = MacNetworkBrowserModel.message(error) }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() }
            catch is CancellationError { }
            catch { model.errorMessage = MacNetworkBrowserModel.message(error) }
        }
    }
}

@MainActor
private struct MacFTPServerEditor: View {
    let onCancel: () -> Void
    let onSave: (NASConnection, String, Bool) -> Void
    private let id: UUID
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var path: String
    @State private var kind: NASProtocol
    @State private var share: String
    @State private var domain: String
    @State private var encoding: FTPFilenameEncoding
    @State private var validation: String?

    init(connection: NASConnection?, password: String, onCancel: @escaping () -> Void,
         onSave: @escaping (NASConnection, String, Bool) -> Void) {
        self.onCancel = onCancel; self.onSave = onSave; id = connection?.id ?? UUID()
        _kind = State(initialValue: connection?.kind ?? .ftp)
        _share = State(initialValue: connection?.share ?? "")
        _domain = State(initialValue: connection?.domain ?? "")
        _name = State(initialValue: connection?.name ?? "")
        _host = State(initialValue: connection?.host ?? "")
        _port = State(initialValue: String(connection?.port ?? 21))
        _username = State(initialValue: connection?.username ?? "")
        _password = State(initialValue: password)
        _path = State(initialValue: connection?.rootPath ?? "/")
        _encoding = State(initialValue: connection?.ftpEncoding ?? .automatic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(SPText("NAS 서버 설정")).font(.headline)
            Text(SPText("비밀번호는 키체인에 저장합니다. 이메일 로그인 시 NAS 설정과 함께 암호화해 동기화합니다."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker(SPText("연결 방식"), selection: $kind) { Text("FTP").tag(NASProtocol.ftp); Text("SMB").tag(NASProtocol.smb) }
                    .onChange(of: kind) { _, value in port = value == .ftp ? "21" : "445" }
                if kind == .smb {
                    TextField(SPText("공유 폴더 (비우면 목록)"), text: $share)
                    TextField(SPText("도메인"), text: $domain)
                }
                TextField(SPText("이름"), text: $name, prompt: Text(SPText("나의 NAS")))
                TextField(SPText("서버 주소"), text: $host, prompt: Text("192.168.0.10"))
                TextField(SPText("포트"), text: $port)
                TextField(SPText("사용자 이름"), text: $username)
                SecureField(SPText("비밀번호"), text: $password)
                TextField(SPText("시작 폴더"), text: $path, prompt: Text("/"))
                Picker(SPText("파일 이름 인코딩"), selection: $encoding) {
                    ForEach(FTPFilenameEncoding.allCases, id: \.self) { value in Text(value.title).tag(value) }
                }
            }.textFieldStyle(.roundedBorder)
            Text(SPText("서버 주소에는 ftp:// 없이 호스트 이름이나 IP를 입력하세요. 패시브 모드로 연결합니다."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            Spacer(minLength: 0)
            HStack {
                Button(SPText("취소"), action: onCancel)
                Spacer()
                Button(SPText("저장")) { submit(connect: false) }
                Button(SPText("저장 후 연결")) { submit(connect: true) }.buttonStyle(.borderedProminent)
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24)
        .onDisappear { password = "" }
    }

    private func submit(connect: Bool) {
        do {
            guard let number = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0 else {
                throw NASError.invalidConnection
            }
            let value = try NASConnection(id: id, name: name, kind: kind, host: host, port: number,
                share: share, rootPath: path, username: username, domain: domain, ftpEncoding: encoding).validated()
            validation = nil
            onSave(value, password, connect)
        } catch { validation = MacNetworkBrowserModel.message(error) }
    }
}
