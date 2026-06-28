import AppCore
import Testing
@testable import Storage

@Test
func storeCreatesAndFetchesMeetings() async throws {
    let store = try SQLiteMeetingStore(path: ":memory:")
    _ = try await store.createMeeting(title: "Standup")
    let meetings = try await store.fetchMeetings(query: "Stand")
    #expect(meetings.count == 1)
}
