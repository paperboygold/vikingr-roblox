# Vikingr Roblox Prototype

This folder mirrors the live Roblox Studio modules created through Studio MCP.

The current implementation is intentionally hash-first:

- `ReplicatedStorage.Vikingr.Hash` is the central substrate.
- `ReplicatedStorage.Vikingr.WorldSpec` owns deterministic map constants and region functions.
- `ReplicatedStorage.Vikingr.ChunkStore` builds coordinate-keyed world state.
- `ReplicatedStorage.Vikingr.RegimeField` collapses local terrain regimes with an entropy-ordered WFC-style pass.
- `ReplicatedStorage.Vikingr.TerrainField` builds smooth coastline, cliff, mountain, river, and lake fields from the hash state.
- `ServerScriptService.Vikingr.TerrainWriter` writes chunked 4-stud Roblox Terrain voxels and markers.
- `ServerScriptService.Vikingr.Profiler` wraps generation benchmarks and scene-health probes.
- `ServerScriptService.Vikingr.Map` is the public entrypoint.
- `ServerScriptService.Vikingr.Bootstrap` runs a no-write health check by default. Set `Workspace.VikingrGenerateOnBoot = true` only when runtime generation is intentionally wanted.

Run in Studio:

```lua
require(game.ServerScriptService.Vikingr.Map).Generate()
require(game.ServerScriptService.Vikingr.Map).BenchScenarios()
require(game.ServerScriptService.Vikingr.Map).ValidateNaturalWater()
```

`Generate()` writes the full voxel map and is intended as an explicit Studio/Edit operation for now. Runtime play startup should use the default no-write bootstrap path so clients do not wait on the full terrain bake.

`Workspace.VikingrClearTerrainWaterForOceanMesh = true` enables the legacy ocean-mesh-only cleanup that removes terrain `Water` voxels. Leave it unset by default: Roblox `ReplaceMaterial` is region-wide, so this pass can also remove inland lake and river water.

Production rendering uses one native Roblox Terrain water body for ocean, rivers, and lakes. `WorldSpec.Config.waterRenderer` defaults to `"terrain"`; this also leaves swimming to Roblox's native Humanoid controller. The conservative custom ocean remains in source for experiments, but setting the renderer to `"custom"` is not a production configuration until it owns every water surface and supplies a certified cell-to-mesh reconstruction.

The particle-fluid visual demo is separately disabled by default through `WorldSpec.Config.enableFluidParticleDemo`.

## Windows handoff

Install Roblox Studio and the Rojo Studio plugin on the Windows machine. Install the Rojo CLI from the [Rojo releases](https://github.com/rojo-rbx/rojo/releases) page and make sure `rojo.exe` is available in PowerShell.

From the cloned repository:

```powershell
rojo serve default.project.json
```

In Roblox Studio, open the Rojo plugin, connect to `localhost:34872`, and open the project place. Keep the Rojo terminal running while editing. Stop Play mode before syncing source changes, then start a fresh Play session so Studio does not reuse cached module values.

Useful checks:

```powershell
rojo build default.project.json -o build\Vikingr.rbxlx
```

Generation is intentionally not run on Play startup. In Studio edit mode, run the commands below from the Command Bar when a new map is wanted:

```lua
require(game.ServerScriptService.Vikingr.Map).Generate()
require(game.ServerScriptService.Vikingr.Map).BenchScenarios()
require(game.ServerScriptService.Vikingr.Map).ValidateNaturalWater()
```

The local `.mcp.json` is deliberately ignored because it contains machine-specific connector paths. It is not required for Rojo or for running the project.
