import CloudKit
import Foundation
import Testing
@testable import Sync

@Test(arguments: [
    (CKError.Code.networkUnavailable, CloudError.Kind.network),
    (.networkFailure, .network),
    (.serverResponseLost, .network),
    (.requestRateLimited, .throttled),
    (.zoneBusy, .throttled),
    (.serviceUnavailable, .throttled),
    (.notAuthenticated, .account),
    (.accountTemporarilyUnavailable, .account),
    (.changeTokenExpired, .tokenExpired),
    (.zoneNotFound, .zoneMissing),
    (.userDeletedZone, .zoneDeletedByUser),
    (.serverRecordChanged, .conflict),
    (.unknownItem, .notFound),
    (.quotaExceeded, .quota),
    (.internalError, .other),
])
func eachCloudKitErrorMapsToItsKind(code: CKError.Code, kind: CloudError.Kind) {
    #expect(CloudKitStore.map(CKError(code)).kind == kind)
}

@Test func aRetryAfterTimeIsKeptAndMakesANetworkErrorAThrottle() {
    let throttled = CloudKitStore.map(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0]))
    #expect(throttled.kind == .throttled)
    #expect(throttled.retryAfter == 30)
    #expect(CloudKitStore.map(CKError(.networkFailure, userInfo: [CKErrorRetryAfterKey: 5.0])).kind == .throttled)
}

@Test func aPartialFailureMapsToItsFirstItemsError() {
    let id = CKRecord.ID(recordName: "key-a")
    let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.serverRecordChanged)]])
    #expect(CloudKitStore.map(error).kind == .conflict)
}

@Test func aTimedOutRequestIsANetworkError() {
    #expect(CloudKitStore.map(URLError(.timedOut)).kind == .network)
}
