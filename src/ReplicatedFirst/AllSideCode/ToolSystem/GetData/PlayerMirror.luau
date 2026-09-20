--[[
	Module: GetData.PlayerMirror
	Description: 玩家 Setting / GamePass 等 Player 下只读镜像查询
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-04

	功能：
	- GetSetting：读 Setting 文件夹 NumberValue；客户端可回退 PlayerData.Setting
	- IsHasPass：GamePass 文件夹下 NumberValue > 0
	- WaitRedPointValue / GetRedPointValue：读 RedPoint 文件夹 NumberValue

	与 GetData.Bag 的关系：
	- Bag 读 Bag/Shard；本模块读 Setting、GamePass 文件夹 NumberValue
	- 客户端 Setting 可回退 PlayerData 会话缓存（IsClient 仅数据源回退，非权威结算）
	- 文件夹名走 EnumMgr.PlayerInst.SettingFolder / GamePassFolder

	加载方式（一般由 GetData/init 聚合）：
		local PlayerMirror = require(script.PlayerMirror)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local PlayerData = Utils.PlayerData
local EnumMgr = Utils.EnumMgr

local PlayerMirror = {}

local PlayerInst = EnumMgr.PlayerInst

--[[
	读取玩家设置项数值（优先 Setting 文件夹 NumberValue，客户端可回退 PlayerData）
	@param plr Player - 玩家对象
	@param setName string - 设置项 ShowName（如 GraphicsQuality）
	@return number? - 设置值；未找到为 nil
]]
function PlayerMirror.GetSetting(plr: Player, setName: string): number?
	if not plr or type(setName) ~= "string" or setName == "" then
		return nil
	end

	local settingFolder = plr:FindFirstChild(PlayerInst.SettingFolder)
	if settingFolder then
		local settingValue = settingFolder:FindFirstChild(setName)
		if settingValue and settingValue:IsA("NumberValue") then
			return settingValue.Value
		end
	end

	if RunService:IsClient() then
		local value = PlayerData.GetPlrDataByKey(plr, { "Setting", setName })
		if value ~= nil then
			return tonumber(value)
		end
	end

	return nil
end

--[[
	检查玩家是否拥有指定 GamePass（GamePass 文件夹下 NumberValue > 0）
	@param plr Player - 玩家对象
	@param onlyTag string - 通行证唯一标签（NumberValue.Name）
	@return boolean - 是否拥有；玩家无效或未找到为 false
]]
function PlayerMirror.IsHasPass(plr: Player, onlyTag: string): boolean
	if not plr or type(onlyTag) ~= "string" or onlyTag == "" then
		return false
	end

	local gamePassFolder = plr:FindFirstChild(PlayerInst.GamePassFolder)
	if not gamePassFolder then
		return false
	end

	local gamePassValue = gamePassFolder:FindFirstChild(onlyTag)
	if not gamePassValue or not gamePassValue:IsA("NumberValue") then
		return false
	end

	return gamePassValue.Value > 0
end

--[[
	等待玩家 RedPoint 文件夹下指定红点 NumberValue（客户端绑定 Changed 用）
	@param plr Player - 玩家对象
	@param redName string - 红点名，如「在线奖励红点」
	@return NumberValue - 对应 NumberValue
]]
function PlayerMirror.WaitRedPointValue(plr: Player, redName: string): NumberValue
	if not plr then
		error("GetData.WaitRedPointValue: plr is required")
	end
	if type(redName) ~= "string" or redName == "" then
		error("GetData.WaitRedPointValue: redName is required")
	end
	local folder = plr:WaitForChild(PlayerInst.RedPointFolder, math.huge) :: Folder
	return folder:WaitForChild(redName, math.huge) :: NumberValue
end

--[[
	读取玩家红点当前数值（文件夹未就绪时为 0）
	@param plr Player - 玩家对象
	@param redName string - 红点名
	@return number - 红点数值（≥0）
]]
function PlayerMirror.GetRedPointValue(plr: Player, redName: string): number
	if not plr or type(redName) ~= "string" or redName == "" then
		return 0
	end
	local folder = plr:FindFirstChild(PlayerInst.RedPointFolder)
	if not folder or not folder:IsA("Folder") then
		return 0
	end
	local node = folder:FindFirstChild(redName)
	if not node or not node:IsA("NumberValue") then
		return 0
	end
	return math.max(0, math.floor(tonumber(node.Value) or 0))
end

return PlayerMirror
