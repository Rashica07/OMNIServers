import SwiftUI

/// The PIN gate shown at launch when `AppLock.shared.isSet` — direct
/// counterpart of the Tauri app's lock screen (`App.tsx`'s `locked`
/// state). Offers Touch ID first when available, PIN always as the
/// fallback — the native win the plan calls out for this feature.
struct LockScreenView: View {
    let onUnlock: () -> Void

    @State private var pin = ""
    @State private var errorText: String?
    @State private var triedBiometrics = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(CPColor.accent)
            VStack(spacing: 4) {
                Text("OMNIServers is locked")
                    .font(CPFont.display(18, weight: .semibold))
                    .foregroundStyle(CPColor.ink)
                Text("Enter your PIN to continue.")
                    .font(.callout)
                    .foregroundStyle(CPColor.inkFaint)
            }

            VStack(spacing: 8) {
                SecureField("PIN", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(tryUnlock)
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(CPColor.bad)
                }
                Button("Unlock") { tryUnlock() }
                    .cpButton(.primary)
                    .disabled(pin.isEmpty)

                if BiometricUnlock.isAvailable {
                    Button {
                        Task { await tryBiometrics() }
                    } label: {
                        Label("Unlock with Touch ID", systemImage: "touchid")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(CPColor.accent)
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CPColor.bg)
        .task {
            guard !triedBiometrics else { return }
            triedBiometrics = true
            await tryBiometrics()
        }
    }

    private func tryUnlock() {
        let entered = pin
        Task {
            // Argon2id is deliberately slow; never on the main thread.
            let ok = await Task.detached { AppLock.shared.check(pin: entered) }.value
            if ok { onUnlock() } else { errorText = "Wrong PIN."; pin = "" }
        }
    }

    private func tryBiometrics() async {
        guard await BiometricUnlock.authenticate(reason: "Unlock CraftPanel") else { return }
        onUnlock()
    }
}
