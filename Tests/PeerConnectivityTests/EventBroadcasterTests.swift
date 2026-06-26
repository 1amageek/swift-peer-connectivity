import Testing
import PeerConnectivity

@Suite("PeerConnectivity EventBroadcaster Tests")
struct EventBroadcasterTests {

    @Test("shutdown finishes current and future subscribers", .timeLimit(.minutes(1)))
    func shutdownFinishesSubscribers() async {
        let broadcaster = PeerConnectivityEventBroadcaster<Int>()
        var iterator = broadcaster.subscribe().makeAsyncIterator()

        broadcaster.emit(1)
        let first = await iterator.next()
        #expect(first == 1)

        broadcaster.shutdown()
        let afterShutdown = await iterator.next()
        #expect(afterShutdown == nil)

        var lateIterator = broadcaster.subscribe().makeAsyncIterator()
        let lateValue = await lateIterator.next()
        #expect(lateValue == nil)
    }

    @Test("bufferingNewest drops oldest buffered events", .timeLimit(.minutes(1)))
    func bufferingNewestDropsOldestEvents() async {
        let broadcaster = PeerConnectivityEventBroadcaster<Int>(bufferingPolicy: .bufferingNewest(2))
        var iterator = broadcaster.subscribe().makeAsyncIterator()

        broadcaster.emit(1)
        broadcaster.emit(2)
        broadcaster.emit(3)

        let first = await iterator.next()
        let second = await iterator.next()
        #expect(first == 2)
        #expect(second == 3)

        broadcaster.shutdown()
    }
}
