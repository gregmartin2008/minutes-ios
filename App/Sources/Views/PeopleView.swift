import MinutesCore
import SwiftUI

/// The people Minutes knows by name, with the details HubSpot needs. Filled from what is typed
/// on meetings, or pasted in as "Name, email, company, title, phone" lines.
struct PeopleView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: Int?
    @State private var adding = false
    @State private var importing = false

    var body: some View {
        List {
            Section {
                if model.directory.isEmpty {
                    Text("No one yet. Add people here, paste a list, or add them on a meeting's screen: they are remembered for the next meeting with the same name.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .listRowBackground(Theme.paper)
                } else {
                    ForEach(Array(model.directory.enumerated()), id: \.offset) { i, p in
                        Button {
                            editing = i
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                Text(detail(p))
                                    .font(.footnote)
                                    .foregroundStyle(p.email == nil ? Theme.warn : Theme.muted)
                            }
                        }
                        .listRowBackground(Theme.paper)
                    }
                    .onDelete { offsets in
                        var list = model.directory
                        list.remove(atOffsets: offsets)
                        model.setDirectory(list)
                    }
                }
            } footer: {
                Text("A meeting's people are filled in from here by name. Swipe left to remove someone.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.paper.ignoresSafeArea())
        .tint(Theme.action)
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { adding = true } label: { Label("Add a person", systemImage: "person.badge.plus") }
                    Button { importing = true } label: { Label("Paste a list", systemImage: "doc.on.clipboard") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add people")
            }
        }
        .sheet(isPresented: $adding) {
            DirectoryPersonSheet(person: Person(name: ""), index: nil)
        }
        .sheet(item: Binding(get: { editing.map { IndexRef(index: $0) } }, set: { editing = $0?.index })) { ref in
            if model.directory.indices.contains(ref.index) {
                DirectoryPersonSheet(person: model.directory[ref.index], index: ref.index)
            }
        }
        .sheet(isPresented: $importing) {
            ImportPeopleSheet()
        }
    }

    private func detail(_ p: Person) -> String {
        var parts: [String] = []
        if let title = p.title, !title.isEmpty { parts.append(title) }
        if let company = p.company, !company.isEmpty { parts.append(company) }
        parts.append(p.email ?? "no email")
        return parts.joined(separator: " · ")
    }
}

private struct IndexRef: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Adds or edits one directory entry.
private struct DirectoryPersonSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var person: Person
    let index: Int?
    @State private var email = ""
    @State private var company = ""
    @State private var title = ""
    @State private var phone = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $person.name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($focused)
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Company", text: $company)
                        .textContentType(.organizationName)
                        .textInputAutocapitalization(.words)
                    TextField("Title", text: $title)
                        .textContentType(.jobTitle)
                        .textInputAutocapitalization(.words)
                    TextField("Phone", text: $phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                }
            }
            .navigationTitle(index == nil ? "Add a person" : "Edit person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(person.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                email = person.email ?? ""
                company = person.company ?? ""
                title = person.title ?? ""
                phone = person.phone ?? ""
                focused = index == nil
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var p = person
        p.name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.email = clean(email)?.lowercased()
        p.company = clean(company)
        p.title = clean(title)
        p.phone = clean(phone)
        var list = model.directory
        if let index, list.indices.contains(index) {
            list[index] = p
            model.setDirectory(list)
        } else {
            model.remember(p)
        }
        dismiss()
    }
}

/// Pastes a list of people, one per line.
private struct ImportPeopleSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .font(.system(size: 14, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("One person per line")
                } footer: {
                    Text("Name, email, company, title, phone — separated by commas (or tabs). Everything after the name is optional. People already in the list are updated with what they were missing.")
                }
                if let result {
                    Section { Text(result).foregroundStyle(Theme.ok) }
                }
            }
            .navigationTitle("Paste a list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let n = model.importDirectory(text)
                        result = "\(n) \(n == 1 ? "person" : "people") added or updated."
                        text = ""
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}
