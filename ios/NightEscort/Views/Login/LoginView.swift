import AuthenticationServices
import EscortKit
import SwiftUI

/**
 登录（设计文档第 9 节）：默认验证码登录，可切换密码登录；底部微信和 Apple。
 新号码验证后必须设密码、填昵称；微信 / Apple 登录必须绑定手机号，没有“跳过”。
 */
struct LoginView: View {
    @EnvironmentObject var model: AppModel

    enum Mode { case code, password }
    enum Step: Equatable { case login, signup(ticket: String, suggested: String?), bind(ticket: String) }

    @State private var mode: Mode = .code
    @State private var step: Step = .login
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var agreed = false
    @State private var cooldown = 0
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .login: loginForm
                case .signup(let ticket, let suggested): SignupView(ticket: ticket, suggestedName: suggested)
                case .bind(let ticket): BindPhoneView(ticket: ticket) { outcome in await handle(outcome) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var title: String {
        switch step {
        case .login: return "登录"
        case .signup: return "设置密码"
        case .bind: return "绑定手机号"
        }
    }

    private var loginForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("到家没").font(.largeTitle.bold())
                    Text("回家路上，有人一直在").foregroundStyle(.secondary)
                }
                .padding(.vertical, 24)

                TextField("手机号", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                if mode == .code {
                    HStack {
                        TextField("6 位验证码", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        AsyncButton {
                            try await sendCode()
                        } label: {
                            Text(cooldown > 0 ? "\(cooldown) 秒" : "获取验证码")
                        }
                        .disabled(cooldown > 0 || !agreed)
                    }
                    .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }

                Toggle(isOn: $agreed) {
                    Text("我已阅读并同意《用户协议》和《隐私政策》").font(.footnote)
                }
                .toggleStyle(CheckboxStyle())

                if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }

                AsyncButton {
                    try await submit()
                } label: {
                    Text("登录").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!agreed)

                Button(mode == .code ? "密码登录" : "验证码登录") {
                    mode = mode == .code ? .password : .code
                    error = nil
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity)

                Divider().padding(.vertical, 8)

                VStack(spacing: 12) {
                    Button {
                        WeChatLogin.start { code in
                            Task { await run { try await model.api.loginWithWeChat(code: code) } }
                        }
                    } label: {
                        Label("微信登录", systemImage: "message.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle(color: Color(red: 0.03, green: 0.76, blue: 0.38)))
                    .disabled(!agreed)

                    SignInWithAppleButton(.signIn) { req in
                        req.requestedScopes = []
                    } onCompletion: { result in
                        guard case .success(let auth) = result,
                              let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                              let data = cred.identityToken, let token = String(data: data, encoding: .utf8) else { return }
                        Task { await run { try await model.api.loginWithApple(identityToken: token) } }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .disabled(!agreed)
                }
                Text("微信或 Apple 登录后需要绑定手机号，一个手机号只能注册一个账号。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func sendCode() async throws {
        error = nil
        try await model.api.sendSmsCode(phone: phone)
        cooldown = 60
        Task {
            while cooldown > 0 {
                try? await Task.sleep(for: .seconds(1))
                cooldown -= 1
            }
        }
    }

    private func submit() async throws {
        error = nil
        do {
            let outcome = mode == .code
                ? try await model.api.loginWithSms(phone: phone, code: code)
                : try await model.api.loginWithPassword(phone: phone, password: password)
            await handle(outcome)
        } catch let e as APIError where e.code == "password_locked" {
            mode = .code
            error = e.message
        }
    }

    private func handle(_ outcome: LoginOutcome) async {
        switch outcome.status {
        case .ok: await model.didLogin(outcome)
        case .needsSignup: step = .signup(ticket: outcome.signupTicket ?? "", suggested: outcome.suggestedName)
        case .needsPhone: step = .bind(ticket: outcome.bindTicket ?? "")
        }
    }

    private func run(_ work: () async throws -> LoginOutcome) async {
        do { await handle(try await work()) } catch { self.error = error.localizedDescription }
    }
}

struct SignupView: View {
    @EnvironmentObject var model: AppModel
    let ticket: String
    let suggestedName: String?
    @State private var password = ""
    @State private var name = ""

    var body: some View {
        Form {
            Section {
                SecureField("至少 8 位，含字母和数字", text: $password).textContentType(.newPassword)
            } header: { Text("设置密码") } footer: { Text("每个账号都必须有密码，以后可以用手机号加密码登录。") }
            Section {
                TextField("别人图谱里看到的名字", text: $name)
            } header: { Text("昵称") }
            Section {
                AsyncButton {
                    let o = try await model.api.signup(ticket: ticket, password: password, displayName: name)
                    await model.didLogin(o)
                } label: { Text("完成").frame(maxWidth: .infinity) }
                .disabled(password.count < 8 || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { if name.isEmpty, let s = suggestedName { name = s } }
    }
}

struct BindPhoneView: View {
    @EnvironmentObject var model: AppModel
    let ticket: String
    let onDone: (LoginOutcome) async -> Void
    @State private var phone = ""
    @State private var code = ""
    @State private var sent = false

    var body: some View {
        Form {
            Section {
                TextField("手机号", text: $phone).keyboardType(.phonePad)
                HStack {
                    TextField("验证码", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    AsyncButton {
                        try await model.api.sendSmsCode(phone: phone, purpose: .bind)
                        sent = true
                    } label: { Text(sent ? "已发送" : "获取验证码") }
                }
            } footer: {
                Text("为了让每个担保人都对应一个真实的人，必须绑定手机号。号码不会被搜到；只有在你求救或联系不上时，这次护航的担保人才能看到，方便直接给你打电话。")
            }
            Section {
                AsyncButton {
                    await onDone(try await model.api.bindPhone(ticket: ticket, phone: phone, code: code))
                } label: { Text("绑定").frame(maxWidth: .infinity) }
                .disabled(code.count != 6)
            }
        }
    }
}

struct CheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(configuration.isOn ? Theme.accent : .secondary)
                configuration.label.foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 微信登录需要接入微信 OpenSDK（WechatOpenSDK），并在微信开放平台注册移动应用。
/// 接入后在 start 里调用 WXApi.send(SendAuthReq)，在 onOpenURL 回调里拿到 code 交给 completion。
enum WeChatLogin {
    static func start(completion: @escaping (String) -> Void) {
        Task { @MainActor in
            AppModel.shared.toast = "微信登录还没接入微信开放平台，先用手机号登录"
        }
    }
}
