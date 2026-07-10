--!strict

-- UnderwaterEffect (client) — post-processing that makes it unmistakable when the CAMERA
-- crosses beneath the wave surface: a blue-green colour tint + murk blur that deepen with
-- depth, plus tighter depth-of-field. Reads the same field the surface is drawn from
-- (_G.VikingrOcean) so the waterline is exact and moves with the swell.

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local cc = Instance.new("ColorCorrectionEffect")
cc.Name = "UnderwaterCC"
cc.Enabled = false
cc.Parent = Lighting

local blur = Instance.new("BlurEffect")
blur.Name = "UnderwaterBlur"
blur.Enabled = false
blur.Size = 0
blur.Parent = Lighting

local SHALLOW = Color3.fromRGB(55, 130, 170)
local DEEP = Color3.fromRGB(14, 58, 104)

RunService.RenderStepped:Connect(function()
	local ocean = _G.VikingrOcean
	if ocean == nil then
		return
	end
	local p = Workspace.CurrentCamera.CFrame.Position
	local depth = ocean:heightAt(p.X, p.Z) - p.Y

	if depth > 0 then
		local d = math.clamp(depth / 45, 0, 1)
		cc.Enabled = true
		cc.TintColor = SHALLOW:Lerp(DEEP, d)
		cc.Brightness = -0.06 - 0.16 * d
		cc.Contrast = 0.08
		cc.Saturation = 0.12
		blur.Enabled = true
		blur.Size = 5 + 15 * d
	else
		if cc.Enabled then
			cc.Enabled = false
			blur.Enabled = false
		end
	end
end)
