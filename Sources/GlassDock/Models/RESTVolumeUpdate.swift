import Vapor

struct RESTVolumeUpdate: Content, Sendable {
    let Labels: [String: String]?
    let DriverOpts: [String: String]?
}
