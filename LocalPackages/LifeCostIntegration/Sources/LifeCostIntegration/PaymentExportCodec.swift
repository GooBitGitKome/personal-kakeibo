import Foundation

public enum PaymentExportCodec {
    public static let maximumBytes = 10 * 1024 * 1024
    public static func encode(_ export: PaymentExport) throws -> Data {
        try export.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(export); guard data.count <= maximumBytes else { throw IntegrationError.tooLarge }; return data
    }
    public static func decode(_ data: Data) throws -> PaymentExport {
        guard data.count <= maximumBytes else { throw IntegrationError.tooLarge }
        // Reject fractional/exponent numeric tokens even when JSONDecoder could coerce them to integers.
        try IntegerJSON.validate(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["payments"] as? [[String: Any]] else { throw IntegrationError.invalid }
        let privateFields = ["name", "amount", "currency", "dueDate", "category", "paymentType", "syncEnabled"]
        for row in rows where row["status"] as? String == "cancelled" {
            guard privateFields.allSatisfy({ row[$0] == nil }) else { throw IntegrationError.invalid }
        }
        do {
            let value = try JSONDecoder().decode(PaymentExport.self, from: data)
            try value.validate(); return value
        } catch let error as IntegrationError { throw error }
        catch { throw IntegrationError.invalid }
    }
}

public enum IntegerJSON {
    public static func validate(_ data: Data) throws {
        _ = try JSONSerialization.jsonObject(with: data)
        var quoted = false; var escaped = false; var number = ""
        func check() throws {
            if !number.isEmpty, number.contains(".") || number.contains("e") || number.contains("E") { throw IntegrationError.invalid }
        }
        for byte in data {
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else if byte == 34 {
                try check(); number = ""; quoted = true
            } else if (48...57).contains(byte) || byte == 45 || (!number.isEmpty && [43,46,101,69].contains(byte)) {
                number.append(Character(UnicodeScalar(byte)))
            } else { try check(); number = "" }
        }
        try check()
    }
}
