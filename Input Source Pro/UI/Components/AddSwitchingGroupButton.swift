import SwiftUI

struct AddSwitchingGroupButton: View {
    @State var isActive = false
    @State var selections = Set<String>()

    let onSelect: ([InputSource]) -> Void

    var body: some View {
        Button("Add Switch Group".i18n(), systemImage: "plus.circle") {
            isActive = true
        }
        .sheet(isPresented: $isActive, content: {
            VStack(alignment: .leading) {
                Text("Select Input Sources".i18n())
                    .font(.title)
                    .padding(.bottom, 4)

                Text("Add a switch group to allow switching between multiple input sources using the same hotkey. Select at least two input sources.".i18n())
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .frame(width: 500)

                VStack(alignment: .leading) {
                    ForEach(InputSource.sources, id: \.persistentIdentifier) { inputSource in
                        VStack(alignment: .leading) {
                            HStack(spacing: 6) {
                                if selections.contains(inputSource.persistentIdentifier) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color.accentColor)
                                        .font(.system(size: 16))
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundColor(.gray)
                                        .font(.system(size: 16))
                                }

                                Text(inputSource.name)
                            }
                            .frame(height: 12)

                            Divider()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selections.contains(inputSource.persistentIdentifier) {
                                selections.remove(inputSource.persistentIdentifier)
                            } else {
                                selections.insert(inputSource.persistentIdentifier)
                            }
                        }
                    }
                }
                .padding(.vertical)

                HStack {
                    Spacer()

                    Button("Cancel".i18n()) { hide() }
                        .keyboardShortcut(.cancelAction)
                    Button("Add".i18n()) { add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selections.count < 2)
                }
            }
            .padding()
        })
    }

    func add() {
        onSelect(InputSource.sources.filter { selections.contains($0.persistentIdentifier) })
        hide()
    }

    func hide() {
        isActive = false
        selections.removeAll()
    }
}

struct MultipleSelectionRow: View {
    var title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(self.title)
                if self.isSelected {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}
