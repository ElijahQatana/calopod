import CalopodStore
import Foundation
import Testing

@Test
func latestSuccessfulRunSurvivesANewerFailure() throws {
    let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
    let successfulID = try repository.beginSyncRun(
        mode: "apply",
        trigger: "automatic",
        id: "successful",
        now: Date(timeIntervalSince1970: 100)
    )
    try repository.finishSyncRun(
        id: successfulID,
        status: "succeeded",
        now: Date(timeIntervalSince1970: 110)
    )
    let failedID = try repository.beginSyncRun(
        mode: "apply",
        trigger: "automatic",
        id: "failed",
        now: Date(timeIntervalSince1970: 200)
    )
    try repository.finishSyncRun(
        id: failedID,
        status: "failed",
        errorCode: "provider",
        now: Date(timeIntervalSince1970: 210)
    )

    #expect(try repository.latestSyncRun(trigger: "automatic")?.id == "failed")
    #expect(try repository.latestSuccessfulSyncRun(trigger: "automatic")?.id == "successful")
    #expect(try repository.latestSuccessfulSyncRun(trigger: "manual") == nil)
}
