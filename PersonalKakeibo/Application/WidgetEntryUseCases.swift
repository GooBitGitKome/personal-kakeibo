import Foundation
import PersonalKakeiboDomain

@MainActor public struct WidgetEntryUseCases {
    private let repository: any WidgetEntryRepository
    public init(repository: any WidgetEntryRepository) { self.repository = repository }

    public func perform(_ action: WidgetEntryAction, value: String = "", sessionID: UUID,
                        deviceID: UUID, now: Date = Date()) throws {
        try repository.performWidgetAction(action, value: value, sessionID: sessionID,
                                           deviceID: deviceID, now: now)
    }
}
