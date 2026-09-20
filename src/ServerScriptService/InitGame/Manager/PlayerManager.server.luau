--[[
	Module: PlayerManager
	Description: 服务端玩家生命周期管理器，编排玩家加入/离开与各 System 初始化
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-09-04

	功能：
	- 玩家加入时按序初始化会话数据与各 System
	- 玩家离开时清理连接并强制存档
	- 角色生成时的服务端外观/碰撞/Parent 编排
	- 挂机重连复位：若 JoinData.TeleportData.afkRestore 有效，等「人物加载完成」后 PivotTo 一次

	与相关模块的关系：
	- SystemSave：InitialPlayerData / PlayerLeaveSave
	- SystemBag：SetupPlayerBag / InitNewPlayerItemsIfNeeded
	- SystemBagToolbar：启动时 Init 注册拖拽 Remote
	- SystemSet / SystemShop / SystemRecord / SystemRedPoint / SystemBUFF / SystemEmail / SystemDailyAward / SystemOnlineAward / SystemUpdateLog
	- SystemSkill / SystemPlrAttr：由本脚本编排 Init；模块自身再校验 IsEnabled
	- AFKManager.server：挂机传送写入 TeleportData.afkRestore，本模块负责落地
	- Player 镜像 Instance.Name 一律 EnumMgr.PlayerInst；Attribute 一律 EnumMgr.PlayerAttr

	端侧 / 调用约束：
	- 本文件是 ServerScript（InitGame/Manager），不是 Utils 可 require 的模块；由服务器启动自动运行
	- 存档失败时中止后续 System / 角色绑定，不踢人（由 SystemSave 记录）
	- 挂机复位是入服一次性硬切 PivotTo，不是 CharacterMotion 电机；死后重生不再应用

	初始化顺序：
	1. 基础 Value 与传送监听 → 2. SystemSave 加载 → 3. 各 System Init → 4. 角色事件绑定 → 5. 挂机复位（可选）
]]

-- ========================================
-- 服务引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Players = Utils.Players
local CollectionService = Utils.CollectionService

-- ========================================
-- 模块引用
-- ========================================
local SystemSave = Utils.SystemSave
local SystemBag = Utils.SystemBag
local SystemBagToolbar = Utils.SystemBagToolbar
local SystemShop = Utils.SystemShop
local SystemRedPoint = Utils.SystemRedPoint
local SystemEmail = Utils.SystemEmail
local SystemUpdateLog = Utils.SystemUpdateLog
local SystemBUFF = Utils.SystemBUFF
local SystemSet = Utils.SystemSet
local SystemRecord = Utils.SystemRecord
local SystemDailyAward = Utils.SystemDailyAward
local SystemOnlineAward = Utils.SystemOnlineAward
local SystemGameConfig = Utils.SystemGameConfig
local SystemSkill = Utils.SystemSkill
local SystemPlrAttr = Utils.SystemPlrAttr

local HumanModule = Utils.HumanModule
local VisibleMgr = Utils.VisibleMgr
local EnumMgr = Utils.EnumMgr
local InsMgr = Utils.InsMgr
local Log = Utils.Log

local PlayerInst = EnumMgr.PlayerInst
local PlayerAttr = EnumMgr.PlayerAttr

-- ========================================
-- 常量定义
-- ========================================
local GROUP_ID: number = SystemGameConfig.GetValue({ "群组设置", "群组ID" })
local HAS_INIT_FLAG = 1
local NAME_TAG_DELAY_SEC = 1
local APPEARANCE_LOADED_DELAY_SEC = 0.1
local CHAR_CHILD_WAIT_SEC = 15
local CHARACTERS_FOLDER_NAME = "Characters"
local AFK_RESTORE_KEY = "afkRestore"
local AFK_RESTORE_WAIT_SEC = 60
local AFK_RESTORE_CF_KEYS = { "x", "y", "z", "r00", "r01", "r02", "r10", "r11", "r12", "r20", "r21", "r22" }

local CUSTOM_TORSO_ASSET_ID = 81467413594714
local CUSTOM_LEFT_ARM_ASSET_ID = 117849292432710
local CUSTOM_RIGHT_ARM_ASSET_ID = 80432799757663
local CUSTOM_LEFT_LEG_ASSET_ID = 82101608689794
local CUSTOM_RIGHT_LEG_ASSET_ID = 138781585387202

local NON_COLLIDE_PART_NAMES = { "Left Arm", "Right Arm", "Torso", "Left Leg", "Right Leg" }

-- ========================================
-- 私有变量
-- ========================================
local _playerConnections: { [number]: { RBXScriptConnection } } = {}
local _pendingAfkRestore: { [number]: CFrame } = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	记录玩家相关连接，便于离开时统一断开

	@param userId number - 玩家 UserId
	@param conn RBXScriptConnection - 待管理的连接
	@return nil
]]
local function _trackPlayerConnection(userId: number, conn: RBXScriptConnection)
	local list = _playerConnections[userId]
	if not list then
		list = {}
		_playerConnections[userId] = list
	end
	table.insert(list, conn)
end

--[[
	断开并清理指定玩家的全部已跟踪连接

	@param userId number - 玩家 UserId
	@return nil
]]
local function _clearPlayerConnections(userId: number)
	local list = _playerConnections[userId]
	if not list then
		return
	end

	for _, conn in list do
		conn:Disconnect()
	end
	_playerConnections[userId] = nil
end

--[[
	将 TeleportData 中的具名分量还原为 CFrame

	@param components { [string]: any }? - 期望含 x/y/z 与 r00..r22 的 number 字段；缺任一或非 table 则失败
	@return CFrame? - 合法则返回 CFrame，否则 nil
]]
local function _componentsToCFrame(components: { [string]: any }?): CFrame?
	if typeof(components) ~= "table" then
		return nil
	end

	local values: { number } = {}
	local source = components :: { [string]: any }
	for index, key in AFK_RESTORE_CF_KEYS do
		local value = source[key]
		if typeof(value) ~= "number" then
			return nil
		end
		values[index] = value
	end

	return CFrame.new(
		values[1],
		values[2],
		values[3],
		values[4],
		values[5],
		values[6],
		values[7],
		values[8],
		values[9],
		values[10],
		values[11],
		values[12]
	)
end

--[[
	从 JoinData.TeleportData 解析挂机复位位姿；仅同 Place 且分量合法时生效

	@param plr Player - 刚加入的玩家
	@return CFrame? - 待复位位姿；无载荷或不合法时为 nil
]]
local function _readAfkRestoreCFrame(plr: Player): CFrame?
	local joinData = plr:GetJoinData()
	local teleportData = joinData and joinData.TeleportData
	if typeof(teleportData) ~= "table" then
		return nil
	end

	local restore = (teleportData :: { [string]: any })[AFK_RESTORE_KEY]
	if typeof(restore) ~= "table" then
		return nil
	end

	local restoreTable = restore :: { [string]: any }
	if restoreTable.placeId ~= game.PlaceId then
		Log.warn("AFK 复位跳过，PlaceId 不匹配:", plr.Name, restoreTable.placeId, game.PlaceId)
		return nil
	end

	local cf = _componentsToCFrame(restoreTable.cf)
	if not cf then
		Log.warn("AFK 复位跳过，CFrame 载荷非法:", plr.Name)
		return nil
	end

	return cf
end

--[[
	登记并在「人物加载完成」后执行一次 PivotTo；仅首次角色，死后重生不再应用

	@param plr Player - 目标玩家
	@return nil
]]
local function _scheduleAfkRestoreIfNeeded(plr: Player)
	local restoreCf = _readAfkRestoreCFrame(plr)
	if not restoreCf then
		return
	end

	_pendingAfkRestore[plr.UserId] = restoreCf

	task.spawn(function()
		local marker = plr:WaitForChild(PlayerInst.AppearanceLoaded, AFK_RESTORE_WAIT_SEC)
		local pending = _pendingAfkRestore[plr.UserId]
		_pendingAfkRestore[plr.UserId] = nil

		if not marker or not pending then
			return
		end
		if not plr.Parent then
			return
		end

		local character = HumanModule.GetCharacter(plr)
		if not character or not character.Parent then
			Log.warn("AFK 复位失败，角色未就绪:", plr.Name)
			return
		end

		character:PivotTo(pending)
		Log.print("AFK 复位完成:", plr.Name)
	end)
end

--[[
	异步拉取并写入玩家群组身份

	@param plr Player - 玩家对象
	@return nil
]]
local function _fetchGroupRole(plr: Player)
	local groupToken: StringValue = InsMgr.GetIns(PlayerInst.GroupRole, "StringValue", plr)
	groupToken.Value = ""

	local succeed, token = pcall(function()
		return plr:GetRoleInGroupAsync(GROUP_ID)
	end)

	if not plr.Parent then
		return
	end

	if succeed and type(token) == "string" then
		groupToken.Value = token
	else
		Log.warn("GetRoleInGroupAsync failed:", plr.UserId, token)
	end
end

--[[
	初始化玩家基础 Attribute 与传送状态 Value

	@param plr Player - 玩家对象
	@return nil
]]
local function _initPlayerValue(plr: Player)
	plr:SetAttribute(PlayerAttr.Die, false)

	local isTeleport: BoolValue = InsMgr.GetIns(PlayerInst.Teleporting, "BoolValue", plr)
	isTeleport.Value = false
end

--[[
	绑定玩家传送状态监听

	@param plr Player - 玩家对象
	@return nil
]]
local function _bindTeleportListener(plr: Player)
	local conn = plr.OnTeleport:Connect(function(teleportState, _placeId, _spawnName)
		Log.print("传送状态:", plr.DisplayName, teleportState)
		if teleportState == Enum.TeleportState.RequestedFromServer then
			local isTeleport: BoolValue? = plr:FindFirstChild(PlayerInst.Teleporting) :: BoolValue?
			if isTeleport then
				isTeleport.Value = true
			end
		end
	end)
	_trackPlayerConnection(plr.UserId, conn)
end

--[[
	异步拉取玩家头像并挂到 Player 下

	@param plr Player - 玩家对象
	@return nil
]]
local function _spawnAvatarThumbnail(plr: Player)
	task.spawn(function()
		local avatar = Instance.new("ImageLabel")
		avatar.Name = PlayerInst.AvatarImage
		avatar.Parent = plr

		local succeed, avatarImage = pcall(function()
			return Players:GetUserThumbnailAsync(
				plr.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size60x60
			)
		end)

		if not plr.Parent then
			return
		end

		if succeed and type(avatarImage) == "string" then
			avatar.Image = avatarImage
		else
			Log.warn("GetUserThumbnailAsync failed:", plr.UserId, avatarImage)
		end
	end)
end

--[[
	战斗系统启用时同步会话属性到 Humanoid（SystemPlrAttr 内部再校验门控）

	@param plr Player - 目标玩家
	@return nil
]]
local function _tryInitPlrAttr(plr: Player)
	if SystemPlrAttr and SystemPlrAttr.InitPlr then
		SystemPlrAttr.InitPlr(plr)
	end
end

--[[
	技能系统启用时初始化玩家技能槽（SystemSkill.Init 内部再校验门控）

	@param plr Player - 目标玩家
	@return nil
]]
local function _tryInitPlayerSkill(plr: Player)
	if SystemSkill and SystemSkill.Init then
		SystemSkill.Init(plr)
	end
end

--[[
	加载玩家存档并初始化各 System（立即 + 延迟）

	@param plr Player - 玩家对象
	@return boolean - 存档加载是否成功
]]
local function _initPlayerDataAndSystems(plr: Player): boolean
	local loadOk, isNew = SystemSave.InitialPlayerData(plr)
	if not loadOk then
		Log.warn("InitialPlayerData failed:", plr.UserId)
		return false
	end

	local isNewPlayerValue: BoolValue = InsMgr.GetIns(PlayerInst.IsNewPlayer, "BoolValue", plr)
	isNewPlayerValue.Value = isNew

	SystemSet.Init(plr)
	SystemShop.InitValue(plr)
	SystemBag.SetupPlayerBag(plr)
	SystemBag.InitNewPlayerItemsIfNeeded(plr, isNew)

	SystemRecord.Init(plr)

	SystemRedPoint.Init(plr)
	SystemBUFF.Init(plr)
	SystemEmail.Init(plr)
	SystemUpdateLog.Init(plr)
	SystemDailyAward.Init(plr)
	SystemOnlineAward.Init(plr)

	_tryInitPlayerSkill(plr)
	_tryInitPlrAttr(plr)

	task.spawn(function()
		SystemShop.Init(plr)
	end)

	return true
end

--[[
	关闭 R6 肢体碰撞，避免卡入地形；部件缺失则跳过

	@param character Model - 刚加载的角色模型
	@return nil
]]
local function _disableLimbCollision(character: Model)
	for _, partName in NON_COLLIDE_PART_NAMES do
		local part = character:WaitForChild(partName, CHAR_CHILD_WAIT_SEC)
		if part and part:IsA("BasePart") then
			part.CanCollide = false
		end
	end
end

--[[
	拉取并套用自定义 R6 外观；失败只打日志

	@param plr Player - 目标玩家
	@param character Model - 刚加载的角色模型
	@param spawnHumanoid Humanoid - 角色 Humanoid
	@return nil
]]
local function _applyCustomAppearance(plr: Player, character: Model, spawnHumanoid: Humanoid)
	local desOk, des = pcall(function()
		return Players:GetHumanoidDescriptionFromUserIdAsync(plr.UserId)
	end)
	if not desOk or not des then
		Log.warn("GetHumanoidDescriptionFromUserIdAsync failed:", plr.UserId, des)
		return
	end
	if not character.Parent then
		return
	end

	des.Torso = CUSTOM_TORSO_ASSET_ID
	des.LeftArm = CUSTOM_LEFT_ARM_ASSET_ID
	des.RightArm = CUSTOM_RIGHT_ARM_ASSET_ID
	des.LeftLeg = CUSTOM_LEFT_LEG_ASSET_ID
	des.RightLeg = CUSTOM_RIGHT_LEG_ASSET_ID

	local applyOk, applyErr = pcall(function()
		spawnHumanoid:ApplyDescriptionAsync(des, Enum.AssetTypeVerification.Default)
	end)
	if not applyOk then
		Log.warn("ApplyDescriptionAsync failed:", plr.UserId, applyErr)
	end
end

--[[
	角色加载完成后的服务端初始化（碰撞、Parent、NameTag、自定义外观）

	@param plr Player - 目标玩家
	@param character Model - 刚加载的角色模型
	@return nil
]]
local function _setupCharacterOnSpawn(plr: Player, character: Model)
	local humanoid: Humanoid? = character:FindFirstChild("Humanoid") :: Humanoid?
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	-- 角色重生后同步会话战斗属性到 Humanoid（战斗系统启用时）
	_tryInitPlrAttr(plr)

	VisibleMgr.SetPlayerCollideID(character)

	task.spawn(function()
		task.wait(NAME_TAG_DELAY_SEC)
		if not character.Parent then
			return
		end

		local humanoidRootPart: Part? = character:WaitForChild("HumanoidRootPart", CHAR_CHILD_WAIT_SEC) :: Part?
		if humanoidRootPart then
			CollectionService:AddTag(humanoidRootPart, "NameTag")
		end

		local spawnHumanoid = character:WaitForChild("Humanoid", CHAR_CHILD_WAIT_SEC)
		if not spawnHumanoid or not spawnHumanoid:IsA("Humanoid") then
			Log.warn("ApplyDescription skip, Humanoid missing:", plr.UserId)
			return
		end

		_applyCustomAppearance(plr, character, spawnHumanoid)
	end)

	local charactersFolder = workspace:FindFirstChild(CHARACTERS_FOLDER_NAME)
	if charactersFolder then
		character.Parent = charactersFolder
	else
		Log.warn("Characters folder missing, skip reparent:", plr.Name)
	end

	_disableLimbCollision(character)
end

--[[
	绑定角色生成与外观加载完成事件

	@param plr Player - 玩家对象
	@return nil
]]
local function _bindCharacterEvents(plr: Player)
	local char: Model? = HumanModule.GetCharacter(plr)
	if char then
		_setupCharacterOnSpawn(plr, char)
	end

	local charAddedConn = plr.CharacterAdded:Connect(function(character: Model)
		_setupCharacterOnSpawn(plr, character)
	end)
	_trackPlayerConnection(plr.UserId, charAddedConn)

	if plr:HasAppearanceLoaded() then
		InsMgr.GetIns(PlayerInst.AppearanceLoaded, "NumberValue", plr)
	end

	local appearanceConn = plr.CharacterAppearanceLoaded:Connect(function(_character: Model)
		task.wait(APPEARANCE_LOADED_DELAY_SEC)
		if not plr.Parent then
			return
		end
		InsMgr.GetIns(PlayerInst.AppearanceLoaded, "NumberValue", plr)
		Log.print("人物加载完成")
	end)
	_trackPlayerConnection(plr.UserId, appearanceConn)
end

--[[
	玩家加入主流程：防重入后编排基础初始化、数据加载与角色事件

	@param plr Player - 玩家对象
	@return nil
]]
local function _handlePlayerAdded(plr: Player)
	_fetchGroupRole(plr)

	if plr:GetAttribute(PlayerAttr.HasInit) == HAS_INIT_FLAG then
		return
	end
	plr:SetAttribute(PlayerAttr.HasInit, HAS_INIT_FLAG)

	_clearPlayerConnections(plr.UserId)

	_initPlayerValue(plr)
	_bindTeleportListener(plr)

	local giftPlayer: ObjectValue = InsMgr.GetIns(PlayerInst.GiftPlayer, "ObjectValue", plr)
	giftPlayer.Value = nil

	_spawnAvatarThumbnail(plr)

	if not _initPlayerDataAndSystems(plr) then
		return
	end

	_bindCharacterEvents(plr)
	_scheduleAfkRestoreIfNeeded(plr)
end

-- ========================================
-- 事件监听
-- ========================================
SystemBagToolbar.Init()

for _, plr in Players:GetPlayers() do
	_handlePlayerAdded(plr)
end

Players.PlayerAdded:Connect(_handlePlayerAdded)

Players.PlayerRemoving:Connect(function(plr: Player)
	_pendingAfkRestore[plr.UserId] = nil
	_clearPlayerConnections(plr.UserId)

	local resetPlayer: BoolValue? = plr:FindFirstChild(PlayerInst.ResetPlayer) :: BoolValue?
	if resetPlayer and resetPlayer.Value then
		return
	end

	SystemSave.PlayerLeaveSave(plr)
end)

-- 服务端启动时播种一次，供后续随机逻辑使用；勿移入玩家加入路径以免重复播种
math.randomseed(os.time())
