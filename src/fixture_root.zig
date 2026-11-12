//! Explicit sample/compatibility fixture; sample-independent code lives in root.zig.
const core = @import("zz0_agent_core");
pub const xrce = core.xrce;
pub const backend = core.backend;
pub const resources = core.resources;
pub const dds_backend = core.dds_backend;
pub const dds_demo = @import("fixtures/dds_demo.zig");
pub const WriteLogMode = core.WriteLogMode;
pub const Agent = core.AgentWithPolicy(@import("fixtures/counter.zig").Policy);
pub const udp = struct {
    pub const parseIdleTimeoutSeconds = core.udp.parseIdleTimeoutSeconds;
    pub const timeoutMillis = core.udp.timeoutMillis;
    pub const ClientSessions = core.udp.Sessions(Agent);
    pub const UdpServer = core.udp.Server(Agent);
};
test {
    _ = @import("fixtures/packet_test.zig");
    _ = @import("fixtures/udp_test.zig");
    _ = @import("fixtures/startup_test.zig");
    _ = @import("fixture_backend_test.zig");
    _ = @import("fixtures/counter.zig");
    _ = @import("dds_backend_test.zig");
}
