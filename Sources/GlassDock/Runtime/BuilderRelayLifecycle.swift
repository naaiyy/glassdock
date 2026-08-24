import Vapor

struct BuilderRelayLifecycle: LifecycleHandler {
    let relay: BuilderRelay

    func shutdown(_ application: Application) {
        relay.stop()
    }
}
