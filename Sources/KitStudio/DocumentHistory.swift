import Foundation
import MPCCore

/// Value snapshots use Swift's copy-on-write audio buffers. A conservative budget
/// also bounds history when successive destructive edits allocate new buffers.
struct StudioDocumentState {
    var program: MPCProgram?
    var sounds: [Int: MPCSound]
    var reports: [Int: PCM16RangeReport]
    var name: String
    var selectedPad: Int
    var revision: UUID

    var cost: Int {
        sounds.values.reduce(4_608) { $0 + $1.frameCount * $1.channels.count * MemoryLayout<Float>.size }
    }
}

struct DocumentHistory {
    private struct Entry {
        let state: StudioDocumentState
        let title: String
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    private var lastKey: String?
    private var lastEdit = Date.distantPast
    private let maximumBytes = 256 * 1024 * 1024
    private let maximumEntries = 50

    var undoTitle: String? { past.last?.title }
    var redoTitle: String? { future.last?.title }

    mutating func record(_ state: StudioDocumentState, title: String, coalescingKey: String? = nil) {
        let now = Date()
        if coalescingKey == nil || lastKey != coalescingKey || now.timeIntervalSince(lastEdit) > 0.7 {
            past.append(Entry(state: state, title: title))
        }
        lastKey = coalescingKey
        lastEdit = now
        future.removeAll()
        while past.count > 1 && (past.count > maximumEntries || past.reduce(0, { $0 + $1.state.cost }) > maximumBytes) {
            past.removeFirst()
        }
    }

    mutating func undo(_ current: StudioDocumentState) -> StudioDocumentState? {
        guard let entry = past.popLast() else { return nil }
        future.append(Entry(state: current, title: entry.title))
        endCoalescing()
        return entry.state
    }

    mutating func redo(_ current: StudioDocumentState) -> StudioDocumentState? {
        guard let entry = future.popLast() else { return nil }
        past.append(Entry(state: current, title: entry.title))
        endCoalescing()
        return entry.state
    }

    mutating func endCoalescing() { lastKey = nil }
}
