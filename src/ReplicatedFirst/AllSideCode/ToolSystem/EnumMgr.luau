--[[
	Module: EnumMgr
	Description: 全项目共享枚举与错误码（元素、物品、坐骑、技能、灯光等）
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-09-01

	功能：
	- 提供 ItemType / BagShow / MountErr / SkillTp / SkillSlot / SkillFolder / SkillErr / PlayerInst / SkillReleaseReject / LightingApplyResult / ShopErr / DailyAwardErr / SetErr / BuyRobloxErr / CodeErr / UpdateLogErr / LogicalDriveMode 等常量
	- 与配置表列值、System 错误码第二返回值对齐

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local EnumMgr = Utils.EnumMgr
]]

local EnumMgr = {}

EnumMgr.ElementTp = {
	None = 0,   -- 无元素
	Wind = 1,   -- 风
	Fire = 2,   -- 火
	Water = 3,  -- 水
	Earth = 4,  -- 地
	Dark = 5,   -- 暗
	Light = 6,  -- 光
	Thunder = 7, -- 雷
	Ice = 8, -- 冰
	Poison = 9, -- 毒
	Space = 10, -- 空间
}

EnumMgr.DmgTp = {
	PlayerDmg = 1,
	PlayerDmgCrit = 2,
	NPCDmg = 3,
	NPCDmgCrit = 4,
	Heal = 5,
	HealCrit = 6,
	Bleed = 7,
	Poison = 8,
	Burn = 9,
}

EnumMgr.TipTp = {
	Normal = 1,
	Error = 2,
}

-- 相机震动类型（对应 CameraModule 多层 Trauma：Once / At / Impulse / 命名源 Sustain；1-8）
EnumMgr.CameraShakeType = {
	Attack = 1,
	Clash = 2,
	BigClash = 3,
	LongClash = 4,
	MagicHit = 5,
	Land = 6,
	Explosion = 7,
	Ambient = 8,
}

-- 相机模式名（与 CameraModule.Mode / LocalPlayer.CameraMode Attribute 一致）
EnumMgr.CameraMode = {
	Default = "Default",
	ShiftLock = "ShiftLock",
	OTS = "OTS",
	LockOn = "LockOn",
	Aim = "Aim",
}

-- 动作仲裁占用优先级（与 ActionArbiter.Priority 一致；数值越大越高）
EnumMgr.ActionClaimPriority = {
	Loco = 0,
	Flight = 40,
	FacingBridge = 55,
	Skill = 60,
	Knockback = 90,
	Cinematic = 100,
}

--特殊货币
EnumMgr.ItemID = {
	Coin = 1,
	Diamond = 2,
}

EnumMgr.ItemType = {
	Item = 0,--普通消耗物品
	UseItem = 1,--可使用物品
	Anime = 2,--动漫角色
	Title = 5,--称号（itemdataConf.tp）
	GamePass = 3,--通行证
	Pet = 4,--宠物
	Skill = 6,--技能（skillConf）
	PetEgg = 7,--宠物蛋
	Mount = 8,--坐骑/载具（mountConf）
}

--[[ itemdataConf.isShow / hasCount / isTrade；存档 Bag.lock 与配置列值对齐 ]]
EnumMgr.BagShow = {
	InBag = 1,
}

EnumMgr.BagStack = {
	Stackable = 1,
}

EnumMgr.BagLock = {
	Unlocked = 0,
	Locked = 1,
}

EnumMgr.BagTrade = {
	NotTradeable = 0,
}

--[[ 背包拖拽 zone（服客 Remote / overlay 共用） ]]
EnumMgr.BagDragZone = {
	Toolbar = "toolbar",
	Warehouse = "warehouse",
}

--[[ BAG_LOCK_ITEMS mode：全锁/全解锁由服扫包，不信客机 onlyID 全表 ]]
EnumMgr.BagLockMode = {
	LockAll = "lockAll",
	UnlockAll = "unlockAll",
}

--[[ mountConf.LocomotionType；决定客户端 MountLocomotion Driver ]]
EnumMgr.MountLocomotionType = {
	GroundMount = "GroundMount",
	WheeledVehicle = "WheeledVehicle",
	FlyingCreature = "FlyingCreature",
	Aircraft = "Aircraft",
}

--[[ 逻辑怪移动命令模式（LogicalMoveCommand / LogicalPathFollow 共用；写入 entity._driveMode）]]
EnumMgr.LogicalDriveMode = table.freeze({
	Auto = "Auto",
	ScriptGoal = "ScriptGoal",
	ScriptDir = "ScriptDir",
	Pause = "Pause",
})

--[[ GroundMount 物理主从：HumanoidHost=A（马焊人）；MountRoot=B（人上鞍、马为根）]]
EnumMgr.MountDriveMode = {
	HumanoidHost = "HumanoidHost",
	MountRoot = "MountRoot",
}

--[[ SystemMount 会话态（全项目唯一）]]
EnumMgr.MountSessionState = {
	Idle = "Idle",
	Summoning = "Summoning",
	Active = "Active",
	Exiting = "Exiting",
}

--[[ ForceExit / TryExit 原因 ]]
EnumMgr.MountForceExitReason = {
	PlayerRequest = "PlayerRequest",
	ZoneBan = "ZoneBan",
	CombatLock = "CombatLock",
	SkillConflict = "SkillConflict",
	CharacterMotionDrive = "CharacterMotionDrive",
	Dialogue = "Dialogue",
	Cutscene = "Cutscene",
	Seated = "Seated",
	Death = "Death",
	Respawn = "Respawn",
	LeaveGame = "LeaveGame",
	InvalidState = "InvalidState",
	AntiCheat = "AntiCheat",
}

--[[ mountConf.CombatPolicy ]]
EnumMgr.MountCombatPolicy = {
	Allow = "Allow",
	ForceExit = "ForceExit",
	DenyEnter = "DenyEnter",
}

--[[ SystemMount.TryEnter / TryExit 错误码（第二返回值）]]
EnumMgr.MountErr = {
	Ok = "",
	NotOwned = "NOT_OWNED",
	NotEquipped = "NOT_EQUIPPED",
	Cooldown = "COOLDOWN",
	ZoneDenied = "ZONE_DENIED",
	CombatDenied = "COMBAT_DENIED",
	AlreadyActive = "ALREADY_ACTIVE",
	NotActive = "NOT_ACTIVE",
	InvalidMountId = "INVALID_MOUNT_ID",
	InvalidState = "INVALID_STATE",
	SkillConflict = "SKILL_CONFLICT",
	MotionConflict = "MOTION_CONFLICT",
	RateLimited = "RATE_LIMITED",
	ConfigMissing = "CONFIG_MISSING",
}

--[[ skillConf.isBase：冲刺 / 普攻 / 主动技能 ]]
EnumMgr.SkillTp = {
	Roll = 0, -- 冲刺
	Base = 1, -- 基础技能（普攻）
	Skill = 2, -- 主动技能
}

--[[ 玩家技能运行时槽位（与 SystemSkill / SystemPlayerSkill 一致） ]]
EnumMgr.SkillSlot = {
	Active1 = 1,
	Active2 = 2,
	Dash = 3,
	NormalAttack = 4,
	Block = 5,
	MaxRuntime = 5,
}

--[[ 服 SystemPlayerSkill 拒释 reason（SkillNet + FireRubberband） ]]
EnumMgr.SkillReleaseReject = {
	Dead = "DEAD",
	MountActive = "MOUNT_ACTIVE",
	InterruptionPriority = "INTERRUPTION_PRIORITY",
	Flying = "FLYING",
}

--[[ 玩家会话技能镜像 Folder / NumberValue 名（与 SystemSkill 写入的 Instance.Name 对齐，勿改语义） ]]
EnumMgr.SkillFolder = {
	Name = "技能相关",
	CooldownName = "技能CD时间戳",
	Skill1 = "Skill1",
	Skill2 = "Skill2",
	SkillPrefix = "Skill",
	Dash = "Dash",
	NormalAtk = "NormalAtk",
	Block = "Block",
	SlotPrefix = "Slot",
}

--[[ SystemSkill.EquipSkill / UnequipSkill 失败时的第二返回值 ]]
EnumMgr.SkillErr = {
	InvalidPlayer = "INVALID_PLAYER",
	InvalidParam = "INVALID_PARAM",
	Disabled = "DISABLED",
	DashDisabled = "DASH_DISABLED",
	ConfigNotFound = "CONFIG_NOT_FOUND",
	NoData = "NO_DATA",
	InvalidSlot = "INVALID_SLOT",
	SaveFailed = "SAVE_FAILED",
}

--[[ skillConf.EffectTarget ]]
EnumMgr.SkillEffectTarget = {
	Enemy = 1,
	Ally = 2,
	Self = 3,
}

--[[ 玩家战斗属性键（会话 Folder「战斗属性」；GetData.GetPlrAttr 可读） ]]
EnumMgr.PlrAttr = {
	HP = "HP",
	Atk = "Atk",
	Atk_P = "Atk_P",
	Crit_Rate = "Crit_Rate",
	Crit_Dmg = "Crit_Dmg",
	Dmg_Bonus = "Dmg_Bonus",
	Dmg_Reduction = "Dmg_Reduction",
	Ele = "Ele",
	Skill_CDR = "Skill_CDR",
	Skill_Haste = "Skill_Haste",
}

--[[ Player 上由 System/Manager 写入的镜像 Instance.Name（客户端只读；改名须同步所有读写方） ]]
EnumMgr.PlayerInst = {
	BuffFolder = "BUFF",
	RoomId = "当前房间号",
	GamePassFolder = "GamePass",
	RecordFolder = "Record",
	RedPointFolder = "RedPoint",
	SettingFolder = "Setting",
	GiftPlayer = "GiftPlayer",
	GroupRole = "群组身份",
	Teleporting = "正在传送",
	IsNewPlayer = "IsNewPlayer",
	AppearanceLoaded = "人物加载完成",
	ResetPlayer = "ResetPlayer",
	AvatarImage = "avatarImage",
}

--[[ Player Attribute 名（与 Instance.Name 分开，避免混用） ]]
EnumMgr.PlayerAttr = {
	Die = "Die",
	HasInit = "HasInit",
}

--[[ settingConf.TempType，与配置表 TempType 列一致 ]]
EnumMgr.SettingTempType = {
	Slider = 1,
	Toggle = 2,
	Choose = 3,
	Input = 4,
}

EnumMgr.Rare = {
	Xyd1 = 1,
	Xyd2 = 2,
	Xyd3 = 3,
	Xyd4 = 4,
	Xyd5 = 5,
}
setmetatable(EnumMgr.Rare,{
	__index = {
		[1] = "稀有",
		[2] = "史诗",
		[3] = "传说",
		[4] = "神秘",
		[5] = "永恒",
	}
})

--付费类型 pass item
EnumMgr.RobuxType = {
	RobuxItem = 1,
	GamePass = 2,
}

EnumMgr.DebugTp = {
	Mail = 1,	--可以使用邮件
	Debug = 2,	--可以使用Debug
	Buff = 3,	--可以设置服务器Buff
	All = 99,	--可以使用所有
}

--[[ DEBUG_BAG msgData.msgType ]]
EnumMgr.DebugBagOp = {
	Add = 1,
	Remove = 2,
	Clear = 3,
}

--[[ DEBUG_SPECIAL 第二参 operationType ]]
EnumMgr.DebugSpecialOp = {
	CoverRecord = "修改记录",
	AddOnlineSeconds = "增加在线时长",
	ResetOnlineAward = "重置在线奖励",
}

--[[ GM 发邮件 RemoteFunction 操作名（DEBUG_EMAIL 第二参）]]
EnumMgr.GmEmailOp = {
	Send = "发送邮件",
}

--[[ GivePlrEmail 写入成功后的第二返回值：在线入包未完成（会补发）/ 同步标记回滚失败（不会自动补发） ]]
EnumMgr.GmEmailErr = {
	QueuedGrantFailed = "QUEUED_GRANT_FAILED",
	SyncRevertFailed = "SYNC_REVERT_FAILED",
	NotWhitelisted = "NOT_WHITELISTED",
	UnknownOperation = "UNKNOWN_OPERATION",
	InvalidEmailData = "INVALID_EMAIL_DATA",
	SendFailed = "SEND_FAILED",
	InvalidPlayer = "INVALID_PLAYER",
	RateLimit = "RATE_LIMIT",
}

--[[ SystemShop 修改类 API 失败时的第二返回值 ]]
EnumMgr.ShopErr = {
	InvalidParam = "INVALID_PARAM",
	ConfigNotFound = "CONFIG_NOT_FOUND",
	NoData = "NO_DATA",
	NotFound = "NOT_FOUND",
	GrantFailed = "GRANT_FAILED",
	SaveFailed = "SAVE_FAILED",
}

--[[ SystemDailyAward.GetDailyAward 失败时的第二返回值 ]]
EnumMgr.DailyAwardErr = {
	InvalidPlayer = "INVALID_PLAYER",
	NoData = "NO_DATA",
	OnCooldown = "ON_COOLDOWN",
	Finished = "FINISHED",
	Busy = "BUSY",
	ConfigNotFound = "CONFIG_NOT_FOUND",
	InvalidReward = "INVALID_REWARD",
	GrantFailed = "GRANT_FAILED",
	SaveFailed = "SAVE_FAILED",
}

--[[ SystemSet.ChangeSet 失败时的第二返回值 ]]
EnumMgr.SetErr = {
	InvalidPlayer = "INVALID_PLAYER",
	InvalidName = "INVALID_NAME",
	InvalidValue = "INVALID_VALUE",
	NoData = "NO_DATA",
	SaveFailed = "SAVE_FAILED",
}

--[[ SystemBuyRoblox 修改类 API 失败时的第二返回值 ]]
EnumMgr.BuyRobloxErr = {
	InvalidParam = "INVALID_PARAM",
	ConfigNotFound = "CONFIG_NOT_FOUND",
	GrantFailed = "GRANT_FAILED",
	SaveFailed = "SAVE_FAILED",
	GiftTargetInvalid = "GIFT_TARGET_INVALID",
	TargetOffline = "TARGET_OFFLINE",
}

--[[ SystemCode.RedeemCode 失败时的第二返回值 ]]
EnumMgr.CodeErr = {
	InvalidPlayer = "INVALID_PLAYER",
	InvalidCode = "INVALID_CODE",
	OrdinaryNotImplemented = "ORDINARY_NOT_IMPLEMENTED",
	RedeemFailed = "REDEEM_FAILED",
	GrantFailed = "GRANT_FAILED",
}

--[[ SystemUpdateLog.ReadUpdateLog 失败时的第二返回值 ]]
EnumMgr.UpdateLogErr = {
	InvalidPlayer = "INVALID_PLAYER",
	InvalidId = "INVALID_ID",
	UnknownId = "UNKNOWN_ID",
	AlreadyRead = "ALREADY_READ",
	SaveFailed = "SAVE_FAILED",
}

--[[ SystemLightingCustomState 状态名（与 Assets.LightingStates 下 Instance.Name 一致）]]
EnumMgr.LightingCustomState = {
	UiBlur = "用户界面模糊背景",
	NpcDialogBlur = "NPC对话背景模糊",
}

--[[ LightingManager 天气写者优先级；lease 取最大 priority，平局取后 Acquire ]]
EnumMgr.WeatherWriterPriority = {
	Baseline = 0,
	Skill = 100,
	Dungeon = 200,
}

--[[
	Weather lease 默认 TTL（秒）。
	- Skill：120；Dungeon：0 表示永不过期；其它合法 priority：60。
	- Acquire 入参 ttl：nil 用本表；0=永不过期；>0=秒数。
]]
EnumMgr.WeatherLeaseDefaultTtl = {
	Skill = 120,
	Dungeon = 0,
	Other = 60,
}

--[[ Weather lease TTL 到期自动释放时的过渡秒数 ]]
EnumMgr.WeatherLeaseExpireTransitionSec = 0.5

--[[
	无 expiresAt 的 lease（如 Dungeon 默认永不过期）存活超过本秒数后写 LightingStaleLeaseWriters 并 Log.warn。
	副本退出仍须 FORCE_CLEAR / RELEASE；本阈值仅告警。
]]
EnumMgr.WeatherLeaseStaleWarnSec = 600

--[[
	无 expiresAt 的 lease 存活硬上限（秒）：达到后自动释放（容灾兜底）。
	0 = 关闭硬上限（仅依赖业务 RELEASE / FORCE_CLEAR + StaleWarn）。
	建议 >= WeatherLeaseStaleWarnSec，使先告警再强制清。
]]
EnumMgr.WeatherLeaseHardMaxSec = 1800

--[[ 同 writer 连续 force ACQUIRE 的最小间隔（秒）；过密则降级为非 force，仍更新 lease ]]
EnumMgr.WeatherAcquireForceMinIntervalSec = 0.05

--[[ 同时持有的 Weather lease 上限；新 writer 超限则 Acquire 拒绝（同 writer 刷新不占新槽）]]
EnumMgr.WeatherMaxActiveLeases = 16

--[[ 客户端图像质量设置值（与 ConfigInstance GraphicsQuality 一致：0 低 / 1 高）]]
EnumMgr.LightingGraphicsQuality = {
	Low = 0,
	High = 1,
}

--[[ 低画质时跳过的天气通道 ClassName（Cloud 仍 apply，仅关微动）]]
EnumMgr.LightingQualityLowSkipClass = {
	BloomEffect = true,
	DepthOfFieldEffect = true,
	SunRaysEffect = true,
}

--[[
	SystemLighting.applyEffectFromInstance / 通道 hide 结果码。
	- Ok：已写 Instance / 已 hide / 已启动 Tween
	- UnknownClass / InvalidArg：参数或类型无效
	- QualitySkip：低画质跳过（已 hide 或未 apply）
	- FxBusy：FXUtilCcBusy 占用，跳过写 Instance 或 hide（逻辑字段可能已更新）
	- ChannelError：通道 apply/hide 抛错（pcall 捕获）
]]
EnumMgr.LightingApplyResult = {
	Ok = "Ok",
	UnknownClass = "UnknownClass",
	QualitySkip = "QualitySkip",
	FxBusy = "FxBusy",
	InvalidArg = "InvalidArg",
	ChannelError = "ChannelError",
}

--[[ settingConf.SetType；SettingCategory[n] 为分类标题（与 settingConf 表内 SetType 数值一致）]]
EnumMgr.SettingCategory = {
	Special = 1,
	Sound = 2,
	Display = 3,
	Control = 4,
	Other = 5,
}

setmetatable(EnumMgr.SettingCategory, {
	__index = {
		[1] = "特殊功能",
		[2] = "声音",
		[3] = "显示",
		[4] = "控制",
		[5] = "其他",
	},
})

return EnumMgr
