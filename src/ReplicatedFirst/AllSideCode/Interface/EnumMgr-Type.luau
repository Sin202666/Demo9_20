local module = {}

-- EnumMgr 是一个枚举管理器，包含多个枚举表
-- 注意：这是一个配置表模块，不是函数模块

module.TipTp = {
	Normal = 1,
	Error = 2,
}

module.CameraShakeType = {
	Attack = 1,
	Clash = 2,
	BigClash = 3,
	LongClash = 4,
	MagicHit = 5,
	Land = 6,
	Explosion = 7,
	Ambient = 8,
}

module.CameraMode = {
	Default = "Default",
	ShiftLock = "ShiftLock",
	OTS = "OTS",
	LockOn = "LockOn",
	Aim = "Aim",
}

module.ActionClaimPriority = {
	Loco = 0,
	Flight = 40,
	FacingBridge = 55,
	Skill = 60,
	Roll = 70,
	Knockback = 90,
	Cinematic = 100,
}

-- 特殊货币枚举
module.ItemID = {
	Coin = 1,
	Diamond = 2,
}

-- 物品类型枚举
module.ItemType = {
	Item = 0,		--普通消耗物品
	UseItem = 1,	--可使用物品
	GamePass = 3,	--通行证
	Pet = 4,		--宠物
	PetEgg = 7,		--宠物蛋
	Mount = 8,		--坐骑/载具
}

module.BagShow = {
	InBag = 1,
}

module.BagStack = {
	Stackable = 1,
}

module.BagLock = {
	Unlocked = 0,
	Locked = 1,
}

module.BagTrade = {
	NotTradeable = 0,
}

module.BagDragZone = {
	Toolbar = "toolbar",
	Warehouse = "warehouse",
}

module.BagLockMode = {
	LockAll = "lockAll",
	UnlockAll = "unlockAll",
}

module.MountLocomotionType = {
	GroundMount = "GroundMount",
	WheeledVehicle = "WheeledVehicle",
	FlyingCreature = "FlyingCreature",
	Aircraft = "Aircraft",
}

module.MountDriveMode = {
	HumanoidHost = "HumanoidHost",
	MountRoot = "MountRoot",
}

module.MountSessionState = {
	Idle = "Idle",
	Summoning = "Summoning",
	Active = "Active",
	Exiting = "Exiting",
}

module.MountForceExitReason = {
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

module.MountCombatPolicy = {
	Allow = "Allow",
	ForceExit = "ForceExit",
	DenyEnter = "DenyEnter",
}

module.MountErr = {
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

module.SkillSlot = {
	Active1 = 1,
	Active2 = 2,
	Dash = 3,
	NormalAttack = 4,
	Block = 5,
	MaxRuntime = 5,
}

module.SkillReleaseReject = {
	Dead = "DEAD",
	MountActive = "MOUNT_ACTIVE",
	InterruptionPriority = "INTERRUPTION_PRIORITY",
	Flying = "FLYING",
}

module.SkillFolder = {
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

-- SystemSkill.EquipSkill / UnequipSkill 失败时的第二返回值
module.SkillErr = {
	InvalidPlayer = "INVALID_PLAYER",
	InvalidParam = "INVALID_PARAM",
	Disabled = "DISABLED",
	DashDisabled = "DASH_DISABLED",
	ConfigNotFound = "CONFIG_NOT_FOUND",
	NoData = "NO_DATA",
	InvalidSlot = "INVALID_SLOT",
	SaveFailed = "SAVE_FAILED",
}

module.PlayerInst = {
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

module.PlayerAttr = {
	Die = "Die",
	HasInit = "HasInit",
}

-- 稀有度枚举
module.Rare = {
	Xyd1 = 1,
	Xyd2 = 2,
	Xyd3 = 3,
	Xyd4 = 4,
	Xyd5 = 5,
}

-- 付费类型枚举
module.RobuxType = {
	RobuxItem = 1,
	GamePass = 2,
}

-- 调试类型枚举
module.DebugTp = {
	Mail = 1,   -- 可以使用邮件
	Debug = 2,  -- 可以使用Debug
	Buff = 3,   -- 可以设置服务器Buff
	All = 99,   -- 可以使用所有
}

-- DEBUG_BAG msgData.msgType
module.DebugBagOp = {
	Add = 1,
	Remove = 2,
	Clear = 3,
}

-- DEBUG_SPECIAL 第二参 operationType
module.DebugSpecialOp = {
	CoverRecord = "修改记录",
	AddOnlineSeconds = "增加在线时长",
	ResetOnlineAward = "重置在线奖励",
}

-- GM 发邮件 RemoteFunction 操作名（DEBUG_EMAIL 第二参）
module.GmEmailOp = {
	Send = "发送邮件",
}

-- GivePlrEmail 写入成功后的第二返回值；DEBUG_EMAIL 失败码
module.GmEmailErr = {
	QueuedGrantFailed = "QUEUED_GRANT_FAILED",
	SyncRevertFailed = "SYNC_REVERT_FAILED",
	NotWhitelisted = "NOT_WHITELISTED",
	UnknownOperation = "UNKNOWN_OPERATION",
	InvalidEmailData = "INVALID_EMAIL_DATA",
	SendFailed = "SEND_FAILED",
	InvalidPlayer = "INVALID_PLAYER",
	RateLimit = "RATE_LIMIT",
}

-- SystemShop 修改类 API 失败时的第二返回值
module.ShopErr = {
	InvalidParam = "INVALID_PARAM",
	ConfigNotFound = "CONFIG_NOT_FOUND",
	NoData = "NO_DATA",
	NotFound = "NOT_FOUND",
	GrantFailed = "GRANT_FAILED",
	SaveFailed = "SAVE_FAILED",
}

-- SystemDailyAward.GetDailyAward 失败时的第二返回值
module.DailyAwardErr = {
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

-- SystemSet.ChangeSet 失败时的第二返回值
module.SetErr = {
	InvalidPlayer = "INVALID_PLAYER",
	InvalidName = "INVALID_NAME",
	InvalidValue = "INVALID_VALUE",
	NoData = "NO_DATA",
	SaveFailed = "SAVE_FAILED",
}

-- SystemBuyRoblox 修改类 API 失败时的第二返回值
module.BuyRobloxErr = {
	InvalidParam = "INVALID_PARAM",
	ConfigNotFound = "CONFIG_NOT_FOUND",
	GrantFailed = "GRANT_FAILED",
	SaveFailed = "SAVE_FAILED",
	GiftTargetInvalid = "GIFT_TARGET_INVALID",
	TargetOffline = "TARGET_OFFLINE",
}

-- SystemCode.RedeemCode 失败时的第二返回值
module.CodeErr = {
	InvalidPlayer = "INVALID_PLAYER",
	InvalidCode = "INVALID_CODE",
	OrdinaryNotImplemented = "ORDINARY_NOT_IMPLEMENTED",
	RedeemFailed = "REDEEM_FAILED",
	GrantFailed = "GRANT_FAILED",
}

-- SystemUpdateLog.ReadUpdateLog 失败时的第二返回值
module.UpdateLogErr = {
	InvalidPlayer = "INVALID_PLAYER",
	InvalidId = "INVALID_ID",
	UnknownId = "UNKNOWN_ID",
	AlreadyRead = "ALREADY_READ",
	SaveFailed = "SAVE_FAILED",
}

-- SystemLightingCustomState 状态名（与 Assets.LightingStates Instance.Name 一致）
module.LightingCustomState = {
	UiBlur = "用户界面模糊背景",
	NpcDialogBlur = "NPC对话背景模糊",
}

-- LightingManager 天气写者优先级
module.WeatherWriterPriority = {
	Baseline = 0,
	Skill = 100,
	Dungeon = 200,
}

-- Weather lease 默认 TTL（秒）；Dungeon=0 永不过期
module.WeatherLeaseDefaultTtl = {
	Skill = 120,
	Dungeon = 0,
	Other = 60,
}

-- Weather lease TTL 到期自动释放时的过渡秒数
module.WeatherLeaseExpireTransitionSec = 0.5

-- 无 expiresAt 的 lease 存活告警阈值（秒）；先告警
module.WeatherLeaseStaleWarnSec = 600

-- 无 expiresAt 的 lease 存活硬上限（秒）；达到后自动释放；0=关闭
module.WeatherLeaseHardMaxSec = 1800

-- 同 writer 连续 force ACQUIRE 的最小间隔（秒）
module.WeatherAcquireForceMinIntervalSec = 0.05

-- 同时持有的 Weather lease 上限；新 writer 超限则 Acquire 拒绝
module.WeatherMaxActiveLeases = 16

-- 客户端图像质量（与 ConfigInstance GraphicsQuality：0 低 / 1 高）
module.LightingGraphicsQuality = {
	Low = 0,
	High = 1,
}

-- 低画质跳过的天气通道 ClassName（Cloud 仍 apply，仅关微动）
module.LightingQualityLowSkipClass = {
	BloomEffect = true,
	DepthOfFieldEffect = true,
	SunRaysEffect = true,
}

-- SystemLighting.applyEffectFromInstance 结果码
module.LightingApplyResult = {
	Ok = "Ok",
	UnknownClass = "UnknownClass",
	QualitySkip = "QualitySkip",
	FxBusy = "FxBusy",
	InvalidArg = "InvalidArg",
	ChannelError = "ChannelError",
}

return module
