--[[
	Module: FindPlayerByID
	Description: 按 UserId / 距离查找玩家的轻量工具（技能命中等用）
	Author: Dev-Framework
	Created: 2026-07-29
	Last Modified: 2026-07-29
]]

local Players = game:GetService("Players")

local FindPlayerByID = {}

--[[
	按 UserId 查找在线玩家
	@param userId number - 玩家 UserId
	@return Player? - 找到的玩家；不在线为 nil
]]
function FindPlayerByID.Find(userId: number): Player?
	if typeof(userId) ~= "number" then
		return nil
	end
	return Players:GetPlayerByUserId(userId)
end

--[[
	查找距离 position 最近的存活玩家（可选最大距离）
	@param position Vector3 - 世界坐标
	@param maxDist number? - 最大距离；nil 表示不限
	@return Player? - 最近玩家；无则 nil
]]
function FindPlayerByID.findNearestPlayer(position: Vector3, maxDist: number?): Player?
	if typeof(position) ~= "Vector3" then
		return nil
	end
	local best: Player? = nil
	local bestDist = if type(maxDist) == "number" then maxDist else math.huge
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			local d = (hrp.Position - position).Magnitude
			if d <= bestDist then
				bestDist = d
				best = plr
			end
		end
	end
	return best
end

return FindPlayerByID
