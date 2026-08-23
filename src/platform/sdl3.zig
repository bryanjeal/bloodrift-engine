// SDL3 platform layer — window management, high-resolution timing, and raw
// keyboard input.
//
// This module wraps the minimal SDL3 surface needed for the game loop:
//   - Window: create/destroy an OS window; present (deprecated, use Renderer).
//   - Timer: nanosecond-precision elapsed time via SDL_GetPerformanceCounter.
//   - InputSnapshot: one frame of raw keyboard state (boolean per key).
//   - pollEvents: drain the SDL3 event queue and update an InputSnapshot.
//
// Design:
//   - No dynamic allocation. All types are value types on the stack.
//   - pollEvents uses getKeyboardState() once per call (not per event).
//   - Timer uses u128 intermediates to avoid overflow in ns conversion.

const std = @import("std");
const sdl = @import("zsdl3");

// ============================================================================
// Window
// ============================================================================

/// An OS window backed by SDL3.
pub const Window = struct {
    handle: *sdl.Window,

    /// Open a new window with the given title and dimensions.
    /// Calls SDL_Init internally — do not call sdl.init separately.
    pub fn init(title: [:0]const u8, width: u31, height: u31) !Window {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);
        try sdl.init(.{ .video = true, .events = true });
        // SDL_WINDOW_VULKAN is required for SDL_Vulkan_CreateSurface (M7+).
        const handle = try sdl.createWindow(title, @intCast(width), @intCast(height), .{ .vulkan = true, .resizable = true });
        return .{ .handle = handle };
    }

    /// Destroy the window and shut down SDL3.
    pub fn deinit(self: *Window) void {
        sdl.destroyWindow(self.handle);
        sdl.quit();
        self.handle = undefined;
    }

    /// Get the current window dimensions in logical (points/DP) units.
    /// On Retina displays, this is half the framebuffer resolution.
    pub fn getSize(self: *const Window) struct { width: u32, height: u32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        sdl.getWindowSize(self.handle, &w, &h) catch return .{ .width = 1280, .height = 720 };
        return .{ .width = @intCast(w), .height = @intCast(h) };
    }

    /// @deprecated: Use engine.renderer.Renderer.present() instead (M7+).
    /// Kept for build compatibility during the M7 transition.
    pub fn present(_: *const Window) void {}
};

// ============================================================================
// Timer
// ============================================================================

/// High-precision elapsed-time timer backed by SDL_GetPerformanceCounter.
pub const Timer = struct {
    start: u64,
    freq: u64,

    /// Capture the current performance counter and frequency.
    pub fn init() Timer {
        const freq = sdl.getPerformanceFrequency();
        std.debug.assert(freq > 0);
        return .{
            .start = sdl.getPerformanceCounter(),
            .freq = freq,
        };
    }

    /// Nanoseconds elapsed since the last reset (or init).
    /// Uses u128 intermediates to avoid overflow for long sessions.
    pub fn elapsedNs(self: *const Timer) u64 {
        std.debug.assert(self.freq > 0);
        const current = sdl.getPerformanceCounter();
        const delta = current -% self.start;
        const ns = @as(u128, delta) * 1_000_000_000 / @as(u128, self.freq);
        return @intCast(ns);
    }

    /// Reset the timer start point to now.
    pub fn reset(self: *Timer) void {
        self.start = sdl.getPerformanceCounter();
    }
};

// ============================================================================
// InputSnapshot
// ============================================================================

/// One frame of raw platform state.
///
/// Quit on Escape or window close. All key mappings (movement, skills, UI
/// toggles) live on the consumer side via isKeyHeld().
pub const InputSnapshot = struct {
    quit: bool = false,
    window_resized: bool = false,

    /// All fields false.
    pub const zero: InputSnapshot = .{};
};

// Re-export SDL scancodes so game code can query arbitrary keys without
// adding game-specific fields to InputSnapshot.
pub const Scancode = sdl.Scancode;

/// Return true if the given scancode is currently held.
/// Must be called after pollEvents (which pumps the event queue) to get
/// the current frame's keyboard state.  Safe to call multiple times per frame.
pub fn isKeyHeld(sc: Scancode) bool {
    const kb = sdl.getKeyboardState();
    return kb[@intFromEnum(sc)];
}

// ============================================================================
// pollEvents
// ============================================================================

/// Drain the SDL3 event queue and update snap with the current keyboard state.
///
/// Returns false if the application should quit (window close or Escape key),
/// true if the loop should continue. The snap.quit field is also set.
///
/// event_hook is called for every SDL event before platform handling.
/// Pass null to disable. Intended for ImGui event forwarding
/// (zgui.backend.processEvent) or other per-event listeners.
pub fn pollEvents(snap: *InputSnapshot, event_hook: ?*const fn (*const anyopaque) void) bool {
    // Drain all pending events. We only care about quit here; keyboard state
    // is read in bulk below via getKeyboardState().
    var event: sdl.Event = undefined;
    while (sdl.pollEvent(&event)) {
        if (event_hook) |hook| hook(@ptrCast(&event));
        if (event.type == .quit) {
            snap.quit = true;
        } else if (event.type == .window_pixel_size_changed) {
            snap.window_resized = true;
        }
    }

    // Read the entire keyboard state in one call. The returned slice is valid
    // until the next SDL_PumpEvents or SDL_PollEvent call.
    const kb = sdl.getKeyboardState();

    // Scancodes confirmed against SDL3 headers (SDL_scancode.h):
    //   a=4, d=7, e=8, f=9, q=20, r=21, s=22, w=26, escape=41
    //   c=6, i=12, p=19
    std.debug.assert(kb.len > 41);

    if (kb[@intFromEnum(sdl.Scancode.escape)]) {
        snap.quit = true;
    }

    return !snap.quit;
}

// ============================================================================
// Tests
// ============================================================================

test "InputSnapshot: zero has all fields false" {
    const snap = InputSnapshot.zero;
    try std.testing.expect(!snap.quit);
    try std.testing.expect(!snap.window_resized);
}

test "Timer: elapsed increases monotonically" {
    // This test requires SDL3 to be initialized (for getPerformanceCounter).
    // It does not require a display — events subsystem is sufficient.
    // On headless CI without SDL3 installed, this test will fail at sdl.init.
    try sdl.init(.{ .events = true });
    defer sdl.quit();

    var timer = Timer.init();
    const first = timer.elapsedNs();

    // Busy-spin briefly to ensure counter advances.
    var i: u32 = 0;
    while (i < 100_000) : (i += 1) {
        std.mem.doNotOptimizeAway(i);
    }

    const second = timer.elapsedNs();
    try std.testing.expect(second >= first);
}

test "Timer: reset brings elapsed back near zero" {
    try sdl.init(.{ .events = true });
    defer sdl.quit();

    var timer = Timer.init();

    var i: u32 = 0;
    while (i < 100_000) : (i += 1) {
        std.mem.doNotOptimizeAway(i);
    }

    timer.reset();
    const after_reset = timer.elapsedNs();
    // After reset, elapsed should be very small (well under 1ms = 1_000_000 ns).
    try std.testing.expect(after_reset < 1_000_000);
}
