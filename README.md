# Blood Rift Engine

The Blood Rift Engine is a modern, cross-platform game engine built in Zig. It provides a solid foundation for building deterministic, high-performance games with Data-Oriented Design (DOD) rendering and a flexible ECS architecture.

## Features

- **Deterministic Simulation** - Fixed-point arithmetic (Q16.16) ensures bit-identical results across all platforms
- **Flecs ECS** - High-performance entity-component system with archetype-based storage
- **Vulkan Rendering** - Modern graphics API with abstraction layer for future backends
- **Cross-Platform** - Windows, macOS, and Linux support via SDL3
- **Deterministic RNG** - SFC64 PRNG for reproducible game states
- **Sidecar Systems** - O(1) lookup for non-ECS data with snapshot/rollback support
- **Zero Hot-Allocation** - Arena, pool, and sidecar allocators with fixed capacity

## Quick Start

### Prerequisites

- Zig 0.15.2 or later
- Vulkan SDK (for development)
- SDL3 development libraries (Windows only)

### Building

The engine is built as a library. To run tests:

```bash
zig build test
```

To build the engine (if needed):

```bash
zig build
```

Note: The game client, server, and simulator are part of the private repository and are not included in this sub-module.

## Directory Structure

```
engine/src/
├── audio/              # (Planned) Audio subsystem
├── core/               # Core utilities and types
│   ├── types/          # Fundamental types (EntityId, Tick, Color)
│   ├── ecs.zig         # Flecs ECS wrapper
│   ├── fixed_point.zig # Fixed-point arithmetic
│   ├── math.zig        # Vector types (FVec3, Vec3f)
│   ├── memory.zig      # Allocators (Arena, Pool)
│   ├── random.zig      # Deterministic RNG
│   └── sidecar_store.zig # O(1) sidecar system store
├── network/            # Networking layer
│   ├── transport.zig   # Transport abstraction
│   ├── tcp.zig         # TCP implementation
│   └── framing.zig     # Length-prefix message framing
├── os.zig              # Cross-platform OS abstractions
├── platform/           # Platform layer (SDL3)
│   └── sdl3.zig        # Window, timer, input handling
├── renderer/           # Rendering subsystem
│   ├── renderer.zig    # Backend-agnostic DOD render queue
│   └── vulkan/         # Vulkan backend implementation
└── src/root.zig        # Top-level engine module
```

## Public API

The engine is organized into logical modules:

```zig
const engine = @import("engine");

// Core utilities
const core = engine.core;
const ecs = core.ecs;
const math = core.math;
const random = core.random;
const sidecar = core.sidecar_store;

// Rendering
const renderer = engine.renderer;
const VulkanBackend = renderer.vulkan.VulkanBackend;

// Networking
const network = engine.network;
const TcpTransport = network.TcpTransport;

// Platform
const platform = engine.platform;
const Window = platform.Window;
const InputSnapshot = platform.InputSnapshot;
```

Each subsystem's `root.zig` re-exports its public API. Internal modules are not importable by game code.

## Design Principles

- **Determinism** - Fixed-point math, deterministic RNG, and no dynamic allocation in hot paths
- **Zero-Cost Abstractions** - Comptime dispatch for backend selection, OS platform, and generic types
- **Explicit State** - No global state; allocators, RNG, and ECS worlds passed explicitly
- **Safety** - Assert liberally, handle all errors, and validate inputs
- **Performance** - DOD patterns, SSBO instancing, and minimal draw calls

## Contributing

See `docs/CONTRIBUTING.md` for development guidelines and `CLAUDE.md` for engine-specific conventions.

## License

The Blood Rift Engine is open source under the MIT License. See `LICENSE` for details.