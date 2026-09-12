import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var store = AgendaStore()

    @State private var weekStart = Self.monday(containing: Date())
    @State private var selectedTemplateID: UUID?
    @State private var showNewBlock = false
    @State private var templateToEdit: BlockTemplate?
    @State private var eventToEdit: AgendaEvent?
    @State private var statusText: String?
    @State private var highlightedDrop: DropTarget?
    @State private var weekSlideDirection: Int = 1
    @State private var showWeekend = false
    @State private var sidebarCollapsed = false
    @State private var showFullDay = false
    @State private var quickTimeEvent: AgendaEvent?
    @State private var showPhoneBlocks = false

    private let calendar = Calendar.current
    private let headerHeight: CGFloat = 48

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 650
            let expandedSidebarWidth: CGFloat = geometry.size.width < 950 ? 170 : 220
            let sidebarWidth: CGFloat = compact ? 0 : (sidebarCollapsed ? 50 : expandedSidebarWidth)
            let timeWidth: CGFloat = compact ? 46 : (geometry.size.width < 950 ? 52 : 64)
            let calendarWidth = max(200, geometry.size.width - sidebarWidth - (compact ? 0 : 1))
            let dayCount = showWeekend ? 7 : 5
            let dayWidth = max(30, (calendarWidth - timeWidth) / CGFloat(dayCount))
            let usableHeight = max(570, geometry.size.height - (compact ? 106 : 64))
            let regularRowHeight = max(12.0, (usableHeight - headerHeight - 24) / 48.0)
            let rowHeight: CGFloat = showFullDay ? (compact ? 18 : 20) : regularRowHeight
            let visibleStartSlot = showFullDay ? -32 : 0
            let visibleSlotCount = showFullDay ? 96 : 48

            VStack(spacing: 0) {
                topBar(compact: compact)

                Divider()

                HStack(alignment: .top, spacing: 0) {
                    if !compact {
                        sidebar(compact: false)
                            .frame(width: sidebarWidth)

                        Divider()
                    }

                    calendarView(
                        rowHeight: rowHeight,
                        dayWidth: dayWidth,
                        timeWidth: timeWidth,
                        dayCount: dayCount,
                        visibleStartSlot: visibleStartSlot,
                        visibleSlotCount: visibleSlotCount
                    )
                    .id("\(weekStart.timeIntervalSince1970)-\(showWeekend)")
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: weekSlideDirection > 0 ? .trailing : .leading)
                                .combined(with: .opacity),
                            removal: .move(edge: weekSlideDirection > 0 ? .leading : .trailing)
                                .combined(with: .opacity)
                        )
                    )
                    .simultaneousGesture(weekSwipeGesture)
                }
                .animation(.easeInOut(duration: 0.28), value: weekStart)
            }
            .overlay(alignment: .bottom) {
                if compact && showPhoneBlocks {
                    phoneBlocksDrawer
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .sheet(isPresented: $showNewBlock) {
            BlockEditorView(
                title: "Nuovo blocco",
                initialName: "",
                initialDurationSlots: 4,
                initialColorHex: "#B8DFF5",
                initialRepeatWeeks: nil,
                initialReminderMinutes: nil,
                initialLocation: nil,
                showDelete: false,
                onSave: { name, duration, color, repeatWeeks, reminderMinutes, location in
                    store.addTemplate(
                        name: name,
                        durationSlots: duration,
                        colorHex: color,
                        repeatWeeks: repeatWeeks,
                        reminderMinutes: reminderMinutes,
                        location: location
                    )
                },
                onDelete: nil
            )
        }
        .sheet(item: $templateToEdit) { template in
            BlockEditorView(
                title: "Modifica blocco",
                initialName: template.name,
                initialDurationSlots: template.durationSlots,
                initialColorHex: template.colorHex,
                initialRepeatWeeks: template.repeatWeeks,
                initialReminderMinutes: template.reminderMinutes,
                initialLocation: template.location,
                showDelete: true,
                onSave: { name, duration, color, repeatWeeks, reminderMinutes, location in
                    let updated = BlockTemplate(
                        id: template.id,
                        name: name,
                        durationSlots: duration,
                        colorHex: color,
                        repeatWeeks: repeatWeeks,
                        reminderMinutes: reminderMinutes,
                        location: location
                    )
                    store.updateTemplate(updated)

                    if selectedTemplateID == template.id {
                        selectedTemplateID = nil
                    }
                },
                onDelete: {
                    store.deleteTemplate(template)

                    if selectedTemplateID == template.id {
                        selectedTemplateID = nil
                    }
                }
            )
        }
        .sheet(item: $eventToEdit) { event in
            EventEditorView(
                event: event,
                onSave: { updated in
                    store.updateEvent(updated)
                },
                onDelete: {
                    store.deleteEvent(event)
                }
            )
        }
        .sheet(item: $quickTimeEvent) { event in
            QuickTimePickerView(event: event) { newStartSlot in
                var updated = event
                updated.startSlot = newStartSlot
                return store.updateEvent(updated)
            }
        }
    }

    @ViewBuilder
    private func topBar(compact: Bool) -> some View {
        if compact {
            VStack(spacing: 5) {
                HStack {
                    Label("Agenda", systemImage: "calendar")
                        .font(.headline.bold())

                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showPhoneBlocks.toggle()
                        }
                    } label: {
                        Label("Blocchi", systemImage: "square.grid.2x2")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .tint(.indigo)

                    Spacer()

                    Button {
                        weekSlideDirection = currentWeekDirection
                        withAnimation(.easeInOut(duration: 0.28)) {
                            weekStart = Self.monday(containing: Date())
                        }
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isCurrentWeek ? Color.secondary : Color.indigo)
                    .disabled(isCurrentWeek)
                }

                HStack(spacing: 8) {
                    Button { changeWeek(by: -1) } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 2)

                    VStack(spacing: 0) {
                        Text(weekLabel)
                            .font(.subheadline.bold())
                            .monospacedDigit()
                        Text(monthLabel)
                            .font(.caption2.bold())
                            .foregroundStyle(.indigo)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)

                    Button { changeWeek(by: 1) } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.background)
        } else {
            ZStack {
                HStack {
                    Label("Agenda a blocchi", systemImage: "calendar")
                        .font(.title3.bold())

                    Spacer()

                    Button {
                        weekSlideDirection = currentWeekDirection
                        withAnimation(.easeInOut(duration: 0.28)) {
                            weekStart = Self.monday(containing: Date())
                        }
                    } label: {
                        Label("Torna a oggi", systemImage: "calendar.badge.clock")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isCurrentWeek ? Color.secondary : Color.indigo)
                    .disabled(isCurrentWeek)
                    .opacity(isCurrentWeek ? 0.65 : 1.0)
                }

                HStack(spacing: 14) {
                    Button { changeWeek(by: -1) } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)

                    VStack(spacing: 0) {
                        Text("Settimana")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(weekLabel)
                            .font(.headline)
                            .monospacedDigit()
                        Text(monthLabel)
                            .font(.caption.bold())
                            .foregroundStyle(.indigo)
                            .padding(.top, 1)
                    }
                    .frame(minWidth: 210)
                    .contentTransition(.numericText())

                    Button { changeWeek(by: 1) } label: {
                        Image(systemName: "chevron.right")
                            .font(.headline)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.background)
        }
    }

    private var isCurrentWeek: Bool {
        let currentMonday = Self.monday(containing: Date())
        return calendar.isDate(weekStart, inSameDayAs: currentMonday)
    }

    private var currentWeekDirection: Int {
        let currentMonday = Self.monday(containing: Date())
        return weekStart < currentMonday ? 1 : -1
    }

    private var weekSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)

                guard abs(horizontal) > 70, abs(horizontal) > vertical * 1.35 else {
                    return
                }

                // Lo swipe richiama esattamente lo stesso cambio settimana delle frecce.
                changeWeek(by: horizontal < 0 ? 1 : -1)
            }
    }

    private func changeWeek(by direction: Int) {
        weekSlideDirection = direction

        withAnimation(.easeInOut(duration: 0.28)) {
            weekStart = calendar.date(
                byAdding: .day,
                value: direction * 7,
                to: weekStart
            ) ?? weekStart
        }
    }

    private var monthLabel: String {
        let end = calendar.date(byAdding: .day, value: showWeekend ? 6 : 4, to: weekStart) ?? weekStart

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "LLLL"

        let startMonth = formatter.string(from: weekStart).capitalized
        let endMonth = formatter.string(from: end).capitalized

        if calendar.component(.month, from: weekStart) == calendar.component(.month, from: end) {
            return startMonth
        }

        return "\(startMonth) – \(endMonth)"
    }

    private var phoneBlocksDrawer: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 38, height: 5)
                .padding(.top, 6)

            HStack {
                Label("Blocchi", systemImage: "square.grid.2x2")
                    .font(.headline.bold())
                Spacer()
                Button {
                    showNewBlock = true
                } label: {
                    Label("Nuovo", systemImage: "plus")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)

                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showPhoneBlocks = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("Trascina un blocco sul giorno e sull’orario desiderato.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(store.templates) { template in
                        phoneTemplateCard(template)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 104)

            if let selected = selectedTemplate {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                    Text("Inserimento rapido: \(selected.name)")
                        .lineLimit(1)
                    Spacer()
                    Button {
                        selectedTemplateID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .shadow(radius: 12, y: 4)
    }

    private func phoneTemplateCard(_ template: BlockTemplate) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: template.colorHex))
                    .frame(width: 9, height: 28)

                Text(template.name)
                    .font(.caption.bold())
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    templateToEdit = template
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(durationText(template.durationSlots))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 132, height: 86, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(selectedTemplateID == template.id ? Color.indigo.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTemplateID = selectedTemplateID == template.id ? nil : template.id
        }
        .onDrag {
            NSItemProvider(object: NSString(string: DragPayload.template(template.id).stringValue))
        } preview: {
            dragPreview(name: template.name, durationSlots: template.durationSlots, colorHex: template.colorHex)
        }
    }

    @ViewBuilder
    private func sidebar(compact: Bool) -> some View {
        if sidebarCollapsed {
            VStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.20)) {
                        sidebarCollapsed = false
                    }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.indigo.opacity(0.10))

                        Image(systemName: "chevron.right")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.indigo)
                    }
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mostra blocchi")

                Image(systemName: "square.grid.2x2")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.background)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Button {
                    showNewBlock = true
                } label: {
                    Label("Aggiungi blocco", systemImage: "plus")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                HStack {
                    Text("Blocchi")
                        .font(.headline)

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.20)) {
                            sidebarCollapsed = true
                        }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.secondary.opacity(0.10))

                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Nascondi blocchi")
                }

                if !compact {
                    Text("Trascina un blocco nella settimana. Tocca ⋯ per modificarlo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.templates) { template in
                            templateCard(template)
                        }
                    }
                }

                Spacer(minLength: 0)

                if let selected = selectedTemplate {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.tap")
                        if !compact {
                            Text("Inserimento rapido: \(selected.name)")
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            selectedTemplateID = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.indigo.opacity(0.08))
                    )
                }
            }
            .padding(10)
            .background(.background)
        }
    }

    private func templateCard(_ template: BlockTemplate) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: template.colorHex))
                .frame(width: 12, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(template.name)
                    .font(.subheadline.bold())

                Text(durationText(template.durationSlots))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                templateToEdit = template
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    selectedTemplateID == template.id
                    ? Color.indigo.opacity(0.10)
                    : Color(uiColor: .secondarySystemGroupedBackground)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTemplateID = selectedTemplateID == template.id ? nil : template.id
            statusText = nil
        }
        .onDrag {
            NSItemProvider(
                object: NSString(string: DragPayload.template(template.id).stringValue)
            )
        } preview: {
            dragPreview(
                name: template.name,
                durationSlots: template.durationSlots,
                colorHex: template.colorHex
            )
        }
    }

    private func calendarView(
        rowHeight: CGFloat,
        dayWidth: CGFloat,
        timeWidth: CGFloat,
        dayCount: Int,
        visibleStartSlot: Int,
        visibleSlotCount: Int
    ) -> some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                dayHeader(dayWidth: dayWidth, timeWidth: timeWidth, dayCount: dayCount)

                if showFullDay {
                    ScrollView(.vertical) {
                        calendarGrid(
                            rowHeight: rowHeight,
                            dayWidth: dayWidth,
                            timeWidth: timeWidth,
                            dayCount: dayCount,
                            visibleStartSlot: visibleStartSlot,
                            visibleSlotCount: visibleSlotCount
                        )
                    }
                    .scrollIndicators(.visible)
                } else {
                    calendarGrid(
                        rowHeight: rowHeight,
                        dayWidth: dayWidth,
                        timeWidth: timeWidth,
                        dayCount: dayCount,
                        visibleStartSlot: visibleStartSlot,
                        visibleSlotCount: visibleSlotCount
                    )
                }
            }
            .background(.background)

            VStack(alignment: .trailing, spacing: 7) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showFullDay.toggle()
                    }
                } label: {
                    Label(
                        showFullDay ? "08–20" : "24 h",
                        systemImage: showFullDay ? "sun.max" : "clock.arrow.circlepath"
                    )
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.indigo.opacity(0.25), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.indigo)

                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showWeekend.toggle()
                    }
                } label: {
                    Label(
                        showWeekend ? "Nascondi weekend" : "Sab + Dom",
                        systemImage: showWeekend ? "calendar.badge.minus" : "calendar.badge.plus"
                    )
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.indigo.opacity(0.25), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.indigo)
            }
            .padding(10)
            .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        }
        .background(.background)
    }

    private func calendarGrid(
        rowHeight: CGFloat,
        dayWidth: CGFloat,
        timeWidth: CGFloat,
        dayCount: Int,
        visibleStartSlot: Int,
        visibleSlotCount: Int
    ) -> some View {
        HStack(spacing: 0) {
            timeColumn(
                rowHeight: rowHeight,
                timeWidth: timeWidth,
                visibleStartSlot: visibleStartSlot,
                visibleSlotCount: visibleSlotCount
            )

            ForEach(0..<dayCount, id: \.self) { dayIndex in
                dayColumn(
                    dayIndex: dayIndex,
                    rowHeight: rowHeight,
                    dayWidth: dayWidth,
                    visibleStartSlot: visibleStartSlot,
                    visibleSlotCount: visibleSlotCount
                )
            }
        }
    }

    private func dayHeader(dayWidth: CGFloat, timeWidth: CGFloat, dayCount: Int) -> some View {
        HStack(spacing: 0) {
            ZStack {
                Color(uiColor: .secondarySystemGroupedBackground)
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: timeWidth, height: headerHeight)

            ForEach(0..<dayCount, id: \.self) { dayIndex in
                let date = dateFor(dayIndex)
                let today = calendar.isDateInToday(date)
                let holiday = italianHolidayName(for: date)
                let observance = italianObservanceName(for: date)

                VStack(spacing: 0) {
                    Text(dayWidth < 64 ? compactDayName(date) : dayName(date))
                        .font(dayWidth < 64 ? .caption.bold() : .subheadline.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    Text(shortDate(date))
                        .font(.caption2.bold())
                        .foregroundStyle(today ? Color.indigo : Color.secondary)

                    if dayWidth >= 72, let holiday = holiday {
                        Text(holiday)
                            .font(.system(size: 8.2, weight: .semibold))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    } else if dayWidth >= 72, let observance = observance {
                        Text(observance)
                            .font(.system(size: 8.0, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                    }
                }
                .frame(width: dayWidth, height: headerHeight)
                .background(
                    holiday != nil
                    ? Color.red.opacity(0.055)
                    : (observance != nil
                       ? Color.orange.opacity(0.045)
                       : (today
                          ? Color.indigo.opacity(0.07)
                          : Color(uiColor: .secondarySystemGroupedBackground)))
                )
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.20))
                        .frame(width: 0.5)
                }
                .overlay(alignment: .bottom) {
                    if today {
                        Rectangle()
                            .fill(Color.indigo)
                            .frame(height: 2)
                    }
                }
            }
        }
    }

    private func timeColumn(
        rowHeight: CGFloat,
        timeWidth: CGFloat,
        visibleStartSlot: Int,
        visibleSlotCount: Int
    ) -> some View {
        let topBottomInset: CGFloat = 12
        let gridHeight = rowHeight * CGFloat(visibleSlotCount)

        return ZStack(alignment: .topTrailing) {
            Color(uiColor: .secondarySystemGroupedBackground)

            VStack(spacing: 0) {
                ForEach(0..<visibleSlotCount, id: \.self) { localSlot in
                    let slot = visibleStartSlot + localSlot
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: timeWidth, height: rowHeight)
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(
                                    slot % 4 == 0
                                    ? Color.secondary.opacity(0.48)
                                    : Color.secondary.opacity(0.20)
                                )
                                .frame(height: slot % 4 == 0 ? 1.2 : 0.6)
                        }
                }
            }
            .offset(y: topBottomInset)

            ForEach(0...visibleSlotCount, id: \.self) { boundary in
                let slot = visibleStartSlot + boundary
                Text(slotTime(slot))
                    .font(
                        .system(
                            size: slot % 4 == 0 ? (timeWidth <= 46 ? 10.0 : 10.5) : (timeWidth <= 46 ? 7.8 : 8.2),
                            weight: slot % 4 == 0 ? .bold : .regular,
                            design: .rounded
                        )
                    )
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(slot % 4 == 0 ? Color.primary : Color.secondary)
                    .padding(.horizontal, 2)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .offset(
                        x: -3,
                        y: topBottomInset + CGFloat(boundary) * rowHeight - 6
                    )
            }
        }
        .frame(width: timeWidth, height: gridHeight + topBottomInset * 2)
    }

    private func dayColumn(
        dayIndex: Int,
        rowHeight: CGFloat,
        dayWidth: CGFloat,
        visibleStartSlot: Int,
        visibleSlotCount: Int
    ) -> some View {
        let date = dateFor(dayIndex)
        let dateKey = Self.dateKey(date)
        let visibleEndSlot = visibleStartSlot + visibleSlotCount
        let items = store.events(on: dateKey).filter { event in
            event.startSlot < visibleEndSlot && event.startSlot + event.durationSlots > visibleStartSlot
        }
        let today = calendar.isDateInToday(date)
        let topBottomInset: CGFloat = 12
        let gridHeight = rowHeight * CGFloat(visibleSlotCount)

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<visibleSlotCount, id: \.self) { localSlot in
                    let slot = visibleStartSlot + localSlot
                    slotCell(
                        dateKey: dateKey,
                        slot: slot,
                        rowHeight: rowHeight,
                        dayWidth: dayWidth,
                        today: today
                    )
                }
            }
            .offset(y: topBottomInset)

            ForEach(items) { event in
                eventBlock(event, rowHeight: rowHeight, dayWidth: dayWidth)
                    .offset(y: topBottomInset + CGFloat(event.startSlot - visibleStartSlot) * rowHeight)
            }

            if let highlightedDrop,
               highlightedDrop.dateKey == dateKey,
               highlightedDrop.slot >= visibleStartSlot,
               highlightedDrop.slot < visibleEndSlot {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.indigo.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.indigo.opacity(0.75), lineWidth: 1.4)
                    )
                    .frame(width: dayWidth - 2, height: rowHeight)
                    .offset(
                        x: 1,
                        y: topBottomInset + CGFloat(highlightedDrop.slot - visibleStartSlot) * rowHeight
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(width: dayWidth, height: gridHeight + topBottomInset * 2, alignment: .topLeading)
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.text],
            delegate: DayAgendaDropDelegate(
                store: store,
                dateKey: dateKey,
                rowHeight: rowHeight,
                topInset: topBottomInset,
                visibleStartSlot: visibleStartSlot,
                visibleSlotCount: visibleSlotCount,
                highlightedDrop: $highlightedDrop,
                statusText: $statusText
            )
        )
        .clipped()
    }

    private func slotCell(
        dateKey: String,
        slot: Int,
        rowHeight: CGFloat,
        dayWidth: CGFloat,
        today: Bool
    ) -> some View {
        let target = DropTarget(dateKey: dateKey, slot: slot)
        let highlighted = highlightedDrop == target

        return Rectangle()
            .fill(
                highlighted
                ? Color.indigo.opacity(0.18)
                : (today && slot % 4 == 0 ? Color.indigo.opacity(0.02) : Color.white)
            )
            .frame(width: dayWidth, height: rowHeight)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(
                        slot % 4 == 0
                        ? Color.secondary.opacity(0.46)
                        : Color.secondary.opacity(0.19)
                    )
                    .frame(height: slot % 4 == 0 ? 1.2 : 0.6)
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 0.5)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard let template = selectedTemplate else { return }

                if let error = store.addEvent(
                    template: template,
                    dateKey: dateKey,
                    startSlot: slot
                ) {
                    statusText = error
                } else {
                    statusText = nil
                    selectedTemplateID = nil
                }
            }

    }

    private func eventBlock(_ event: AgendaEvent, rowHeight: CGFloat, dayWidth: CGFloat) -> some View {
        let height = CGFloat(event.durationSlots) * rowHeight
        let borderColor = Color.darker(hex: event.colorHex, amount: 0.32)

        // Su iPhone ogni giorno è stretto (~70 pt): usiamo una tipografia dedicata
        // invece di lasciare che il testo venga troncato con "…".
        let compactEvent = dayWidth < 90
        let horizontalPadding: CGFloat = compactEvent ? 4 : 7
        let eventWidth = max(20, dayWidth - (compactEvent ? 4 : 6))

        return VStack(alignment: .leading, spacing: compactEvent ? 0 : 1) {
            if event.durationSlots > 1 && dayWidth >= 38 {
                HStack(spacing: 3) {
                    Text(event.name)
                        .font(.system(size: compactEvent ? 9.4 : 13, weight: .bold, design: .rounded))
                        .lineLimit(compactEvent && height >= 44 ? 2 : 1)
                        .minimumScaleFactor(0.72)

                    Spacer(minLength: 1)

                    if !compactEvent, event.reminderMinutes != nil {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }

                    if !compactEvent, let location = event.location, !location.isEmpty {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if compactEvent {
                // Per i blocchi stretti evitiamo "11:00–…": l'intervallo va su due righe.
                if height >= 38 {
                    VStack(alignment: .leading, spacing: -1) {
                        Text(slotTime(event.startSlot))
                        Text("– " + slotTime(event.startSlot + event.durationSlots))
                    }
                    .font(.system(size: 7.4, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                } else if height >= 27 {
                    Text(slotTime(event.startSlot))
                        .font(.system(size: 7.2, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if height >= 28 && dayWidth >= 46 {
                Text("\(slotTime(event.startSlot))–\(slotTime(event.startSlot + event.durationSlots))")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            if height >= 50 && dayWidth >= 86, let location = event.location, !location.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.blue)
                        .allowsHitTesting(false)

                    Button {
                        openLocationInGoogleMaps(location)
                    } label: {
                        Text(location)
                            .font(.system(size: 9.0, weight: .semibold, design: .rounded))
                            .underline()
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .foregroundStyle(Color.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Apri \(location) in Google Maps")
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, compactEvent ? 2 : 4)
        .frame(
            width: eventWidth,
            height: max(12, height - 1),
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(hex: event.colorHex))
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(borderColor)
                .frame(height: 2.4)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(borderColor)
                .frame(height: 2.4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor.opacity(0.55), lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.05), radius: 1.2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture {
            eventToEdit = event
        }
        .contextMenu {
            if let location = event.location, !location.isEmpty {
                Button {
                    openLocationInGoogleMaps(location)
                } label: {
                    Label("Apri su Maps", systemImage: "map")
                }
            }

            Button {
                quickTimeEvent = event
            } label: {
                Label("Cambia orario", systemImage: "clock.arrow.2.circlepath")
            }

            Button {
                eventToEdit = event
            } label: {
                Label("Modifica", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                store.deleteEvent(event)
            } label: {
                Label("Elimina", systemImage: "trash")
            }
        }
        .onDrag {
            NSItemProvider(
                object: NSString(string: DragPayload.event(event.id).stringValue)
            )
        } preview: {
            dragPreview(
                name: event.name,
                durationSlots: event.durationSlots,
                colorHex: event.colorHex
            )
        }
    }

    private func dragPreview(
        name: String,
        durationSlots: Int,
        colorHex: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.subheadline.bold())

            Text(durationText(durationSlots))
                .font(.caption2)
        }
        .padding(10)
        .frame(width: 150, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: colorHex))
        )
    }

    private func openLocationInGoogleMaps(_ location: String) {
        let clean = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/maps/search/"
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: clean)
        ]

        if let url = components.url {
            openURL(url)
        }
    }

    private var selectedTemplate: BlockTemplate? {
        guard let selectedTemplateID else { return nil }
        return store.templates.first { $0.id == selectedTemplateID }
    }

    private var weekLabel: String {
        let end = calendar.date(byAdding: .day, value: showWeekend ? 6 : 4, to: weekStart) ?? weekStart
        return "\(shortDate(weekStart)) – \(shortDate(end))"
    }

    private func dateFor(_ dayIndex: Int) -> Date {
        calendar.date(byAdding: .day, value: dayIndex, to: weekStart) ?? weekStart
    }

    private func slotTime(_ slot: Int) -> String {
        let totalMinutes = 8 * 60 + slot * 15
        let hour = totalMinutes / 60
        let minute = totalMinutes % 60
        return String(format: "%02d:%02d", hour, minute)
    }

    private func durationText(_ slots: Int) -> String {
        Self.durationTextStatic(slots)
    }

    static func durationTextStatic(_ slots: Int) -> String {
        let minutes = slots * 15
        let hours = minutes / 60
        let remainder = minutes % 60

        if hours > 0 && remainder > 0 {
            return "\(hours) h \(remainder) min"
        } else if hours > 0 {
            return "\(hours) h"
        } else {
            return "\(remainder) min"
        }
    }

    private func dayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date).capitalized
    }

    private func compactDayName(_ date: Date) -> String {
        let names = ["Do", "Lu", "Ma", "Me", "Gi", "Ve", "Sa"]
        let weekday = calendar.component(.weekday, from: date)
        return names[max(0, min(6, weekday - 1))]
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "dd/MM"
        return formatter.string(from: date)
    }

    private func italianHolidayName(for date: Date) -> String? {
        let cal = Calendar.current
        let day = cal.component(.day, from: date)
        let month = cal.component(.month, from: date)
        let year = cal.component(.year, from: date)

        let fixed: [String: String] = [
            "01-01": "Capodanno",
            "01-06": "Epifania",
            "04-25": "Liberazione",
            "05-01": "Festa del Lavoro",
            "06-02": "Festa della Repubblica",
            "08-15": "Ferragosto",
            "11-01": "Ognissanti",
            "12-08": "Immacolata",
            "12-25": "Natale",
            "12-26": "S. Stefano"
        ]

        let key = String(format: "%02d-%02d", month, day)

        if let name = fixed[key] {
            return name
        }

        if let easter = easterSunday(year: year) {
            if cal.isDate(date, inSameDayAs: easter) {
                return "Pasqua"
            }

            if let easterMonday = cal.date(byAdding: .day, value: 1, to: easter),
               cal.isDate(date, inSameDayAs: easterMonday) {
                return "Lunedì dell'Angelo"
            }
        }

        return nil
    }

    private func italianObservanceName(for date: Date) -> String? {
        let cal = Calendar.current
        let day = cal.component(.day, from: date)
        let month = cal.component(.month, from: date)

        let key = String(format: "%02d-%02d", month, day)

        let observances: [String: String] = [
            "01-17": "S. Antonio Abate",
            "01-31": "S. Giovanni Bosco",
            "02-14": "S. Valentino",
            "03-19": "S. Giuseppe",
            "04-23": "S. Giorgio",
            "04-25": "S. Marco",
            "05-22": "S. Rita",
            "06-13": "S. Antonio da Padova",
            "06-24": "S. Giovanni Battista",
            "06-29": "SS. Pietro e Paolo",
            "07-11": "S. Benedetto",
            "07-16": "Madonna del Carmelo",
            "08-10": "S. Lorenzo",
            "09-21": "S. Matteo",
            "09-29": "SS. Michele, Gabriele e Raffaele",
            "10-04": "S. Francesco",
            "10-18": "S. Luca",
            "11-02": "Commemorazione dei defunti",
            "11-11": "S. Martino",
            "11-25": "S. Caterina",
            "12-06": "S. Nicola",
            "12-13": "S. Lucia",
            "12-26": "S. Stefano",
            "12-31": "S. Silvestro"
        ]

        return observances[key]
    }

    private func easterSunday(year: Int) -> Date? {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        return Calendar.current.date(from: components)
    }

    static func monday(containing date: Date) -> Date {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "it_IT")
        let weekday = calendar.component(.weekday, from: date)
        let daysFromMonday = (weekday + 5) % 7
        let start = calendar.date(byAdding: .day, value: -daysFromMonday, to: date) ?? date
        return calendar.startOfDay(for: start)
    }

    static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func dateFromKey(_ key: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key) ?? Date()
    }
}

private struct DropTarget: Equatable {
    let dateKey: String
    let slot: Int
}

private enum DragPayload {
    case template(UUID)
    case event(UUID)

    var stringValue: String {
        switch self {
        case .template(let id):
            return "template:\(id.uuidString)"
        case .event(let id):
            return "event:\(id.uuidString)"
        }
    }

    static func parse(_ string: String) -> DragPayload? {
        let parts = string.split(separator: ":", maxSplits: 1).map(String.init)

        guard parts.count == 2 else { return nil }
        guard let id = UUID(uuidString: parts[1]) else { return nil }

        if parts[0] == "template" {
            return .template(id)
        }

        if parts[0] == "event" {
            return .event(id)
        }

        return nil
    }
}

private struct DayAgendaDropDelegate: DropDelegate {
    let store: AgendaStore
    let dateKey: String
    let rowHeight: CGFloat
    let topInset: CGFloat
    let visibleStartSlot: Int
    let visibleSlotCount: Int

    @Binding var highlightedDrop: DropTarget?
    @Binding var statusText: String?

    private func target(for info: DropInfo) -> DropTarget {
        let adjustedY = max(0, info.location.y - topInset)
        let rawLocalSlot = Int(floor(adjustedY / max(rowHeight, 1)))
        let localSlot = min(visibleSlotCount - 1, max(0, rawLocalSlot))
        return DropTarget(dateKey: dateKey, slot: visibleStartSlot + localSlot)
    }

    func dropEntered(info: DropInfo) {
        highlightedDrop = target(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        highlightedDrop = target(for: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if highlightedDrop?.dateKey == dateKey {
            highlightedDrop = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let finalTarget = target(for: info)
        highlightedDrop = nil

        guard let provider = info.itemProviders(for: [UTType.text]).first else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString else { return }
            guard let payload = DragPayload.parse(text as String) else { return }

            Task { @MainActor in
                switch payload {
                case .template(let id):
                    guard let template = store.template(id: id) else { return }

                    if let error = store.addEvent(
                        template: template,
                        dateKey: finalTarget.dateKey,
                        startSlot: finalTarget.slot
                    ) {
                        statusText = error
                    } else {
                        statusText = nil
                    }

                case .event(let id):
                    if let error = store.moveEvent(
                        id: id,
                        toDateKey: finalTarget.dateKey,
                        startSlot: finalTarget.slot
                    ) {
                        statusText = error
                    } else {
                        statusText = nil
                    }
                }
            }
        }

        return true
    }
}

struct BlockEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let showDelete: Bool
    let onSave: (String, Int, String, Int?, Int?, String?) -> Void
    let onDelete: (() -> Void)?

    @State private var name: String
    @State private var durationSlots: Int
    @State private var colorHex: String
    @State private var repeatWeeks: Int
    @State private var reminderMinutes: Int
    @State private var location: String

    private let colors = [
        "#F2B6C8", "#B8DFF5", "#BFE5C5", "#FFE59A",
        "#D7C2F3", "#F5C79E", "#B9E7E1", "#D5D9DE"
    ]

    private let repeatChoices = [1, 2, 4, 8, 12, 26, 52]
    private let reminderChoices = [-1, 0, 5, 10, 15, 30, 60]

    init(
        title: String,
        initialName: String,
        initialDurationSlots: Int,
        initialColorHex: String,
        initialRepeatWeeks: Int?,
        initialReminderMinutes: Int?,
        initialLocation: String?,
        showDelete: Bool,
        onSave: @escaping (String, Int, String, Int?, Int?, String?) -> Void,
        onDelete: (() -> Void)?
    ) {
        self.title = title
        self.showDelete = showDelete
        self.onSave = onSave
        self.onDelete = onDelete

        _name = State(initialValue: initialName)
        _durationSlots = State(initialValue: initialDurationSlots)
        _colorHex = State(initialValue: initialColorHex)
        _repeatWeeks = State(initialValue: initialRepeatWeeks ?? 1)
        _reminderMinutes = State(initialValue: initialReminderMinutes ?? -1)
        _location = State(initialValue: initialLocation ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        TextField("Nome", text: $name)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Label("Nome", systemImage: "text.cursor")
                    }

                    Picker(selection: $durationSlots) {
                        ForEach(1...16, id: \.self) { slots in
                            Text(ContentView.durationTextStatic(slots))
                                .tag(slots)
                        }
                    } label: {
                        Label("Durata", systemImage: "timer")
                    }
                } header: {
                    Text("Blocco")
                }

                Section {
                    Picker(selection: $repeatWeeks) {
                        ForEach(repeatChoices, id: \.self) { value in
                            Text(repeatLabel(value)).tag(value)
                        }
                    } label: {
                        Label("Ripeti", systemImage: "repeat")
                    }

                    Picker(selection: $reminderMinutes) {
                        ForEach(reminderChoices, id: \.self) { value in
                            Text(reminderLabel(value)).tag(value)
                        }
                    } label: {
                        Label("Promemoria", systemImage: "alarm")
                    }

                    LabeledContent {
                        TextField("Posizione / indirizzo", text: $location)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Label("Posizione", systemImage: "mappin.and.ellipse")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Opzioni facoltative")
                } footer: {
                    Text("Ripetizione, promemoria e posizione vengono applicati quando inserisci il blocco nella settimana.")
                }

                Section {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible()), count: 4),
                        spacing: 14
                    ) {
                        ForEach(colors, id: \.self) { color in
                            Button {
                                colorHex = color
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: color))
                                        .frame(width: 44, height: 44)

                                    if colorHex == color {
                                        Image(systemName: "checkmark")
                                            .font(.headline.bold())
                                            .foregroundStyle(.black.opacity(0.65))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Colore")
                }

                if showDelete {
                    Section {
                        Button("Elimina blocco", role: .destructive) {
                            onDelete?()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)

                        guard !cleanName.isEmpty else {
                            return
                        }

                        onSave(
                            cleanName,
                            durationSlots,
                            colorHex,
                            repeatWeeks > 1 ? repeatWeeks : nil,
                            reminderMinutes >= 0 ? reminderMinutes : nil,
                            cleanLocation.isEmpty ? nil : cleanLocation
                        )

                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func repeatLabel(_ value: Int) -> String {
        if value == 1 { return "Non ripetere" }
        if value == 2 { return "2 settimane" }
        if value == 4 { return "4 settimane" }
        if value == 8 { return "8 settimane" }
        if value == 12 { return "12 settimane" }
        if value == 26 { return "6 mesi" }
        if value == 52 { return "1 anno" }
        return "\(value) settimane"
    }

    private func reminderLabel(_ value: Int) -> String {
        if value == -1 { return "Nessuno" }
        if value == 0 { return "All'ora di inizio" }
        if value == 60 { return "1 ora prima" }
        return "\(value) minuti prima"
    }
}

struct QuickTimePickerView: View {
    @Environment(\.dismiss) private var dismiss

    let event: AgendaEvent
    let onSave: (Int) -> String?

    @State private var selectedSlot: Int
    @State private var errorText: String?

    // Slot 0 = 08:00 nel calendario. -32 = 00:00.
    // La fine del blocco non può superare le 24:00 (slot 64).
    private var availableSlots: [Int] {
        let lastStartSlot = 64 - event.durationSlots
        guard lastStartSlot >= -32 else { return [-32] }
        return Array(-32...lastStartSlot)
    }

    init(event: AgendaEvent, onSave: @escaping (Int) -> String?) {
        self.event = event
        self.onSave = onSave
        _selectedSlot = State(initialValue: event.startSlot)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text(event.name)
                    .font(.headline)
                    .padding(.top, 6)

                Text("Scorri di 15 minuti alla volta")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Orario", selection: $selectedSlot) {
                    ForEach(availableSlots, id: \.self) { slot in
                        Text("\(slotTime(slot))–\(slotTime(slot + event.durationSlots))")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .tag(slot)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: 430)
                .frame(height: 250)
                .clipped()

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer(minLength: 2)
            }
            .navigationTitle("Cambia orario")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Fatto") {
                        if let error = onSave(selectedSlot) {
                            errorText = error
                        } else {
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func slotTime(_ slot: Int) -> String {
        let totalMinutes = 8 * 60 + slot * 15
        let normalizedMinutes = ((totalMinutes % (24 * 60)) + (24 * 60)) % (24 * 60)
        let hour = normalizedMinutes / 60
        let minute = normalizedMinutes % 60

        // Mostriamo 24:00 solo quando rappresenta esattamente la fine della giornata.
        if totalMinutes == 24 * 60 {
            return "24:00"
        }

        return String(format: "%02d:%02d", hour, minute)
    }
}

struct EventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let event: AgendaEvent
    let onSave: (AgendaEvent) -> String?
    let onDelete: () -> Void

    @State private var name: String
    @State private var date: Date
    @State private var startSlot: Int
    @State private var durationSlots: Int
    @State private var colorHex: String
    @State private var repeatWeeks: Int
    @State private var reminderMinutes: Int
    @State private var location: String
    @State private var errorText: String?

    private let colors = [
        "#F2B6C8", "#B8DFF5", "#BFE5C5", "#FFE59A",
        "#D7C2F3", "#F5C79E", "#B9E7E1", "#D5D9DE"
    ]

    private let repeatChoices = [1, 2, 4, 8, 12, 26, 52]
    private let reminderChoices = [-1, 0, 5, 10, 15, 30, 60]

    init(
        event: AgendaEvent,
        onSave: @escaping (AgendaEvent) -> String?,
        onDelete: @escaping () -> Void
    ) {
        self.event = event
        self.onSave = onSave
        self.onDelete = onDelete

        _name = State(initialValue: event.name)
        _date = State(initialValue: ContentView.dateFromKey(event.dateKey))
        _startSlot = State(initialValue: event.startSlot)
        _durationSlots = State(initialValue: event.durationSlots)
        _colorHex = State(initialValue: event.colorHex)
        _repeatWeeks = State(initialValue: event.repeatWeeks ?? 1)
        _reminderMinutes = State(initialValue: event.reminderMinutes ?? -1)
        _location = State(initialValue: event.location ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent {
                        TextField("Nome", text: $name)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Label("Nome", systemImage: "text.cursor")
                    }

                    DatePicker(
                        selection: $date,
                        displayedComponents: .date
                    ) {
                        Label("Giorno", systemImage: "calendar")
                    }

                    Picker(selection: $startSlot) {
                        ForEach(-32..<64, id: \.self) { slot in
                            Text(slotTime(slot)).tag(slot)
                        }
                    } label: {
                        Label("Ora inizio", systemImage: "flag.fill")
                    }

                    Picker(selection: $durationSlots) {
                        ForEach(1...16, id: \.self) { slots in
                            Text(ContentView.durationTextStatic(slots))
                                .tag(slots)
                        }
                    } label: {
                        Label("Durata", systemImage: "timer")
                    }

                    HStack {
                        Label("Ora fine", systemImage: "flag.checkered")
                        Spacer()
                        Text(slotTime(min(48, startSlot + durationSlots)))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Impegno")
                }

                Section {
                    Picker(selection: $repeatWeeks) {
                        ForEach(repeatChoices, id: \.self) { value in
                            Text(repeatLabel(value)).tag(value)
                        }
                    } label: {
                        Label("Ripeti", systemImage: "repeat")
                    }

                    Picker(selection: $reminderMinutes) {
                        ForEach(reminderChoices, id: \.self) { value in
                            Text(reminderLabel(value)).tag(value)
                        }
                    } label: {
                        Label("Promemoria", systemImage: "alarm")
                    }

                    LabeledContent {
                        TextField("Posizione / indirizzo", text: $location)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Label("Posizione", systemImage: "mappin.and.ellipse")
                            .foregroundStyle(.red)
                    }

                    if !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            openMaps()
                        } label: {
                            Label("Apri in Google Maps", systemImage: "map")
                        }
                    }
                } header: {
                    Text("Opzioni facoltative")
                } footer: {
                    Text("Il promemoria usa una notifica sonora di iPadOS.")
                }

                Section {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible()), count: 4),
                        spacing: 14
                    ) {
                        ForEach(colors, id: \.self) { color in
                            Button {
                                colorHex = color
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: color))
                                        .frame(width: 44, height: 44)

                                    if colorHex == color {
                                        Image(systemName: "checkmark")
                                            .font(.headline.bold())
                                            .foregroundStyle(.black.opacity(0.65))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Colore")
                }

                if let errorText = errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Elimina impegno", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Modifica impegno")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)

                        guard !cleanName.isEmpty else {
                            return
                        }

                        let updated = AgendaEvent(
                            id: event.id,
                            templateID: event.templateID,
                            name: cleanName,
                            durationSlots: durationSlots,
                            colorHex: colorHex,
                            dateKey: ContentView.dateKey(date),
                            startSlot: startSlot,
                            repeatWeeks: repeatWeeks > 1 ? repeatWeeks : nil,
                            reminderMinutes: reminderMinutes >= 0 ? reminderMinutes : nil,
                            location: cleanLocation.isEmpty ? nil : cleanLocation,
                            seriesID: event.seriesID
                        )

                        if let error = onSave(updated) {
                            errorText = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func openMaps() {
        let clean = location.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clean.isEmpty else {
            return
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/maps/search/"
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: clean)
        ]

        if let url = components.url {
            openURL(url)
        }
    }

    private func repeatLabel(_ value: Int) -> String {
        if value == 1 { return "Non ripetere" }
        if value == 2 { return "2 settimane" }
        if value == 4 { return "4 settimane" }
        if value == 8 { return "8 settimane" }
        if value == 12 { return "12 settimane" }
        if value == 26 { return "6 mesi" }
        if value == 52 { return "1 anno" }
        return "\(value) settimane"
    }

    private func reminderLabel(_ value: Int) -> String {
        if value == -1 { return "Nessuno" }
        if value == 0 { return "All'ora di inizio" }
        if value == 60 { return "1 ora prima" }
        return "\(value) minuti prima"
    }

    private func slotTime(_ slot: Int) -> String {
        let totalMinutes = 8 * 60 + slot * 15
        let hour = totalMinutes / 60
        let minute = totalMinutes % 60
        return String(format: "%02d:%02d", hour, minute)
    }
}
