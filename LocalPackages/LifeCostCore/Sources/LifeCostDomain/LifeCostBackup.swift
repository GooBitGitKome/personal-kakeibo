import Foundation
import LifeCostIntegration

public struct LifeCostRestorePreview: Sendable {
    public let original: LifeCostSnapshot
    public let merged: LifeCostSnapshot
    public let additions: Int
    public let updates: Int
}
public enum LifeCostBackup {
    public static let maximumBytes = 50 * 1024 * 1024
    public static func encode(_ snapshot: LifeCostSnapshot) throws -> Data {
        try snapshot.validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(snapshot); guard data.count <= maximumBytes else { throw IntegrationError.tooLarge }; return data
    }
    public static func decode(_ data: Data) throws -> LifeCostSnapshot {
        guard data.count <= maximumBytes else { throw IntegrationError.tooLarge }
        try IntegerJSON.validate(data)
        let snapshot = try JSONDecoder().decode(LifeCostSnapshot.self, from: data); try snapshot.validate(); return snapshot
    }
    public static func preview(_ incoming: LifeCostSnapshot, current: LifeCostSnapshot, overwrite: Bool) throws -> LifeCostRestorePreview {
        try incoming.validate(); try current.validate()
        guard current.isEmpty || incoming.sourceDatasetId == current.sourceDatasetId else { throw IntegrationError.changed }
        var additions = 0; var updates = 0
        func merge<T: Identifiable & Equatable>(_ old: [T], _ incoming: [T]) throws -> [T] where T.ID == UUID {
            var result = old; var indices = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($0.element.id,$0.offset) })
            for value in incoming {
                if let index = indices[value.id] {
                    if result[index] != value {
                        guard overwrite else { throw IntegrationError.changed }; result[index] = value; updates += 1
                    }
                } else { indices[value.id] = result.count; result.append(value); additions += 1 }
            }
            return result
        }
        var merged = current
        if current.isEmpty { merged.sourceDatasetId = incoming.sourceDatasetId }
        merged.assets = try merge(current.assets,incoming.assets); merged.contracts = try merge(current.contracts,incoming.contracts)
        merged.occurrences = try merge(current.occurrences,incoming.occurrences)
        // An exported occurrence must remain known even when restoring an older backup.
        let exported = Set(current.occurrences.filter(\.exported).map(\.id))
        for i in merged.occurrences.indices where exported.contains(merged.occurrences[i].id) { merged.occurrences[i].exported = true }
        try merged.validate(); return .init(original: current, merged: merged, additions: additions, updates: updates)
    }
}
