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
            vocabularySection
            calendarSection
            peopleSection
            hubspotSection
            microphoneSection
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
            TextField("Send notes to (optional)", text: $recipient)
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
                ? "Notes and transcripts are sent from this account as soon as a meeting has been processed. Leave \"Send notes to\" empty to send them to the same address; separate several addresses with commas."
                : "Minutes sends the notes through your own mail account, so there is no service in between and nothing to pay for. Leave \"Send notes to\" empty to send them to the same address.")
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
        let stored = model.saveMail(
            address: address, recipient: recipient, password: password.isEmpty ? nil : password,
            host: host, port: Int(port.trimmingCharacters(in: .whitespaces)))
        guard stored else {
            testing = false
            testFailed = true
            testResult = "The password couldn't be saved in this iPhone's Keychain. Restart the iPhone and try again; if it keeps happening, reinstall Minutes."
            return
        }
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
                    Text(model.setup.preparing
                        ? "Preparing the models for this iPhone. This takes a minute or two and happens once."
                        : "Keep Minutes open until both finish.")
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

    // MARK: Vocabulary

    @State private var rawMicrophone = AppSettings.shared.rawMicrophone

    private var microphoneSection: some View {
        Section {
            Picker("Microphone", selection: $rawMicrophone) {
                Text("Standard").tag(false)
                Text("Raw").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: rawMicrophone) { _, on in AppSettings.shared.rawMicrophone = on }
        } header: {
            Text("Microphone")
        } footer: {
            Text("Standard lets iOS adjust the microphone as it does for calls. Raw turns that off and records the room as it is, which may keep a quieter voice across the table from being flattened in a loud room. Try Raw for one noisy meeting and compare.")
        }
    }

    // MARK: People

    private var peopleSection: some View {
        Section {
            NavigationLink(value: Route.people) {
                HStack {
                    Text("People")
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(model.directory.isEmpty ? "None yet" : "\(model.directory.count)")
                        .foregroundStyle(Theme.muted)
                }
            }
        } header: {
            Text("People")
        } footer: {
            Text("The people you meet with, with the email, company and title HubSpot needs. A meeting's people are filled in from here by name; what you type on a meeting is remembered here.")
        }
    }

    // MARK: HubSpot

    @State private var hubspotBatch = false
    @State private var hubspotSending = false
    @State private var hubspotProgress: String?

    @State private var hubspotToken = ""
    @State private var hubspotSaved = !AppSettings.shared.hubspotToken.isEmpty
    @State private var hubspotChecking = false
    @State private var hubspotResult: String?
    @State private var hubspotFailed = false

    private var hubspotSection: some View {
        Section {
            SecureField(hubspotSaved ? "Access token (saved)" : "Private app access token", text: $hubspotToken)
                .textContentType(.password)
                .autocorrectionDisabled()
            Button {
                Task { await saveAndCheckHubSpot() }
            } label: {
                HStack(spacing: 10) {
                    if hubspotChecking { ProgressView() }
                    Text(hubspotChecking ? "Checking" : "Save and check the connection")
                }
            }
            .disabled(hubspotChecking || (hubspotToken.isEmpty && !hubspotSaved))
            if let hubspotResult {
                Label(hubspotResult, systemImage: hubspotFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(hubspotFailed ? Theme.record : Theme.ok)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hubspotSaved {
                let ready = model.meetingsReadyForHubSpot.count
                Button {
                    hubspotBatch = true
                } label: {
                    HStack(spacing: 10) {
                        if hubspotSending { ProgressView() }
                        Text(hubspotSending ? (hubspotProgress ?? "Sending") : "Send all finished meetings (\(ready))")
                    }
                }
                .disabled(hubspotSending || ready == 0)
                .confirmationDialog("Send \(ready) meeting\(ready == 1 ? "" : "s") to HubSpot?", isPresented: $hubspotBatch, titleVisibility: .visible) {
                    Button("Send to HubSpot") { Task { await sendAllToHubSpot() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every finished meeting not yet in HubSpot whose people have an email address: the contacts HubSpot does not have are created, and each meeting is logged with its notes on their records.")
                }
                Button("Remove the token", role: .destructive) {
                    AppSettings.shared.hubspotToken = ""
                    hubspotSaved = false
                    hubspotToken = ""
                    hubspotResult = nil
                }
            }
        } header: {
            Text("HubSpot")
        } footer: {
            Text("A HubSpot private app's access token (HubSpot Settings > Integrations > Private Apps; it needs the contacts read and write scopes). With it, a meeting's screen can add the people met as contacts and log the meeting with the notes on their records. Nothing is sent until you tap that. The token is kept in this iPhone's Keychain.")
        }
    }

    private func sendAllToHubSpot() async {
        hubspotSending = true
        hubspotProgress = nil
        let report = await model.pushAllToHubSpot { hubspotProgress = $0 }
        hubspotSending = false
        hubspotProgress = nil
        hubspotFailed = report.contains("Not sent")
        hubspotResult = report
    }

    private func saveAndCheckHubSpot() async {
        hubspotChecking = true
        hubspotResult = nil
        let token = hubspotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            AppSettings.shared.hubspotToken = token
            hubspotSaved = true
            hubspotToken = ""
        }
        do {
            try await HubSpotClient(token: AppSettings.shared.hubspotToken).check()
            hubspotFailed = false
            hubspotResult = "Connected to HubSpot."
        } catch {
            hubspotFailed = true
            hubspotResult = error.localizedDescription
        }
        hubspotChecking = false
    }

    // MARK: Calendar

    @State private var usesCalendar = AppSettings.shared.usesCalendar
    @State private var calendarAccess = MeetingCalendar.shared.access

    private var calendarSection: some View {
        Section {
            Toggle("Use the calendar", isOn: $usesCalendar)
                .onChange(of: usesCalendar) { _, on in
                    AppSettings.shared.usesCalendar = on
                    guard on, MeetingCalendar.shared.access == .notAsked else { return }
                    Task {
                        _ = await MeetingCalendar.shared.requestAccess()
                        calendarAccess = MeetingCalendar.shared.access
                    }
                }
            if usesCalendar, calendarAccess == .denied {
                Text("Calendar access is off for Minutes. Turn it on in the iPhone's Settings, under Minutes.")
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("When a recording starts during a meeting on your calendar, the meeting takes that name and the people invited fill the \"With\" list. Google and other calendars added to this iPhone are included. Nothing is written to the calendar.")
        }
        .onAppear { calendarAccess = MeetingCalendar.shared.access }
    }

    private var vocabularySection: some View {
        Section {
            NavigationLink(value: Route.vocabulary) {
                HStack {
                    Text("Vocabulary")
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(model.vocabulary.terms.isEmpty ? "None yet" : "\(model.vocabulary.terms.count)")
                        .foregroundStyle(Theme.muted)
                }
            }
        } header: {
            Text("Names and terms")
        } footer: {
            Text("Company names, people and the terms of your work that come out wrong in transcripts. Minutes corrects them and spells them right in the notes.")
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
