import AppKit
import Foundation
import SwiftData
import SwiftUI
import UserNotifications

struct PlannedNotification: Equatable {
    let id: String
    let date: Date
    let credentialID: UUID?
}

enum NotificationPlanner {
    static func reminder(period: UUID, oldest: Date, days: Int, queuedPeriod: UUID?, queuedAt: Date?, now: Date, calendar: Calendar = .current) -> PlannedNotification? {
        guard (1...365).contains(days) else { return nil }
        if queuedPeriod == period, (queuedAt ?? .distantPast) <= now { return nil }
        guard let due = calendar.date(byAdding: .day, value: days, to: oldest) else { return nil }
        return PlannedNotification(id: "AppMate.backup.\(period)", date: max(due, now.addingTimeInterval(2)), credentialID: nil)
    }

    static func expiry(id: UUID, expiresAt: Date, days: [Int], now: Date, calendar: Calendar = .current) -> [PlannedNotification] {
        days.compactMap { day in
            guard let target = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: expiresAt)),
                  let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: target) else { return nil }
            let date = day == 0 ? min(morning, expiresAt) : morning
            guard date > now else { return nil }
            return PlannedNotification(id: "AppMate.expiry.\(id).\(day)", date: date, credentialID: id)
        }
    }
}

@MainActor final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    var pending: UUID?
    var open: ((UUID?) -> Void)?
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["credentialID"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            self.pending = id
            self.open?(id)
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor @Observable final class NotificationService {
    static let shared = NotificationService()
    var message = "通知の状態を確認しています"
    var omitted = 0
    private var updating = false

    func refresh(context: ModelContext, records: [StoredCredential], changes: [BackupChange]) async {
        guard ProcessInfo.processInfo.environment["APP_MATE_TESTING"] != "1", !updating else { return }
        updating = true
        defer { updating = false }
        do {
            let prefs = try PreferencesStore.read(in: context)
            let active = records.filter { $0.deletedAt == nil && $0.revokedAt == nil && $0.replacedByID == nil && $0.app?.deletedAt == nil }
            let count = active.filter { $0.displayState(at: .now).needsRenewal }.count
            NSApplication.shared.dockTile.badgeLabel = prefs.showDockBadge && count > 0 ? String(count) : nil
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("AppMate.") }
            guard !Task.isCancelled else { return }
            guard prefs.notificationsEnabled && allowed else {
                center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
                message = "通知はオフです。設定から許可できます。"
                omitted = 0
                return
            }
            let now = Date.now
            var plans = active.flatMap { record in record.expiresAt.map { NotificationPlanner.expiry(id: record.id, expiresAt: $0, days: prefs.expirationDays, now: now) } ?? [] }
            let checkpoint = try context.fetch(FetchDescriptor<BackupCheckpoint>()).first
            var reminder: UUID?
            var preserved: [UNNotificationRequest] = []
            if let days = prefs.backupReminderDays, let oldest = changes.min(by: { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }) {
                let id = "AppMate.backup.\(oldest.id)"
                if let plan = NotificationPlanner.reminder(period: oldest.id, oldest: oldest.createdAt, days: days, queuedPeriod: checkpoint?.reminderPeriod, queuedAt: checkpoint?.reminderScheduledAt, now: now) {
                    plans.append(plan)
                    reminder = oldest.id
                } else { preserved = pending.filter { $0.identifier == id } }
            }
            plans.sort { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
            omitted = max(0, plans.count - (60 - preserved.count))
            plans = Array(plans.prefix(60 - preserved.count))
            let desired = Set(plans.map(\.id) + preserved.map(\.identifier))
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { !desired.contains($0) })
            for plan in plans {
                if let old = pending.first(where: { $0.identifier == plan.id }),
                   let date = (old.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(), abs(date.timeIntervalSince(plan.date)) < 1 { continue }
                let content = UNMutableNotificationContent()
                content.title = plan.credentialID == nil ? "バックアップを作成してください" : "資格情報の期限を確認してください"
                content.body = "App Mateを開いて内容を確認できます。"
                content.sound = .default
                if let id = plan.credentialID { content.userInfo = ["credentialID": id.uuidString] }
                var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: plan.date)
                components.timeZone = .current
                guard !Task.isCancelled else { return }
                try await center.add(UNNotificationRequest(identifier: plan.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
                if let reminder, plan.id == "AppMate.backup.\(reminder)", let checkpoint, !context.hasChanges {
                    checkpoint.reminderPeriod = reminder
                    checkpoint.reminderScheduledAt = plan.date
                    do { try context.save() } catch { context.rollback(); center.removePendingNotificationRequests(withIdentifiers: [plan.id]); throw error }
                }
            }
            message = omitted > 0 ? "近い通知を優先しました。\(omitted)件は次回起動・復帰時に再確認します。" : "期限の通知はオンです"
        } catch { message = "通知を更新できませんでした。設定から再確認してください。" }
    }
}

struct NotificationCoordinator: View {
    let container: ModelContainer
    let navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow
    @Query private var records: [StoredCredential]
    @Query private var changes: [BackupChange]
    @Query private var checkpoints: [BackupCheckpoint]
    @State private var tick = 0
    private var revision: String {
        records.map { "\($0.id)\($0.expiresAt?.description ?? "")\($0.deletedAt?.description ?? "")\($0.revokedAt?.description ?? "")\($0.replacedByID?.description ?? "")" }.sorted().joined()
        + changes.map { $0.id.uuidString }.sorted().joined()
        + (checkpoints.first?.preferencesData?.base64EncodedString() ?? "") + String(tick)
    }
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: revision) {
                if let prefs = try? PreferencesStore.read(in: container.mainContext) { navigation.menuVisible = prefs.showMenuBar }
                await NotificationService.shared.refresh(context: container.mainContext, records: records, changes: changes)
            }
            .onAppear {
                guard ProcessInfo.processInfo.environment["APP_MATE_TESTING"] != "1" else { return }
                NotificationRouter.shared.open = { id in
                    navigation.show(id.map(CredentialScope.credential) ?? .all)
                    if let window = NSApp.windows.first(where: { $0.title == "App Mate" && $0.canBecomeMain }) { window.deminiaturize(nil); window.makeKeyAndOrderFront(nil) }
                    else { openWindow(id: "main") }
                    NSApp.activate()
                }
                if let pending = NotificationRouter.shared.pending { NotificationRouter.shared.open?(pending); NotificationRouter.shared.pending = nil }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in tick += 1 }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in tick += 1 }
    }
}
