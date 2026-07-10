--!strict

-- OceanWater (server) — optional compatibility pass for old ocean-mesh-only builds.
-- It is deliberately opt-in: ReplaceMaterial is region-wide and cannot distinguish open
-- ocean from inland lakes/rivers, so running it by default deletes real terrain water.
--
-- MUST run AFTER the terrain regeneration (Bootstrap) actually finishes. Bootstrap's
-- TerrainWriter.write takes ~60s and yields throughout; this script has no yields and would
-- otherwise finish and clear water in milliseconds — i.e. long before the real terrain (and
-- its own fresh Water material, painted from the seabed up to sea level in every column)
-- even exists. That ordering bug is exactly why the default Roblox water shader kept
-- reappearing: nothing ever cleared the water the regen itself had just written.
--
-- No more separate flat "far water backdrop" — the real seabed (ReliefField's underwater
-- relief) now covers the whole map, so there is a genuine floor everywhere and that stopgap
-- plane (sitting a fixed 10 studs below sea level) is exactly the stray "second surface one
-- block down" that's now obsolete.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldSpec = require(ReplicatedStorage:WaitForChild("Vikingr"):WaitForChild("WorldSpec"))
local cfg = WorldSpec.Config
local SEA = cfg.seaLevel

-- clean up any leftover stopgap backdrop from earlier builds
local stale = workspace:FindFirstChild("OceanFarBase")
if stale then
	stale:Destroy()
end

if workspace:GetAttribute("VikingrBootstrapRan") ~= true then
	workspace:GetAttributeChangedSignal("VikingrBootstrapRan"):Wait()
end

local halfW = cfg.width * cfg.cellSize / 2
local halfD = cfg.depth * cfg.cellSize / 2

if workspace:GetAttribute("VikingrClearTerrainWaterForOceanMesh") ~= true then
	return
end

-- Destructive legacy mode. This clears every Water voxel in the ocean Y band, including
-- inland water if it overlaps the region, so only enable it for mesh-only ocean tests.
local region = Region3.new(
	Vector3.new(-halfW - 64, SEA - cfg.waterDepth - 64, -halfD - 64),
	Vector3.new(halfW + 64, SEA + 6, halfD + 64)
):ExpandToGrid(4)
workspace.Terrain:ReplaceMaterial(region, 4, Enum.Material.Water, Enum.Material.Air)
