import LintelCore
import SwiftUI

/// Settings → Calendar: the master switch and calendar access, the island and open-card options,
/// Quick Peek, sounds, time to leave and the calendars list (Calendar
/// tab). Without calendar access only the switch and the way to grant access are shown.
struct CalendarSettingsView: View {
    let settings: SettingsStore

    var body: some View {
        if let feature = CalendarFeature.shared {
            CalendarSettingsForm(settings: settings, feature: feature)
        } else {
            Form { Text("Calendar isn't available.").foregroundStyle(.secondary) }
                .formStyle(.grouped)
                .navigationTitle("Calendar")
        }
    }
}

private struct CalendarSettingsForm: View {
    let settings: SettingsStore
    let feature: CalendarFeature

    private var agenda: CalendarAgenda { feature.agenda }
    private var enabled: Bool { settings[Keys.calendarEnabled] }

    var body: some View {
        Form {
            Section {
                Toggle("Show calendar events", isOn: settings.binding(Keys.calendarEnabled))
                if enabled { accessRow }
            } header: {
                Text("Calendar")
            } footer: {
                Text("Lintel only reads your calendars to show what's next. It never changes them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if enabled, agenda.access.canRead {
                islandSection
                peekSection
                cardSection
                soundSection
                leaveSection
                calendarSections
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendar")
        .onAppear { agenda.refreshAccess() }
    }

    // MARK: Access

    @ViewBuilder private var accessRow: some View {
        switch agenda.access {
        case .fullAccess:
            EmptyView()
        case .notDetermined:
            LabeledContent("Lintel needs to see your calendars") {
                Button("Allow Access…") { feature.requestCalendarAccess() }
            }
        case .denied, .restricted, .writeOnly:
            LabeledContent("Calendar access is turned off") {
                Button("Open Privacy Settings…") { feature.openPrivacySettings(location: false) }
            }
        }
    }

    // MARK: Island

    private var islandSection: some View {
        Section {
            MinutesSlider(title: "Count down from", value: settings.binding(Keys.calendarLeadMinutes), range: 5...60, step: 5)
            Toggle("Colour the icon like its calendar", isOn: settings.binding(Keys.calendarTintIcon))
            Toggle("Hide while an event is under way", isOn: settings.binding(Keys.calendarHideDuringEvents))
        } header: {
            Text("In the island")
        } footer: {
            Text("The island counts down to your next event, then shows how far along it is.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var peekSection: some View {
        let peek = settings[Keys.calendarPeek]
        return Section {
            Toggle("Quick Peek", isOn: settings.binding(Keys.calendarPeek))
            Toggle("When the countdown starts", isOn: settings.binding(Keys.calendarPeekBefore)).disabled(!peek)
            Toggle("When an event starts", isOn: settings.binding(Keys.calendarPeekAtStart)).disabled(!peek)
            SecondsSlider(title: "Peek for", value: settings.binding(Keys.calendarPeekDuration), range: 1...10).disabled(!peek)
        } header: {
            Text("Quick Peek")
        } footer: {
            Text("Shows the event's name for a moment.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Open card

    private var cardSection: some View {
        let monthView = settings[Keys.calendarMonthView]
        return Section {
            Toggle("Colour event names", isOn: settings.binding(Keys.calendarTintTitles))
            Toggle("Show this month instead of tomorrow", isOn: settings.binding(Keys.calendarMonthView))
            Toggle("Mark days that have events", isOn: settings.binding(Keys.calendarEventDots)).disabled(!monthView)
            Toggle("Show the weather on free days", isOn: locationBinding(.weatherOnFreeDay))
            locationNote(for: .weatherOnFreeDay)
            Picker("Open events in", selection: settings.binding(Keys.calendarApp)) {
                ForEach(appChoices, id: \.self) { choice in
                    Text(feature.installedApps.contains(choice) ? choice.title : "\(choice.title) (not installed)").tag(choice)
                }
            }
        } header: {
            Text("Open card")
        } footer: {
            Text("Weather by Open-Meteo.com (CC BY 4.0). Only your approximate location, rounded to about 1 km, is sent.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var appChoices: [CalendarAppChoice] {
        let chosen = settings[Keys.calendarApp]
        return CalendarAppChoice.allCases.filter { feature.installedApps.contains($0) || $0 == chosen }
    }

    // MARK: Sounds

    private var soundSection: some View {
        Section("Sounds") {
            SoundToggleRow(title: "Play a sound when an event starts", isOn: settings.binding(Keys.calendarStartSound),
                           cue: .eventStart, tones: feature.tones)
            SoundToggleRow(title: "Chime on the hour", isOn: settings.binding(Keys.calendarHourlyChime),
                           cue: .hourlyChime, tones: feature.tones)
        }
    }

    // MARK: Time to leave

    private var leaveSection: some View {
        let on = settings[Keys.timeToLeaveEnabled]
        return Section {
            Toggle("Tell me when it's time to leave", isOn: locationBinding(.timeToLeave))
            locationNote(for: .timeToLeave)
            Picker("Getting there by", selection: settings.binding(Keys.timeToLeaveMode)) {
                ForEach(TravelMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .disabled(!on)
            MinutesSlider(title: "Extra time", value: settings.binding(Keys.timeToLeaveBufferMinutes), range: 0...30, step: 5)
                .disabled(!on)
            SecondsSlider(title: "Alert stays for", value: settings.binding(Keys.duration(.timeToLeave)), range: 3...15)
                .disabled(!on)
            SoundToggleRow(title: "Play a sound", isOn: settings.binding(Keys.timeToLeaveSound), cue: .leaveNow, tones: feature.tones)
                .disabled(!on)
        } header: {
            Text("Time to leave")
        } footer: {
            Text("For events with a place. Travel times come from Apple Maps, from where you are now.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Calendars

    @ViewBuilder private var calendarSections: some View {
        let accounts = Dictionary(grouping: agenda.calendars, by: \.account)
        ForEach(accounts.keys.sorted(), id: \.self) { account in
            Section(account.isEmpty ? "Calendars" : account) {
                ForEach((accounts[account] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) { entry in
                    CalendarRow(entry: entry, settings: settings)
                }
            }
        }
    }

    // MARK: Location-dependent toggles

    private func locationBinding(_ target: LocationPermissionTarget) -> Binding<Bool> {
        let key = CalendarFeature.key(for: target) ?? Keys.calendarWeatherOnFreeDay
        return Binding(get: { settings[key] || settings[Keys.locationPendingTarget] == target },
                       set: { feature.setLocationFeature(target, on: $0) })
    }

    @ViewBuilder private func locationNote(for target: LocationPermissionTarget) -> some View {
        let key = CalendarFeature.key(for: target) ?? Keys.calendarWeatherOnFreeDay
        let pending = settings[Keys.locationPendingTarget] == target
        if settings[key] || pending {
            switch feature.locationAccess {
            case .authorized:
                EmptyView()
            case .notDetermined where pending:
                Text("Waiting for permission to use your location…").font(.footnote).foregroundStyle(.secondary)
            case .notDetermined:
                LabeledContent("This needs your location") {
                    Button("Allow…") { feature.setLocationFeature(target, on: true) }
                }
                .font(.footnote)
            case .denied, .restricted, .servicesOff:
                LabeledContent(feature.locationAccess == .servicesOff ? "Location Services are off" : "Location access is turned off") {
                    Button("Open Privacy Settings…") { feature.openPrivacySettings(location: true) }
                }
                .font(.footnote)
            }
        }
    }
}

/// One calendar: colour, name, where it appears, and whether it is included.
private struct CalendarRow: View {
    let entry: CalendarListEntry
    let settings: SettingsStore

    var body: some View {
        let included = !settings[Keys.calendarExclusions].ids.contains(entry.id)
        HStack(spacing: 8) {
            Circle().fill(Color(eventColor: entry.color)).frame(width: 10, height: 10)
            Text(entry.title).lineLimit(1)
            Spacer()
            Picker("Show in", selection: mode) {
                ForEach(CalendarDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!included)
            Toggle("Include \(entry.title)", isOn: includedBinding).labelsHidden()
        }
    }

    private var includedBinding: Binding<Bool> {
        Binding(get: { !settings[Keys.calendarExclusions].ids.contains(entry.id) },
                set: { included in
                    var exclusions = settings[Keys.calendarExclusions]
                    if included { exclusions.ids.remove(entry.id) } else { exclusions.ids.insert(entry.id) }
                    settings[Keys.calendarExclusions] = exclusions
                })
    }

    private var mode: Binding<CalendarDisplayMode> {
        Binding(get: { settings[Keys.calendarModes].mode(for: entry.id) },
                set: { mode in
                    var modes = settings[Keys.calendarModes]
                    modes.modes[entry.id] = mode == .both ? nil : mode
                    settings[Keys.calendarModes] = modes
                })
    }
}

/// A switch with a button that previews its sound.
private struct SoundToggleRow: View {
    let title: String
    let isOn: Binding<Bool>
    let cue: ToneCue
    let tones: TonePlayer

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Button {
                    tones.play(cue)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Play")
                .accessibilityLabel("Play \(title.lowercased())")
                Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

/// Minutes slider with a value readout ("15 min").
private struct MinutesSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double = 1

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 180)
                Text("\(Int(value.wrappedValue.rounded())) min")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}
