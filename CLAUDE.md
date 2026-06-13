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

## Directory Structure

```
engine/
├── src/
│   ├── root.zig              # Public entry point ("engine" import)
│   ├── core/                 # ECS (World wrapper), math (Fp16/FVec3/FQuat), memory, allocators
│   ├── renderer/             # Renderer abstraction + Vulkan backend
│   │   └── vulkan/           # Vulkan-specific pipeline, shaders, swapchain
│   ├── platform/             # SDL3 windowing, input, Vulkan surface
│   ├── network/              # Transport abstraction + TCP
│   ├── physics/              # Jolt Physics integration
│   └── audio/                # FMOD integration
├── build.zig                 # Engine build (linkSdl3, linkVulkan, shader compilation)
└── build.zig.zon
```

For Zig conventions (TIGER_STYLE overrides, antipatterns, code style), see the project root CLAUDE.md.

## linkSdl3 / linkVulkan Pattern

Both functions are `pub` in `engine/build.zig` and **mirrored** in the root `build.zig`. Both copies must stay in sync.

```zig
// In root build.zig — call for each executable that needs SDL3/Vulkan:
linkSdl3(client_exe);
linkVulkan(client_exe, vulkan_sdk);
```

`linkVulkan` also adds SDL3 include paths so `@cImport(SDL_vulkan.h)` resolves in `backend.zig`.

## Renderer Abstraction Contract

The `Renderer` type is now a comptime alias, not a runtime vtable wrapper. The `-Dbackend=` build option selects the concrete backend at compile time via `switch (build_options.renderer)`. Backends are validated at comptime via `assertRendererInterface()`.

```zig
const Renderer = @import("engine").renderer.Renderer; // comptime-selected type
var backend = try Renderer.init(
    allocator,
    window.handle,
    width,
    height,
    @import("render/materials.zig").ALL_MATERIALS, // required materials parameter
);
defer backend.deinit(); // deinit takes a pointer to the backend; method call auto-converts
```

All backend structs must implement the required interface: `beginFrame`, `submitQueue`, `endFrame`, `present`, `resize`, `deinit`. Violations are compile errors.

`ShaderPayload` is a comptime-switched type:
- `.vulkan` => `[]align(@alignOf(u32)) const u8` (SPIR-V)
- `.webgpu` => `[]const u8` (WGSL)
- `.opengl` => `[:0]const u8` (GLSL)

Build with `-Dbackend=vulkan` (default) or `-Dbackend=webgpu`/`-Dbackend=opengl` when those backends are implemented.

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

## ECS Module (core/ecs.zig)

The `World` struct wraps Flecs lifecycle and common operations. Raw zflecs bindings are re-exported as `World.zflecs` for advanced use (observers, custom queries, iterators). Game code should prefer `World` methods for common operations and use `World.zflecs` only when the wrapper doesn't provide what's needed.

```zig
const World = @import("engine").core.ecs.World;
const zflecs = World.zflecs; // raw bindings for observers, etc.

// Common operations via World methods:
world.registerComponent(MyComponent);
world.setComponent(entity, MyComponent, .{ .field = value });
const comp = world.getComponent(entity, MyComponent);

// Advanced operations via raw zflecs:
var desc: zflecs.observer_desc_t = .{ .callback = myCallback };
desc.events[0] = zflecs.OnAdd;
desc.query.terms[0] = .{ .id = zflecs.id(MyComponent) };
_ = zflecs.observer_init(world.raw, &desc);
```

## Build & Test

```bash
zig build test              # Engine test suite (from engine/ directory)
zig build test --watch      # Continuous testing during engine development
```

Run from the project root: `zig build test` also runs engine tests (engine is a dependency).

## Zig 0.15.2 Compatibility Notes

- Use vulkan-zig commit `bed9e2d` — latest master uses `std.process.Init` not in 0.15.2
- `std.ArrayList(T)` is unmanaged in 0.15.2: pass allocator to `.append`, `.deinit`, etc.
- `std.BoundedArray` does not exist — use plain local arrays
- `vk.makeApiVersion` returns `vk.Version` (packed struct) — `@bitCast` to assign to `u32` fields

## Vulkan Synchronization (Spec-Compliant)

### Authoritative References

All synchronization decisions MUST cite at least one of:

- **Vulkan 1.3 Specification** — §7 (Synchronization and Cache Control), §30.6 (Swapchain Creation), §30.10 (WSI Semaphore/Fence Contracts)
- **Vulkan Programming Guide** (Graham Sellers, 2016) — Chapter 9 (Synchronization), Chapter 11 (The Swapchain)
- **GPUOpen Vulkan Memory / Sync Primer** — <https://gpuopen.com/learn/vulkan-memory-sync-primer/>
- **MoltenVK Best Practices** — <https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Runtime_UserGuide.md>

### Indexing Rule (BLOCKING)

**Every synchronization primitive MUST have its indexing scheme explicitly justified against the resource's actual lifetime.** Add a comment at the declaration site for each array of fences, semaphores, or command buffers explaining:

1. What does this array index by? (frame counter? image index? something else?)
2. What is the resource's lifetime? (same-frame? cross-frame? per-image?)
3. Why is this indexing scheme correct per the Vulkan spec?

Counters over time:

| Resource | Lifetime | Index by |
|----------|----------|----------|
| Acquire semaphore | Same-frame (acquire→submit) | Frame counter |
| Render semaphore | Cross-frame (submit→present) | Swapchain image index |
| In-flight fence | Same-frame (submit→CPU wait) | Frame counter |
| Command buffer | Per-swapchain-image (records into specific framebuffer) | Swapchain image index |
| Framebuffer | Per-swapchain-image (attached to specific image view) | Swapchain image index |
| Uniform/staging buffer | Per-frame-in-flight (CPU writes between fence signals) | Frame counter |

### Platform-Specific Gotchas

- **MoltenVK image count:** On macOS, MoltenVK may create 3 swapchain images even when `min_image_count` is 2. Never assume `image_count == max_frames_in_flight`. Always queried `sc.image_views.len` at runtime and allocate per-image resources accordingly.
- **MoltenVK present timing:** The Metal present engine may defer semaphore consumption differently from desktop Vulkan drivers. A fence covering the submit does NOT guarantee the present engine has consumed the render semaphore. Use per-image render semaphores to avoid this race.
- **`min_image_count` is a request, not a guarantee:** The Vulkan spec states the implementation may create more images than requested. Per-image arrays must be sized by `getSwapchainImagesKHR` output, not by `min_image_count`.

### Anti-Patterns (Never Do These)

- **Never index synchronization primitives by frame counter when the resource lifetime is tied to a swapchain image.** This causes undefined behavior when `swapchain_image_count > max_frames_in_flight`.
- **Never assume `swapchain_image_count == max_frames_in_flight`.** This works by coincidence on some desktop drivers but fails on MoltenVK and is not spec-guaranteed.
- **Never bundle acquire semaphore, render semaphore, and fence into a single per-frame struct** when they have different lifetime domains. Keep per-frame and per-image resources in separate arrays with explicit comments.
- **Never use the same semaphore array for acquire and present** when they operate on different indexing domains (same-frame vs. cross-frame).
