# Blood Rift Engine Architecture

The Blood Rift Engine is designed around a few core architectural principles:

1. **Deterministic Simulation** - Fixed-point arithmetic ensures bit-identical results across all platforms
2. **Data-Oriented Design** - DOD rendering with SSBO instancing and ECS-based entity management
3. **Comptime Dispatch** - Backend selection, OS platform, and generic types resolved at compile time
4. **Zero Hot-Allocation** - Fixed-capacity allocators with no dynamic growth in performance-critical paths

## System Overview

The engine is organized into logical subsystems, each with a clear responsibility:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Application Layer                           │
│  (Game code, client/server logic, input handling)                 │
├─────────────────────────────────────────────────────────────────────┤
│                        Engine Subsystems                            │
├──────────┬──────────┬──────────┬──────────┬──────────┬─────────────┤
│   Core   │ Renderer │ Network  │ Platform │   OS     │   Audio     │
│          │          │          │          │          │   (future)  │
└──────────┴──────────┴──────────┴──────────┴──────────┴─────────────┘
```

## Core Subsystem

The core provides fundamental utilities used throughout the engine:

### Fixed-Point Arithmetic
- `Fp16` (Q16.16) for deterministic world coordinates and velocities
- Pre-computed sin/cos lookup table with linear interpolation
- Integer square root for fixed-point length calculations

### Vector Types
- `FVec3` - Fixed-point 3D vector for simulation
- `Vec3f` - Floating-point 3D vector for rendering
- `FQuat` / `Quatf` - Quaternions for rotation
- `Mat4f` - 4x4 column-major matrix for view/projection

### ECS (Entity Component System)
- Flecs ECS via `zflecs` bindings
- Archetype-based storage for cache-friendly iteration
- `SidecarStore` for O(1) non-ECS systems with snapshot/rollback support

### Memory Allocators
- `ArenaAllocator` - Bump allocator with reset for frame-temporary allocations
- `PoolAllocator(T)` - Fixed-capacity free-list pool for typed objects
- All capacity fixed at init time; no dynamic growth

### Random Number Generator
- SFC64 PRNG for deterministic sequences
- Independent RNG instances; no global state
- Uniform distributions, integer ranges, and shuffling

## Renderer Subsystem

The renderer implements a Data-Oriented Design (DOD) pipeline:

### Backend Abstraction
- Compile-time backend selection via `-Dbackend=vulkan|webgpu|opengl`
- `Renderer` type alias resolved at comptime using `build_options.renderer`
- `assertRendererInterface()` comptime validation ensures backend implements required methods

### DOD Render Queue
- Single SSBO for instance data (host-visible, persistently mapped)
- Instances sorted by material_id to minimize draw calls
- Push constants for camera view/projection matrix only (64 bytes)
- Material pipelines pre-created at init time

### Shader Compilation
- Build-time compilation via `glslc` to SPIR-V
- Embedded via `@embedFile` in Zig wrapper modules
- No shader files committed to git

### Public API
```zig
const Renderer = @import("engine").renderer.Renderer;
const CameraData = renderer.CameraData;
const InstanceData = renderer.InstanceData;
const MaterialDef = renderer.MaterialDef;
const RenderQueue = renderer.RenderQueue;
```

## Network Subsystem

The network layer provides reliable, ordered messaging:

### Transport Abstraction
- `Transport` interface with TCP implementation
- Length-prefix framing (`[u32 big-endian length][payload]`)
- Non-blocking I/O with configurable timeout

### TCP Implementation
- `TcpTransport` for client connections
- `TcpListener` for server sockets
- Cross-platform socket wrappers handle Windows/POSIX differences

## Platform Subsystem

The platform layer abstracts OS-specific details:

### SDL3 Integration
- Window creation and management
- Input handling via `InputSnapshot`
- High-resolution timer
- Vulkan loader integration

### OS Abstraction
- Socket I/O wrappers (`socketSendAll`, `socketRecv`)
- Socket pair creation for testing
- Error mapping between Windows and POSIX

## Determinism Boundary

A key architectural constraint is the separation between simulation and rendering:

- **Simulation Types**: `FVec3`, `FQuat`, `Fp16` (fixed-point)
- **Rendering Types**: `Vec3f`, `Quatf`, `Mat4f` (floating-point)
- **Boundary Conversions**: `toVec3f()` / `toFVec3()` only at sim-to-render handoff

This ensures bit-identical simulation results across all platforms while allowing rendering to use hardware floats.

## Comptime Dispatch

Many decisions are resolved at compile time to eliminate runtime overhead:

- **Backend Selection**: `-Dbackend=vulkan|webgpu|opengl` selects renderer
- **OS Platform**: `builtin.os.tag` selects appropriate OS abstractions
- **Generic Types**: `FixedPoint(N)`, `SidecarStore(Entry, cap, depth)`, `PoolAllocator(T)`

## Zero Hot-Allocation

All performance-critical paths use fixed-capacity allocators:

- **Frame-Temporary**: `ArenaAllocator` (bump + reset per frame)
- **Fixed-Type Pools**: `PoolAllocator(T)` with free-list
- **Sidecar Systems**: `SidecarStore` with pre-allocated dense arrays

No heap allocation occurs during simulation or rendering ticks.

## VTable Abstractions

Where runtime polymorphism is needed, vtable patterns are used:

- **Transport/Listener** - Networking abstraction
- **Renderer** - Backend abstraction (now comptime-resolved)

These are validated at compile time via `assertRendererInterface()` to catch mismatches early.

## Future Work

- Audio subsystem (placeholder in `audio/`)
- Physics integration
- WebGPU backend
- OpenGL backend
- Multi-threading for ECS systems
- Asset loading pipeline

## References

- `CLAUDE.md` - Engine module/build conventions
- `docs/design/DESIGN_DECISIONS.md` - Game design decisions
- `docs/dev/GUIDELINES.md` - Development rules and workflow