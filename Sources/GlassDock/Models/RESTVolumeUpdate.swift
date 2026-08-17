import Vapor

struct RESTVolumeUpdate: Content, Sendable {
    let Labels: [String: String]?
    let DriverOpts: [String: String]?
    let Spec: VolumeUpdateSpec?
}

/// The Engine API uses this route for Swarm cluster-volume updates. Glass
/// Dock keeps local volume metadata, but accepts the object so Docker clients
/// can send the same request shape when the volume is local.
struct VolumeUpdateSpec: Content, Sendable {
    let Availability: String?
}
