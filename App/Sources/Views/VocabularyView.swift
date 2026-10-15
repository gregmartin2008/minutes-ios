import MinutesCore
import SwiftUI

/// Names and terms the recognizer gets wrong, and how it has been heard saying them.
struct VocabularyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: VocabularyTerm?
    @State private var adding = false
    @State private var listens = AppSettings.shared.listensForVocabulary

    var body: some View {
        List {
            Section {
                Toggle("Listen for these terms in the audio", isOn: $listens)
                    .onChange(of: listens) { _, on in AppSettings.shared.listensForVocabulary = on }
                    .listRowBackground(Theme.paper)
            } footer: {
                Text("Experimental. A second, small model listens for the terms and known names and corrects the transcript where it hears one. Off by default: loading it has crashed the app on some iPhones. The typed spelling corrections below work either way.")
            }
            Section {
                if model.vocabulary.terms.isEmpty {
                    Text("No terms yet. Add the names of your firm, your companies and the people you meet with, and the spellings Minutes has used for them.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .listRowBackground(Theme.paper)
                } else {
                    ForEach(model.vocabulary.terms) { term in
                        Button {
                            editing = term
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(term.term)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                Text(term.heardAs.isEmpty
                                    ? "Spelled this way in the notes"
                                    : "Heard as " + term.heardAs.joined(separator: ", "))
                                    .font(.footnote)
                                    .foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .listRowBackground(Theme.paper)
                    }
                    .onDelete { offsets in
                        offsets.map { model.vocabulary.terms[$0].id }.forEach { model.removeTerm($0) }
                    }
                }
            } header: {
                Text("Your terms")
            } footer: {
                Text("A term's misheard spellings are replaced in every transcript from now on, and the notes use the spelling you give. Earlier meetings are not changed.")
            }

            Section {
                ForEach(Vocabulary.builtIn) { term in
                    HStack(alignment: .firstTextBaseline) {
                        Text(term.term)
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Text(term.heardAs.prefix(3).joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.trailing)
                    }
                    .listRowBackground(Theme.paper)
                }
            } header: {
                Text("Built in")
            } footer: {
                Text("Terms of business and finance that are corrected for everyone.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .tint(Theme.action)
        .navigationTitle("Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a term")
            }
        }
        .sheet(isPresented: $adding) {
            TermSheet(term: VocabularyTerm(term: ""), isNew: true)
        }
        .sheet(item: $editing) { term in
            TermSheet(term: term, isNew: false)
        }
    }
}

/// Adds or edits one term.
private struct TermSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var term: String
    @State private var heard: String
    private let id: UUID
    private let isNew: Bool

    init(term: VocabularyTerm, isNew: Bool) {
        id = term.id
        self.isNew = isNew
        _term = State(initialValue: term.term)
        _heard = State(initialValue: term.heardAs.joined(separator: ", "))
    }

    private var canSave: Bool { !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Correct spelling", text: $term)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The name or term as it should appear, for example Soterra or Estée Lauder.")
                }
                Section {
                    TextField("Heard as, separated by commas", text: $heard, axis: .vertical)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...5)
                } footer: {
                    Text("How it came out in a transcript, for example Sotera, Sotero. Whole words only, so a short spelling never changes part of a longer word. Leave empty to only fix the spelling in the notes.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.paper.ignoresSafeArea())
            .tint(Theme.action)
            .navigationTitle(isNew ? "New term" : "Edit term")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let variants = heard.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init)
                        model.saveTerm(VocabularyTerm(id: id, term: term, heardAs: variants))
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
