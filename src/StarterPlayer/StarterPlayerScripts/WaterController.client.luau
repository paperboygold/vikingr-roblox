--!strict

-- WaterController (client) — makes the ocean a BODY you swim in, without Roblox Terrain
-- water. Reads the same field the surface is drawn from (_G.VikingrOcean):
--   • sticky water state (spatial hysteresis + TIME debounce) so bobbing on big open-sea
--     swell (now ±20 studs) can't rapid-toggle it — the previous thresholds (tuned for the
--     old ±5-10 stud waves) were far too tight for the new broadband swell and thrashed the
--     Swimming/GettingUp state every wave cycle, which reads as "locked up, can't move".
--   • horizontal swim direction is the camera's YAW only (LookVector/RightVector flattened
--     to the horizontal plane) — vertical motion is Space/Shift explicitly, or idle
--     buoyancy. Previously the FULL 3D LookVector drove swimming, so a downward-pitched
--     camera made holding W involuntarily dive the player deeper and deeper — losing
--     vertical control is the other half of "can't move on a wave".
--   • one LinearVelocity drives motion (no spring/bob fighting the animation).
-- Ships reuse Ocean:heightAt/normalAt for buoyancy the same way.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local SHORE_STAND = 4.2 -- leave swimming when ground is within this many studs under the feet
local ENTER_DEPTH = 2.0 -- studs under the local wave surface before entering water
local LEAVE_DEPTH = -7.0 -- studs above the local wave surface before leaving water
local DEBOUNCE = 0.3 -- seconds a transition condition must hold before it takes effect

local player = Players.LocalPlayer
local SWIM_SPEED = 16

local function onCharacter(char: Model)
	local humanoid = char:WaitForChild("Humanoid") :: Humanoid
	local root = char:WaitForChild("HumanoidRootPart") :: BasePart

	local att = Instance.new("Attachment")
	att.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = math.huge
	lv.VectorVelocity = Vector3.zero
	lv.Enabled = false
	lv.Parent = root

	local inWater = false
	local pendingSince: number? = nil -- time.clock() when the opposite condition started holding

	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	groundParams.FilterDescendantsInstances = { char }
	groundParams.IgnoreWater = true

	local function key(k: Enum.KeyCode): number
		return UserInputService:IsKeyDown(k) and 1 or 0
	end

	local function enter()
		inWater = true
		pendingSince = nil
		lv.Enabled = true
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
	end

	local function leave()
		inWater = false
		pendingSince = nil
		lv.Enabled = false
		lv.VectorVelocity = Vector3.zero
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end

	RunService.Heartbeat:Connect(function()
		local ocean = _G.VikingrOcean
		if ocean == nil or root.Parent == nil then
			return
		end
		local pos = root.Position
		local surf = ocean:heightAt(pos.X, pos.Z)
		local depth = surf - pos.Y -- >0 when the root is under the waterline
		local now = os.clock()

		if not inWater then
			if depth > ENTER_DEPTH then
				if pendingSince == nil then
					pendingSince = now
				elseif now - pendingSince >= DEBOUNCE then
					enter()
				end
			else
				pendingSince = nil
			end
			return
		end

		-- smooth shore exit: stop swimming the moment standable ground is under the feet
		local hit = Workspace:Raycast(pos, Vector3.new(0, -5.5, 0), groundParams)
		local onShore = hit ~= nil and (pos.Y - hit.Position.Y) < SHORE_STAND
		if onShore or depth < LEAVE_DEPTH then
			if pendingSince == nil then
				pendingSince = now
			elseif onShore or now - pendingSince >= DEBOUNCE then
				leave() -- shore exit is immediate (no debounce); open-water exit is debounced
				return
			end
		else
			pendingSince = nil
		end
		lv.Enabled = true -- safeguard: keep swim control live while submerged

		-- horizontal swim direction: camera YAW only (flattened) — looking up/down must not
		-- force the player to rise/dive; that's Space/Shift
		local cf = Workspace.CurrentCamera.CFrame
		local fwd = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
		if fwd.Magnitude > 0.01 then
			fwd = fwd.Unit
		end
		local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
		if right.Magnitude > 0.01 then
			right = right.Unit
		end
		local horiz = fwd * (key(Enum.KeyCode.W) - key(Enum.KeyCode.S))
			+ right * (key(Enum.KeyCode.D) - key(Enum.KeyCode.A))

		local upKey, downKey = key(Enum.KeyCode.Space), key(Enum.KeyCode.LeftShift)
		local vy: number
		if upKey > 0 or downKey > 0 then
			vy = (upKey - downKey) * SWIM_SPEED
		else
			-- idle/auto buoyancy: track the (moving) surface — gain/cap raised so it can
			-- keep pace with big open-sea swell instead of lagging on the steep part of a
			-- wave (where the old cap fell behind the surface's own rate of change)
			vy = math.clamp((surf - 0.6 - pos.Y) * 6, -16, 16)
		end
		local vel = (horiz.Magnitude > 0.1 and horiz.Unit * SWIM_SPEED or Vector3.zero) + Vector3.new(0, vy, 0)
		-- don't launch out of the water: cap upward motion once the head is at the surface
		if pos.Y > surf - 0.4 and vel.Y > 0 then
			vel = Vector3.new(vel.X, 0, vel.Z)
		end
		lv.VectorVelocity = vel

		-- keep the swim animation running: only re-assert if the engine drifted it off
		if humanoid:GetState() ~= Enum.HumanoidStateType.Swimming then
			humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
		end
	end)
end

if player.Character then
	onCharacter(player.Character)
end
player.CharacterAdded:Connect(onCharacter)
