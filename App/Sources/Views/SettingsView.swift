import MinutesCore
import SwiftUI

/// Email account, speech models, remembered voices, storage and diagnostics.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var address = ""
    @State private var password = ""
    @State private var recipient = ""
    @State private var host = ""
    @State private var port = ""
    @State private var showServer = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false
    @State private var keepDays = 30
    @State private var languageModel = ""
    @State private var languageModelOK = true
    @State private var share: ShareItem?
    @State private var confirmRemoveMail = false
    @State private var loaded = false

    var body: some View {
        Form {
            emailSection
            if !model.mailReady || model.mail.isGmail {
                gmailHelpSection
            }
            speechSection
            voicesSection
            storageSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .tint(Theme.action)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onAppear(perform: load)
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog("Remove the email account?", isPresented: $confirmRemoveMail, titleVisibility: .visible) {
            Button("Remove account", role: .destructive) {
                model.removeMail()
                address = ""
                password = ""
                recipient = ""
                testResult = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The address and app password are erased from this iPhone. Notes stop being emailed until an account is set up again.")
        }
    }

    // MARK: Email

    private var emailSection: some View {
        Section {
            TextField("Gmail address", text: $address)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(model.mailReady ? "App password (saved)" : "App password", text: $password)
                .textContentType(.password)
            TextField("Send notes to (leave empty for the same address)", text: $recipient)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            DisclosureGroup("Mail server", isExpanded: $showServer) {
                TextField("Server", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                Text("Leave these alone for Gmail. Another provider works if its server accepts an encrypted connection on port 465.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }

            Button {
                Task { await saveAndTest() }
            } label: {
                HStack(spacing: 10) {
                    if testing { ProgressView() }
                    Text(testing ? "Sending a test email" : "Save and send a test email")
                }
            }
            .disabled(testing || !canSave)

            if let testResult {
                Label(testResult, systemImage: testFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(testFailed ? Theme.record : Theme.ok)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.mailReady {
                Button("Remove this account", role: .destructive) { confirmRemoveMail = true }
            }
        } header: {
            Text("Email")
        } footer: {
            Text(model.mailReady
                ? "Notes and transcripts are sent from this account as soon as a meeting has been processed."
                : "Minutes sends the notes through your own mail account, so there is no service in between and nothing to pay for.")
        }
    }

    private var canSave: Bool {
        address.contains("@") && (!password.isEmpty || model.mailReady)
    }

    private var gmailHelpSection: some View {
        Section {
            helpStep(1, "Turn on 2-Step Verification for your Google account, if it isn't on already.")
            Link("Open Google security settings", destination: URL(string: "https://myaccount.google.com/security")!)
            helpStep(2, "Create an app password and name it Minutes. Google shows 16 letters.")
            Link("Open Google app passwords", destination: URL(string: "https://myaccount.google.com/apppasswords")!)
            helpStep(3, "Paste the 16 letters into App password above, then send the test email.")
        } header: {
            Text("Getting a Gmail app password")
        } footer: {
            Text("An app password is a separate password for one app. You can revoke it at any time on the same Google page without changing your real password. Minutes keeps it in this iPhone's Keychain and uses it only to sign in to Gmail's mail server.")
        }
    }

    private func helpStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(Theme.numerals(15))
                .foregroundStyle(Theme.muted)
                .frame(width: 16)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveAndTest() async {
        testing = true
        testResult = nil
        model.saveMail(
            address: address, recipient: recipient, password: password.isEmpty ? nil : password,
            host: host, port: Int(port.trimmingCharacters(in: .whitespaces)))
        let problem = await model.sendTestEmail()
        testing = false
        testFailed = problem != nil
        if let problem {
            testResult = problem
        } else {
            let to = model.mail.recipients.joined(separator: ", ")
            testResult = "Test email sent to \(to). Check the inbox."
            password = ""
            // Anything that was waiting only for a working mail account can go now.
            model.resumeWaiting(onlyEmail: true)
        }
    }

    // MARK: Speech and notes

    private var speechSection: some View {
        Section {
            if model.setup.ready {
                Label("Speech models are on this iPhone", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.ok)
            } else if model.setup.downloading {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcription model")
                        .font(.subheadline)
                    ProgressView(value: model.setup.transcription)
                    Text("Speaker separation model")
                        .font(.subheadline)
                    ProgressView(value: model.setup.separation)
                    Text("Keep Minutes open until both finish.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                .tint(Theme.ink)
            } else {
                if let error = model.setup.error {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Theme.record)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Download speech models (about 700 MB)") {
                    Task { await model.downloadModels() }
                }
            }
            Label(languageModel, systemImage: languageModelOK ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(languageModelOK ? Theme.ok : Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("On this iPhone")
        } footer: {
            Text("Recording, speaker separation, transcription and note writing all run on this iPhone. The only thing that leaves it is the email, sent through your own account.")
        }
    }

    // MARK: Voices

    private var voicesSection: some View {
        Section {
            if model.profiles.isEmpty {
                Text("No voices yet. Name a speaker in any meeting and Minutes recognizes that voice afterward.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            } else {
                ForEach(model.profiles) { profile in
                    HStack {
                        Text(profile.name)
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Text(profile.samples == 1 ? "1 meeting" : "\(profile.samples) meetings")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { model.profiles[$0].id }
                    ids.forEach { model.forgetVoice($0) }
                }
            }
        } header: {
            Text("Voices Minutes knows")
        } footer: {
            if !model.profiles.isEmpty {
                Text("Swipe a name to forget that voice.")
            }
        }
    }

    // MARK: Storage

    private var storageSection: some View {
        Section {
            Picker("Keep recordings", selection: $keepDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("Until I delete them").tag(0)
            }
            .onChange(of: keepDays) { _, days in
                guard loaded, !model.isDemo else { return }
                AppSettings.shared.keepAudioDays = days
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("After a meeting's email has been sent, its audio is erased once it is this old. Transcripts and notes stay until you delete the meeting. An hour of audio takes about 115 MB.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            Button("Share diagnostics") {
                if let url = model.diagnosticsFile() { share = ShareItem(url: url) }
            }
        } header: {
            Text("Help")
        } footer: {
            Text("Diagnostics list the app's recent activity and timings. They contain no audio, no transcript text and no passwords; your email address may appear.\n\nMinutes \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
        }
    }

    // MARK: Loading

    private func load() {
        guard !loaded else { return }
        address = model.mail.address
        recipient = model.mail.recipient
        host = model.mail.host
        port = String(model.mail.port)
        keepDays = model.isDemo ? 30 : AppSettings.shared.keepAudioDays
        if model.isDemo {
            languageModel = "Apple Intelligence is ready to write notes"
            languageModelOK = true
        } else {
            switch FoundationNotesModel.make() {
            case .success:
                languageModel = "Apple Intelligence is ready to write notes"
                languageModelOK = true
            case .failure(let reason):
                languageModel = MeetingPipeline.describe(reason) + " Until then, Minutes emails the transcript without notes."
                languageModelOK = false
            }
        }
        // Set last so the first assignment to keepDays above isn't written back.
        DispatchQueue.main.async { loaded = true }
    }
}
