//! Library entry point — re-exports the emulator core for test harnesses
//! and downstream consumers. This deliberately does NOT pull in
//! `frontend/sdl.zig`, so it can be linked into headless test binaries
//! without dragging SDL2 in.

pub const Core = @import("core/core.zig").Core;
pub const Bus = @import("core/bus.zig").Bus;
pub const Cpu = @import("cpu/arm7tdmi.zig").Cpu;
