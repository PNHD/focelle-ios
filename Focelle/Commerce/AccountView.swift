import AuthenticationServices
import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var account: Account
    @EnvironmentObject private var referral: Referral
    @State private var confirmsDeletion = false

    var body: some View {
        Form {
            if account.isSignedIn {
                Section("account.credits") {
                    LabeledContent("account.aiCredits", value: "\(account.credits)")
                    Button("account.sync") { Task { await account.refresh() } }
                    if referral.enabled {
                        NavigationLink("referral.title") {
                            ReferralView().environmentObject(referral)
                        }
                    }
                }
                Section {
                    Button("account.signOut", action: account.signOut)
                    Button("account.delete", role: .destructive) {
                        confirmsDeletion = true
                    }
                }
            } else {
                Section {
                    SignInWithAppleButton(
                        .signIn,
                        onRequest: account.configure,
                        onCompletion: account.complete
                    )
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)
                } footer: {
                    Text("account.signInDetail")
                }
            }

            if let messageKey = account.messageKey {
                Text(LocalizedStringKey(messageKey)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("account.title")
        .task {
            await account.refresh()
            await referral.refresh()
        }
        .confirmationDialog(
            "account.deleteConfirm",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("account.delete", role: .destructive) {
                Task { await account.delete() }
            }
            Button("common.cancel", role: .cancel) {}
        }
    }
}
