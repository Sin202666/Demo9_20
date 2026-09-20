--[[
	Module: HitResolver.Destructible
	Description: 可破坏物命中（扣 HP、缓存、延迟刷新）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	残骸短时 BodyVelocity 只写可破坏物克隆体，不写角色。
	业务只经 Utils.HitResolver.applyHit，不要直接 require 本文件。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CollectionService = Utils.CollectionService
local VisibleMgr = Utils.VisibleMgr
local FindPlayerByID = Utils.FindPlayerByID
local SoundModule = Utils.SoundModule
local InsMgr = Utils.InsMgr
local Debris = Utils.Debris
local GetData = Utils.GetData
local GameGlobalConfig = Utils.GameGlobalConfig

local globalConfig = GameGlobalConfig.Get()

local Destructible = {}

--[[
	结算可破坏物命中：扣 HP，归零后收入缓存并按配置延迟刷新。
	beHit=nil：可破坏物跳过无敌检查；伤害优先 hitData.finalDamage。

	@param enemyModel Model? - 可破坏物模型；nil 则直接返回
	@param partParent Model - 带 HP Attribute 的部件父级（通常与 enemyModel 同体）
	@param hitData table - 伤害包，含 finalDamage 等
	@param hitbox any - 命中盒（刷新击退方向用）
	@param knockback number? - 击退速度（stud/s）；>0 时对残存体写短时 BodyVelocity
	@return nil
]]
function Destructible.applyBroken(enemyModel, partParent, hitData, hitbox, knockback)
	if not enemyModel then
		return
	end

	local Dmg = select(1, GetData.GetDmg(enemyModel, nil, hitData))
	Dmg = tonumber(Dmg) or 0
	if Dmg <= 0 then
		return
	end
	local oldHp = partParent:GetAttribute("HP")
	if oldHp then
		oldHp = oldHp - Dmg
		partParent:SetAttribute("HP", oldHp)
		if oldHp <= 0 then
			local baseCf = partParent:GetPivot()
			local oldParent = partParent.Parent

			partParent.Parent = InsMgr.GetIns("可破坏物缓存", "Folder", game.ServerStorage)

			task.delay(globalConfig["可破坏物"]["恢复时间"], function()
				while true do
					if not FindPlayerByID.findNearestPlayer(baseCf.Position, globalConfig["可破坏物"]["检测周围有人距离"]) then
						partParent.Parent = oldParent
						partParent:PivotTo(baseCf)
						partParent:SetAttribute("HP", partParent:GetAttribute("HPMAX"))
						return
					end
					task.wait(globalConfig["可破坏物"]["检测周围有人距离时间"])
				end
			end)

			local newBroken: Model = partParent:Clone()
			Debris:AddItem(newBroken, 10)
			task.delay(5, function()
				VisibleMgr.fadeAllTween(newBroken)
			end)

			newBroken.Parent = workspace
			newBroken:PivotTo(baseCf)

			VisibleMgr.SetCollideID(newBroken, "BrokenEnd")
			VisibleMgr.UnAnchoredAll(newBroken)
			for _, v in pairs(newBroken:GetDescendants()) do
				CollectionService:RemoveTag(v, "WindShake")
				if v:IsA("BasePart") then
					v.Massless = true
					v.CanCollide = true
				end
			end

			local Sound = partParent:GetAttribute("Sound")
			if Sound then
				local soundData = {
					SoundName = Sound,
					Is2D = false,
					PlayPosition = baseCf.Position,
				}
				for _, plr in pairs(game.Players:GetChildren()) do
					SoundModule:PlaySound(plr, soundData)
				end
			end

			local refPos = (hitbox and hitbox.hitbox and hitbox.hitbox.Parent and hitbox.hitbox.Position) or partParent:GetPivot().Position
			for _, v in pairs(newBroken:GetChildren()) do
				local Primary = (v:IsA("Model") and (v :: Model).PrimaryPart) or (v:IsA("BasePart") and v) or nil
				if Primary then
					local delta = Primary.Position - refPos
					delta = Vector3.new(delta.X, 0, delta.Z)
					if delta.Magnitude > 0.001 then
						local MoveDirection = delta.Unit
						local existingBodymover = Primary:FindFirstChildOfClass("BodyVelocity")
						if existingBodymover then
							existingBodymover:Destroy()
						end
						local Bodymover = InsMgr.GetIns("Bodymover", "BodyVelocity", Primary)
						Bodymover.MaxForce = Vector3.new(1, 0, 1) * 25000
						Bodymover.Velocity = MoveDirection * knockback
						Bodymover.Parent = Primary
						task.delay(0.15, function()
							Debris:AddItem(Bodymover, 0)
						end)
					end
				end
			end
			return
		end
	end
end

return Destructible
