--[[
	Module: GameConfig
	Description: 策划/程序共用的静态全局配置（开关、阈值、默认键位）；运行时只读
	Author: 林奥宇
	Created: 2026-07-01
	Last Modified: 2026-09-04

	功能：
	- 版本号、DataStore 名、角色移速 / Control / 脚步 / BGM / 设置
	- 时钟、光照缓动、相机、HeadTrack、技能 / 怪物 / 战斗 / 坐骑等子系统开关与缺省值
	- 每日签到 / 在线奖励 / 背包UI 功能开关（关入口与对应结算；背包UI 不关库存）
	- 加载后深度 freeze，禁止运行时改写

	与相关模块的关系：
	- 业务优先走 SystemGameConfig.Get / GetValue（深拷贝或按路径取值）
	- 少数热路径可 Utils.GameConfig 直读；不要写回本表
	- 导表数据在 ConfigInstance / CfgFind，不在本模块

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local GameConfig = Utils.GameConfig
		local SystemGameConfig = Utils.SystemGameConfig

	使用示例：
		local walkSpeed = GameConfig.CharacterMoveSpeed["玩家行走移动速度"]
		local skillOn = SystemGameConfig.GetValue({ "技能系统", "启用" })
		local bagUiOn = SystemGameConfig.GetValue({ "背包UI", "启用" })
]]

local GameConfig = {}

--[[
	递归冻结表及其嵌套表（已冻结则跳过）
	@param value any - 任意值；非 table 直接返回
	@return any - 冻结后的同一引用，或原非 table 值
]]
local function _deepFreeze(value: any): any
	if type(value) ~= "table" then
		return value
	end
	if table.isfrozen(value) then
		return value
	end
	for _, v in pairs(value) do
		_deepFreeze(v)
	end
	return table.freeze(value)
end

-- ============================================================================
-- 框架运行时配置（原 ReplicatedFirst「游戏全局配置」Instance 文件夹）
-- ============================================================================

GameConfig["版本号"] = "1.0.0"
GameConfig.DataStore = "Data"

GameConfig.CharacterMoveSpeed = {
	["玩家行走移动速度"] = 16,
	["玩家奔跑移动速度"] = 22,
}

-- 角色 Control（Intent / LockMask / Sprint Toggle|Hold / Jump / Look·Interact / Transfer）
-- 「冲刺键」= Locomotion 奔跑（默认 LeftShift）；与技能「冲刺」NewRoll（Q）无关
-- 一键切换/长按奔跑：settingConf.RunMode（默认 0=一键切换）；本表不覆盖
-- 「ShiftLock键」= 视角锁定开关（默认 LeftControl），避免与奔跑抢 LeftShift
-- 「交互键」= Intent.interactPressed（默认 E；手柄 ButtonX）
GameConfig.CharacterControl = {
	["启用"] = true,
	["进场默认奔跑"] = false, -- true：进场即 Run（Toggle=初值闩 / Hold=直至首次松键）；false：默认走
	["冲刺键"] = "LeftShift",
	["ShiftLock键"] = "LeftControl", -- 写入 PlayerModule MouseLockController.BoundKeys
	["交互键"] = "E", -- Intent.interactPressed；手柄默认 ButtonX（Constants）
	["跳跃缓冲秒"] = 0.12,
	["郊狼秒"] = 0.08,
	["默认落地禁跳秒"] = 0, -- 0=不自动禁跳；技能自行 SuppressJump / PushLock
	-- Move 锁：SpeedOnly=仅 CMS 冻速；DisableControls=冻速+关默认 Controls（可被 mask.MovePolicy 覆盖）
	["Move锁默认策略"] = "SpeedOnly", -- PushLock({ Move=true }) 缺省
	["Transfer移控策略"] = "DisableControls", -- TransferControlOwner 缺省
}

GameConfig.FootStep = {
	["启用"] = true,
	-- true：本地脚步优先 Animate Marker；FootStepManager 在 AnimFootStepAt 抑制窗内跳过速度计步（无 Marker 仍兜底）
	["动画Marker驱动"] = true,
}

GameConfig.Bgm = {
	["启用"] = true,
	["默认BGM"] = "BGM1",
	["区域标签"] = "BGMArea",
	["区域BGM属性"] = "BGM",
	["淡入淡出秒"] = 2,
	["检测间隔秒"] = 0.5,
	["区域边界容差"] = 0.001,
}

GameConfig.Setting = {
	["启用"] = true,
	["音量渐变秒"] = 0.5,
}

-- 昼夜时钟（ClockManager）：启用=false 时不创建 ClockAuthority/TimeSlot/LightingBaseline
-- 时间流动=false 时仍设置初始权威时刻与时间段，但不推进 ClockAuthority
-- 权威逻辑时刻走 Lighting.ClockAuthority；视觉 Lighting.ClockTime 由客户端写入
GameConfig.Clock = {
	["启用"] = false,
	["时间流动"] = false,
	["初始时钟时间"] = 12, -- 权威逻辑时刻 0–24（ClockAuthority），非服端直写 ClockTime
	["一天秒数"] = 3600, -- 现实多少秒对应游戏内一天
	["更新间隔秒"] = 0.2,
	["光照切换秒"] = 5, -- 客户端按 LightingBaseline 切换天气时的过渡秒数
	["白天天气名"] = "Day", -- 逻辑段 Day 对应的 LightingConfig 名
	-- 进入 Night 时服务端从中随机选一写入 LightingBaseline（全端一致）
	["夜晚天气变体"] = { "Night_1", "Night_2" },
	-- 时间段：半开区间 [Min, Max)；Max=24 表示至日界（归一化后 24→0 由 [0,6) 覆盖）
	-- 默认：Day=[6,18)，Night=[0,6)∪[18,24)；边界 6→Day、18→Night，避免双命中
	["时间段"] = {
		["Day"] = {
			{ Min = 6, Max = 18 },
		},
		["Night"] = {
			{ Min = 0, Max = 6 },
			{ Min = 18, Max = 24 },
		},
	},
}

-- SystemLighting 过渡缓动（LightingTweenUtil；值为 Enum.EasingStyle / EasingDirection 名）
GameConfig.LightingTween = {
	["缓动样式"] = "Quad",
	["缓动方向"] = "Out",
}

GameConfig.SmartBone = {
	["启用"] = false,
}

-- NPC 头部跟踪（HeadTrack.client）：启用=false 时不监听标签、不跑 Heartbeat
GameConfig.HeadTrack = {
	["启用"] = true,
	["跟踪半径"] = 15, -- studs；玩家 HRP 与 NPC HRP 距离上限
	["视野点积阈值"] = 0.55, -- 躯干水平 Look · 指向玩家，约 56° 半角
	["转向平滑频率"] = 2, -- 一阶指数平滑 Hz；越大跟上越快
	["骨架等待秒"] = 10,
	["骨架轮询秒"] = 0.1,
}

GameConfig.CameraModule = {
	["默认视野角度"] = 60,
	["过场FOV过渡秒"] = 0.15, -- 主事件栈空归还后 FOV 短过渡；0=立即切到目标
	["震动最大位移"] = 3, -- studs，合成后硬限幅
	["震动最大转角"] = 18, -- 度，合成后硬限幅
	["Trauma衰减每秒"] = 1.2,
	["Trauma上升秒"] = 0.05, -- Once/At/Impulse 缺省 Attack 上升；0=瞬时满幅
	["噪声频率"] = 12, -- 层 roughness 缺省回退
	["降频下限"] = 0.2, -- 衰减时 roughness 乘 trauma 的下限，避免尾音完全停频
	-- 以下为叠在预设 pos/rotInfluence 上的全局乘子（1=不缩放）
	["位置影响X"] = 1,
	["位置影响Y"] = 1,
	["位置影响Z"] = 1,
	["旋转影响X"] = 1,
	["旋转影响Y"] = 1,
	["旋转影响Z"] = 1,
	["Impulse位移系数"] = 0.8,
	["Impulse转角系数"] = 4,
	-- Kick 弹簧：冲击写入速度，刚度/阻尼积分回零（不再用假指数衰减）
	["Impulse弹簧刚度"] = 180,
	["Impulse弹簧阻尼"] = 22,
	["Impulse冲量系数"] = 12, -- 速度冲量 = 位移/转角系数 × 强度 × 本系数
	["PlayAt默认最大距离"] = 80,
	["PlayAt最小满幅距离"] = 0,
	["PlayAt方向Kick系数"] = 0.65, -- At 自动方向 Kick 相对 trauma 的幅度；0=关闭默认 Kick 强度
	-- CameraMode 基线 Helper（OTS/LockOn/Aim；Default/ShiftLock 不注册）
	["OTS肩偏移X"] = 1.5,
	["OTS肩偏移Y"] = 0.35,
	["OTS肩偏移Z"] = 0.5,
	["LockOn肩偏移系数"] = 0.6, -- 相对 OTS 肩偏移比例
	["Aim视野增量"] = -8, -- Aim 模式 FOV 增量（负=拉近）
}

GameConfig["群组设置"] = {
	["群组ID"] = 0,
}

-- 「启用」= false：不建顶栏入口、不打开 DailyReward、不跑领取 / 红点 / 30 秒检测；Remote 仍注册但拒绝
GameConfig["每日签到"] = {
	["启用"] = true,
	["每日奖励领取间隔"] = 24, -- 单位：小时
	["每日签到最大天数"] = 7,
	["每日签到最大多少轮次"] = 3,
}

-- 「启用」= false：不建顶栏入口、不打开 OnlineAward、不计时 / 不领取 / 不付费 Unlock；Remote 仍注册但拒绝
GameConfig["在线奖励"] = {
	["启用"] = true,
}

GameConfig.AFK = {
	["挂机超时秒"] = 60 * 18,
	["空闲重置秒"] = 60,
	["挂机重连复位"] = false, -- true：挂机重连后回到重连前位置与朝向；死亡态不复位
}

GameConfig.Feedback = {
	["Webhook网址"] = "https://discord.com/api/webhooks/1430850397269917767/uDshDWpFgGS3-_fg-GvmuePmkR_f3CpQwJ2VeISbNPlYvN40UnBrx2Zbr8sruUXdSMC_", -- Discord Webhook 完整 URL；留空则反馈无法投递
	["反馈CD分钟"] = 5, -- 两次反馈最小间隔（分钟）
}

-- ============================================================================
-- 技能系统（玩家槽位 / 默认冲刺等）
-- 「启用」= false：不跑 SystemSkill.Init / PlayerSkillManager / PlayerSkillClientManager
-- 「启用冲刺技能」= false：不绑定冲刺槽、不监听冲刺键（仍依赖「启用」）
-- ============================================================================

GameConfig["技能系统"] = {
	["启用"] = true,
	["启用冲刺技能"] = true,
	["玩家可掌握技能数"] = 2,
	["玩家可掌握普攻数"] = 1,
	["默认普攻技能ID"] = 0,
	["默认冲刺技能ID"] = 10000002, -- NewRoll
	["默认格挡技能ID"] = 0,
	["默认主动技能1ID"] = 10000011, -- Meteor（含 Hitbox 主动样板；无 Hitbox 见 SkillDemoCast=10000010）；快捷键 e
	["默认主动技能2ID"] = 10000012, -- SpaceSkill（空间技能纯表现）；快捷键 r
	["默认瞄准距离上限"] = 80, -- skillConf.Range<=0 时 targetCF 钳制距离
	["技能默认快捷键"] = {
		[1] = "e",
		[2] = "r",
	},
	["冲刺快捷键"] = "q",
}

GameConfig["自动索敌"] = {
	["启用"] = false,
}

-- ============================================================================
-- 怪物系统（逻辑怪权威 / EnemySim / LocalMonster 表现）
-- 「启用」= false：不 Init SystemEnemy/EnemySim、不刷逻辑怪、客 EnemyManager 不注册
-- ============================================================================

GameConfig["怪物系统"] = {
	["启用"] = true,
	-- 逻辑怪地面移动：连续无效步进达到此帧数后侧向改向（LogicEntityMotion M0）
	["卡住帧数"] = 30,
	-- M2 路点寻路（PathfindingService）；false 时全员直线 + M0 滑移
	["寻路启用"] = true,
	["寻路每帧计算数"] = 3, -- EnemySim 循环后 flush 的 ComputeAsync 上限（钳制 0～8）
	-- >0：中心射线无挡则跳过 Path（默认 12 表示开着，不是「超过就强制 Path」）；≤0 关闭启发式
	["直线可达跳过寻路距离"] = 12,
}

GameConfig["可破坏物"] = {
	["检测周围有人距离"] = 80,
}

GameConfig["闪避"] = {
	["无敌时间"] = 0.35, -- 兼容旧路径；优先读「战斗系统.闪避无敌时间」
}

-- ============================================================================
-- 战斗系统（伤害 / 无敌 / 最小 Buff / 会话战斗属性）
-- 「启用」= false：不 InitPlr、不扣血/写无敌、GetDmg 恒 0、SkillBuff RuntimeWindow 不写
-- ============================================================================

GameConfig["战斗系统"] = {
	["启用"] = true,
	["默认攻击"] = 100,
	["默认生命"] = 1000,
	["默认攻击百分比"] = 0,
	["默认暴击率"] = 0,
	["默认暴击伤害"] = 0.5,
	["默认最终伤害加成"] = 0,
	["默认最终伤害减免"] = 0,
	["闪避无敌时间"] = 0.35,
}

-- ============================================================================
-- 坐骑系统（SystemMount / GroundMount Locomotion）
-- 「启用」= false：不 Init SystemMount、不注册 Mount Remote、客不订 Mount.Toggle
-- ============================================================================

GameConfig["坐骑系统"] = {
	["启用"] = true,
}

-- ============================================================================
-- 背包配置（V2 窗口容量条 / 快捷栏槽数；GRANT_AWARD 仍 Capacity.None，本表不拦发奖）
-- ============================================================================

GameConfig["背包配置"] = {
	["窗口上限"] = 100, -- 容量条展示；Capacity.Backpack 占用只计 Filter.Window
	["工具栏快捷槽数"] = 8, -- Bag.equip 1~N；仅 Filter.Toolbar 可上栏
}

-- 背包 UI（顶栏 / 热键 / Main.Backpack HUD / 锁与拖拽 Remote）
-- 「启用」= false：不建入口、强制藏 HUD；BAG_LOCK_ITEMS / BACKPACK_TOOLBAR_DRAG 拒绝
-- 不关 SystemBag 库存：AddItems / SetupPlayerBag / 自动上栏 / 金币顶栏 / GRANT_AWARD 仍运行
GameConfig["背包UI"] = {
	["启用"] = true,
}

-- ============================================================================
-- 短视频模块（ShortVideoFeature）
-- 「启用」= false：不 Init Remotes / 片单 / 社交，客户端不挂载；Studio 调试按钮也不注册
-- ============================================================================

GameConfig["短视频"] = {
	["启用"] = false,
}

return _deepFreeze(GameConfig)
