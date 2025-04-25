import KeyboardShortcuts
import SwiftUI

struct KeyboardsSettingsView: View {
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "createdAt", ascending: true)])
    var hotKeyGroups: FetchedResults<HotKeyGroup>

    @EnvironmentObject var preferencesVM: PreferencesVM
    @EnvironmentObject var indicatorVM: IndicatorVM

    let imgSize: CGFloat = 16

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                normalSection
                groupSection
                AddSwitchingGroupButton(onSelect: preferencesVM.addHotKeyGroup)
            }
            .padding()
        }
        .background(NSColor.background1.color)
    }

    var normalSection: some View {
        ForEach(InputSource.sources, id: \.id) { inputSource in
            SettingsSection(title: "") {
                HStack {
                    CustomizedIndicatorView(inputSource: inputSource)
                        .help(inputSource.id)

                    Spacer()

                    KeyboardShortcuts.Recorder(for: .init(inputSource.id), onChange: { _ in
                        indicatorVM.refreshShortcut()
                    })
                }
                .padding()
            }
            .padding(.bottom)
        }
    }

    var groupSection: some View {
        ForEach(hotKeyGroups, id: \.self) { group in
            SettingsSection(title: "") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        ForEach(group.inputSources, id: \.id) { inputSource in
                            CustomizedIndicatorView(inputSource: inputSource)
                                .help(inputSource.id)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing) {
                        KeyboardShortcuts.Recorder(for: .init(group.id!), onChange: { _ in
                            indicatorVM.refreshShortcut()
                        })

                        HStack {
                            Button("Delete".i18n()) {
                                deleteGroup(group: group)
                            }
                        }
                    }
                }
                .padding()
            }
            .padding(.bottom)
        }
    }

    func deleteGroup(group: HotKeyGroup) {
        KeyboardShortcuts.reset([.init(group.id!)])
        preferencesVM.deleteHotKeyGroup(group)
        indicatorVM.refreshShortcut()
    }
}
