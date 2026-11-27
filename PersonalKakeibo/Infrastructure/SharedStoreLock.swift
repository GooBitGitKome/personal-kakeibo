import Foundation
import Darwin

/// All local app/extension reads and writes use the same lock and a fresh context.
enum SharedStoreLock {
    static func withLock<T>(at url: URL?, _ body: () throws -> T) throws -> T {
        guard let url else { return try body() }
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StoreError.conflict }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(3)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw StoreError.conflict }
            usleep(10_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}
