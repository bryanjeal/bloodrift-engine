# Engine Technical Debt

This document tracks known technical debt, limitations, and future work for the Blood Rift Engine.

## Missing Subsystems

### Audio
- **Status**: `audio/` directory exists but contains only `.gitkeep` file
- **Impact**: No sound effects or music
- **Priority**: Medium
- **Notes**: Plan to use FMOD via C bindings. Need to design audio component system and event bus.

### Physics
- **Status**: No physics integration
- **Impact**: Collision detection and response must be implemented in game code
- **Priority**: High (M22+)
- **Notes**: Jolt Physics is the preferred library. Need to design physics component and collision world.

## Performance & Scalability

### Single-Threaded ECS
- **Status**: Flecs world is single-threaded
- **Impact**: Limited parallelism for systems
- **Priority**: High (M23+)
- **Notes**: Consider multi-threaded world or job system for CPU-bound systems (pathfinding, AI).

### Fixed-Point Conversion Precision
- **Status**: `FVec3`/`FQuat` to `Vec3f`/`Quatf` conversions involve scaling and may lose precision
- **Impact**: Minor visual discrepancies in extreme cases
- **Priority**: Low
- **Notes**: Current implementation is acceptable for game scales. Could explore higher precision fixed-point or mixed-precision approaches.

## Platform Abstraction

### Limited Platform Support
- **Status**: Only SDL3 platform abstraction
- **Impact**: Hard to port to other platforms (e.g., mobile, consoles)
- **Priority**: Low (M24+)
- **Notes**: SDL3 covers most desktop platforms. For mobile/console, would need alternative abstraction layer.

### OS Abstraction
- **Status**: `os.zig` handles sockets only
- **Impact**: Other OS services (file I/O, threading) are direct Zig stdlib calls
- **Priority**: Low
- **Notes**: Current approach is acceptable. Could add more wrappers if needed.

## Code Quality

### `@panic` Usage
- **Status**: Some functions use `@panic` for unrecoverable errors (e.g., `parseRendererOption` for invalid backend)
- **Impact**: Crashes on invalid configuration
- **Priority**: Low
- **Notes**: Acceptable for configuration errors that should be caught at build time. Could return errors instead for more graceful handling.

### Manual Reset of Allocators
- **Status**: `ArenaAllocator` and `PoolAllocator` require explicit `reset()` calls
- **Impact**: Easy to forget, leading to memory leaks or incorrect state
- **Priority**: Medium
- **Notes**: Could integrate with frame loop to automate resets. Current approach gives explicit control.

### Shader Compilation
- **Status**: Requires external `glslc` tool and build-time compilation
- **Impact**: Adds build complexity, platform-specific shader binaries
- **Priority**: Medium
- **Notes**: Could explore runtime compilation or bundled SPIR-V files. Current approach ensures shaders are always up-to-date.

## Testing & Validation

### Incomplete Test Coverage
- **Status**: Many systems lack comprehensive tests
- **Impact**: Potential bugs in edge cases
- **Priority**: High
- **Notes**: Simulator provides good coverage for simulation logic. Need more unit tests for core utilities, network, and platform.

### Deterministic Math Edge Cases
- **Status**: Fixed-point math may have edge cases at precision limits
- **Impact**: Rare visual artifacts or simulation divergence
- **Priority**: Low
- **Notes**: Current implementation has been validated with simulator. Could add more property-based tests.

## Documentation

### Missing Documentation
- **Status**: No README, ARCHITECTURE, or TECH_DEBT files until now
- **Impact**: Onboarding new developers is harder
- **Priority**: Low (resolved)
- **Notes**: These files now exist. Need to keep them updated as architecture evolves.

### CLAUDE.md Outdated Sections
- **Status**: Module Export Chain and Renderer Abstraction Contract sections outdated due to backend abstraction changes
- **Priority**: High (resolved)
- **Notes**: Updated in this commit.

## Migration Paths

### Backend Abstraction Changes
- **Impact**: `MaterialDef.vertex_spv`/`fragment_spv` renamed to `vertex_shader`/`fragment_shader`
- **Fix**: Update all game code using these fields
- **Impact**: `VulkanBackend.renderer()` method removed
- **Fix**: Use `Renderer` type alias directly (comptime-resolved)
- **Impact**: New `build_options` module required
- **Fix**: Add `engine_module.addOptions("build_options", options)` in game build.zig

## Future Work

### Planned Features
- Audio system (M21)
- Physics integration (M22)
- WebGPU backend (M25+)
- OpenGL backend (M25+)
- Multi-threaded ECS (M23+)
- Asset loading pipeline (M20)

### Performance Optimizations
- SSBO buffer pooling
- Instanced rendering optimizations
- Network packet batching
- ECS query caching

## References

- `CLAUDE.md` - Engine module/build conventions
- `docs/design/DESIGN_DECISIONS.md` - Game design decisions
- `docs/dev/GUIDELINES.md` - Development rules and workflow
- `docs/dev/TECH_DEBT.md` (this file)

## Last Updated

2026-04-13 by Claude Code