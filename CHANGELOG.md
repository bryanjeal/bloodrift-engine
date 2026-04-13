# Engine Changelog

All changes to the Blood Rift Engine, newest first.

## [2026-04-12] Replace runtime vtable Renderer with comptime backend abstraction

**Summary:** Remove the runtime vtable-based Renderer abstraction and replace it with a comptime-validated backend selection layer. Backends are now chosen at build time via `-Dbackend=` and validated at compile time via `assertRendererInterface`.

**Changes:**
- `build.zig`: Added `Renderer` enum (`vulkan`, `webgpu`, `opengl`), `parseRendererOption()`, `build_options` module with `addOptions` so .zig code can import `build_options`
- `renderer.zig`: Removed vtable-based `Renderer` struct (ptr + vtable + VTable + wrappers). Added `assertRendererInterface(comptime T: type)` for comptime backend validation. Renamed `MaterialDef.vertex_spv`/`fragment_spv` to `vertex_shader`/`fragment_shader`. Added `ShaderPayload` type (comptime switch on selected_renderer).
- `renderer/root.zig`: `Renderer` is now comptime `switch (build_options.renderer) { .vulkan => VulkanBackend, ... }`. Added `comptime { _ = assertRendererInterface(Renderer); }` guard.
- `vulkan/backend.zig`: Removed `renderer()` method and ~40 lines of vtable shim functions. Changed `mat.vertex_spv`/`fragment_spv` to `mat.vertex_shader`/`fragment_shader`. Fixed SSBO flush to read `non_coherent_atom_size` and use `std.mem.alignForward`.
- `vulkan/device.zig`: Added `properties: vk.PhysicalDeviceProperties` field to `DeviceState`, populated in `init()` via `getPhysicalDeviceProperties`.
- `vulkan/pipeline.zig`: Changed shader params from `[]const u8` to `[]align(@alignOf(u32)) const u8`. Removed runtime `@alignCast`.

**Breaking changes:**
- `MaterialDef.vertex_spv` and `fragment_spv` renamed to `vertex_shader` and `fragment_shader`
- `VulkanBackend.renderer()` method removed -- use `Renderer` (comptime alias) directly
- `build_options` module now required (added via `addOptions` in build.zig)