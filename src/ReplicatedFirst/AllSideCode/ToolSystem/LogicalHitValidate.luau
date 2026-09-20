--[[
	Module: LogicalHitValidate
	Description: 逻辑怪受击权威粗检（白名单 + CombatReady + 距离）
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-08-12

	功能：
	- canAcceptPlayerHit：玩家打逻辑怪是否可结算（alive / 白名单 / combatReady / 距离）
	- 与 SystemEnemy.Hit / collectLogicalOverlapHits 配合：几何命中后再粗检

	约束：
	- 白名单空表 = 全开（与 CreateLogicalEnemy L1 约定一致）
	- 仅读 EnemyLogicalStore；不写权威状态

	加载：
		local LogicalHitValidate = Utils.LogicalHitValidate
]]

local Players = game:GetService("Players")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnemyLogicalStore = Utils.EnemyLogicalStore

local LogicalHitValidate = {}

local DEFAULT_MAX_HIT_RANGE = 80

--[[
	玩家攻击逻辑怪是否可接受

	@param playerId number - 攻击者 UserId
	@param enemyId number - 逻辑怪运行时 id
	@param hitData any? - 可含 maxRange（stud）；缺省 DEFAULT_MAX_HIT_RANGE
	@return boolean - 通过校验为 true
]]
function LogicalHitValidate.canAcceptPlayerHit(playerId: number, enemyId: number, hitData: any?): boolean
	local uid = tonumber(playerId)
	local id = tonumber(enemyId)
	if not uid or not id then
		return false
	end

	local rec = EnemyLogicalStore.get(id)
	if not rec or not rec.alive then
		return false
	end
	if not rec.combatReady then
		return false
	end
	-- 空白名单 = 全开
	if next(rec.allowedSet) ~= nil and not rec.allowedSet[uid] then
		return false
	end

	local plr = Players:GetPlayerByUserId(uid)
	local character = plr and plr.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return false
	end

	local maxRange = DEFAULT_MAX_HIT_RANGE
	if type(hitData) == "table" and typeof(hitData.maxRange) == "number" and hitData.maxRange > 0 then
		maxRange = hitData.maxRange
	end

	local enemyPos = rec.cframe.Position
	local dist = (hrp.Position - enemyPos).Magnitude
	return dist <= maxRange
end

return LogicalHitValidate
