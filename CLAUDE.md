# Blood Rift Engine — Module Notes

## Module Export Chain

Engine subsystems are exposed via a nested root pattern:

```
engine/src/root.zig          ← game code imports this as "engine"
  └─ renderer/root.zig       ← engine.renderer.*
       ├─ renderer.zig        ← Renderer, DrawCall (vtable abstraction)
       └─ vulkan/root.zig     ← VulkanBackend
  └─ platform/root.zig       ← engine.platform.*
  └─ network/root.zig        ← engine.network.*
  └─ core/root.zig           ← engine.core.*
```

Each subsystem's `root.zig` re-exports the public API. Internal modules are not importable by game code.

## linkSdl3 / linkVulkan Pattern

Both functions are `pub` in `engine/build.zig` and **mirrored** in the root `build.zig`. Both copies must stay in sync.

```zig
// In root build.zig — call for each executable that needs SDL3/Vulkan:
linkSdl3(client_exe);
linkVulkan(client_exe, vulkan_sdk);
```

`linkVulkan` also adds SDL3 include paths so `@cImport(SDL_vulkan.h)` resolves in `backend.zig`.

## Renderer Abstraction Contract

No Vulkan types cross the `Renderer` interface boundary. `VulkanBackend` is a concrete type; callers hold a `Renderer` value (fat pointer + vtable).

```zig
var backend = try VulkanBackend.init(allocator, window.handle, width, height);
defer backend.deinit();
const rend = backend.renderer(); // returns Renderer (vtable handle)
```

The `Renderer` value must not outlive the `VulkanBackend` it was created from.

## Shader Compilation (glslc + WriteFile embed)

SPIR-V files are build artifacts — **not committed to git**. The build system:

1. Runs `glslc` to produce `.spv` files
2. Uses `addWriteFiles` to create Zig wrapper modules alongside the `.spv` files
3. The wrapper uses `@embedFile("triangle.vert.spv")` (resolves relative to generated file)
4. Engine module imports `"vert_spv"` and `"frag_spv"` for use in `pipeline.zig`

## MoltenVK on macOS

The Vulkan loader needs to find the MoltenVK ICD JSON at runtime:

```bash
# Set before running the binary directly:
export VK_ICD_FILENAMES=$VULKAN_SDK/share/vulkan/icd.d/MoltenVK_icd.json
export VK_LAYER_PATH=$VULKAN_SDK/share/vulkan/explicit_layer.d

# Or use the build system run step (sets these automatically):
zig build run
```

The `zig build run` step calls `setEnvironmentVariable` for both vars using the `vulkan-sdk` build option (defaults to `VULKAN_SDK` env var, then a known local path).

## Zig 0.15.2 Compatibility Notes

- Use vulkan-zig commit `bed9e2d` — latest master uses `std.process.Init` not in 0.15.2
- `std.ArrayList(T)` is unmanaged in 0.15.2: pass allocator to `.append`, `.deinit`, etc.
- `std.BoundedArray` does not exist — use plain local arrays
- `vk.makeApiVersion` returns `vk.Version` (packed struct) — `@bitCast` to assign to `u32` fields
