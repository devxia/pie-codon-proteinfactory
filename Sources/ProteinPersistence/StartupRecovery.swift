import Foundation
import GRDB
import ProteinDomain

func recoverInterruptedWork(_ db: Database, at date: Date) throws {
    let time = storedTime(date)
    guard time.isFinite else { throw PersistenceError.recoveryFailed }

    try db.execute(sql: """
        UPDATE batches SET status = 'unknown', updated_at = ?
        WHERE id IN (
            SELECT batch_id FROM records WHERE status = 'running'
            UNION
            SELECT records.batch_id FROM attempts JOIN records ON records.id = attempts.record_id
            WHERE attempts.status = 'dispatching'
        );
        UPDATE records SET status = 'unknown'
        WHERE status <> 'running' AND id IN (SELECT record_id FROM attempts WHERE status = 'dispatching');
        UPDATE attempts SET status = 'unknown', effect = 'unknown'
        WHERE status = 'dispatching';
        UPDATE records SET status = 'unknown' WHERE status = 'running';
        UPDATE batches SET status = 'stopped', stop_requested = 1, updated_at = ?
        WHERE status = 'queued';
        """, arguments: [time, time])

    for batchID in try String.fetchAll(db, sql: "SELECT id FROM batches WHERE status = 'running'") {
        let statuses = try String.fetchAll(db, sql: "SELECT status FROM records WHERE batch_id = ?", arguments: [batchID])
            .map { try storedRawValue($0, "records.status") as RecordStatus }
        guard let status = BatchSummary(statuses: statuses).statusAfterExecution else { throw PersistenceError.recoveryFailed }
        try db.execute(sql: "UPDATE batches SET status = ?, updated_at = ? WHERE id = ?",
                       arguments: [status.rawValue, time, batchID])
    }
}
