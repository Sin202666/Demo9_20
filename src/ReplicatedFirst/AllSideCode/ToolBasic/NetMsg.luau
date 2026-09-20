--[[
	Module: NetMsg
	Description: 游戏通信 msgName 常量表，避免字符串拼写错误
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-04

	功能：
	- RemoteEvent / RemoteFunction / Bindable 的 msgName 常量
	- 技能、逻辑怪、坐骑等通道消息名与 NetWork 注册名对齐

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local NetMsg = Utils.NetMsg
		NetWork.RegisterClientRemoteEvent(NetMsg.PLAY_SOUND, handler)
]]

local NetMsg = {}

-- RemoteEvent（跨端）
NetMsg.PLAYER_DATA_SYNC = "玩家数据同步"
NetMsg.PLAYER_DATA_REQUEST = "请求玩家数据"
NetMsg.SHOW_LOCAL_UI = "显示本地界面"
NetMsg.REFRESH_LOCAL_UI = "刷新本地界面"
NetMsg.SHOW_TIPS = "显示提示"
NetMsg.SHOW_TIPS_2KEY = "显示提示双键"
NetMsg.NEW_SHOW_TIPS = "新显示提示"
NetMsg.NEW_SHOW_TIPS_WITH_TYPE = "新显示提示带类型"
NetMsg.NEW_SHOW_TIPS_WITH_TEMP = "新显示提示带模板"
NetMsg.PLAY_SOUND = "播放声音"
NetMsg.STOP_SOUND = "停止声音"
NetMsg.RNG_SHOW_EFFECT = "随机显示特效"

-- RemoteFunction（跨端）
NetMsg.CLAIM_LEVEL_AWARD = "领取等级奖励"
NetMsg.CLAIM_DAILY_AWARD = "领取每日奖励"
NetMsg.CLAIM_ONLINE_AWARD = "领取在线奖励"
NetMsg.EMAIL_CLAIM_AWARD = "邮件领取奖励"
NetMsg.EMAIL_DELETE = "邮件删除"
NetMsg.EMAIL_READ = "阅读邮件"
NetMsg.UPDATE_LOG_READ = "阅读公告"
NetMsg.SETTING_CHANGE = "设置变更"
NetMsg.INPUT_BINDINGS_GET = "输入键位获取"
NetMsg.INPUT_BINDINGS_SET = "输入键位设置"
NetMsg.REDEEM_CODE = "兑换码"
NetMsg.CANCEL_GIFT = "取消赠送"
NetMsg.SET_GIFT = "设置赠送"
NetMsg.SUBMIT_FEEDBACK = "提交反馈"

-- RemoteEvent / RemoteFunction（调试与基础）
NetMsg.DEBUG_BAG = "调试背包"
NetMsg.DEBUG_SPECIAL = "调试特殊"
NetMsg.DEBUG_RESET = "调试重置"
NetMsg.DEBUG_EMAIL = "调试发邮件"
NetMsg.AFK_MOVE = "挂机移动"
NetMsg.PRIVATE_SERVER_OWNER_ID = "私人服务器玩家id"

-- BindableEvent / BindableFunction（同端）
NetMsg.GRANT_AWARD = "发放奖励"
NetMsg.RECORD_ITEM_GAIN = "记录获得物品"
NetMsg.RECORD_ITEM_REMOVE = "记录删除物品"
NetMsg.GET_EMAIL_COUNT = "获取邮件数量"
NetMsg.OBTAIN_HERO = "获得英雄"

NetMsg.LIGHTING_CHANGE = "光照变更" -- 兼容：等同 LIGHTING_BASELINE_CHANGE
NetMsg.LIGHTING_BASELINE_CHANGE = "光照基线变更"
NetMsg.LIGHTING_ACQUIRE = "光照租约取得"
NetMsg.LIGHTING_RELEASE = "光照租约释放"
NetMsg.LIGHTING_FORCE_CLEAR = "光照租约强制清空" -- 调试/容灾：清 lease 后 reconcile
NetMsg.CLOCK_CHANGE = "时钟变更"
NetMsg.LIGHT_CUSTOM_CHANGE = "光照自定义变更"
NetMsg.UPDATE_CHARACTER_SPEED = "更新角色速度"
NetMsg.FOOT_STEP = "脚步事件"
NetMsg.SHIFT_LOCK = "视角锁定"
NetMsg.EVENT_NOTIFY = "事件通知"

-- 技能域（走 NetChannel.SKILL / Default Bindable）
NetMsg.RELEASE_GROUP_SKILL = "ReleaseGroupSkill"
NetMsg.CLIENT_STOP_SKILL = "ClientStopSkill"
NetMsg.FIX_SKILL_TIME = "FixSkillTime"
NetMsg.STOP_SKILL = "StopSkill"
NetMsg.SYN_SKILL_EFFECT = "SynSkillEffect"
NetMsg.SYN_PLAYER_CFRAME = "SynPlayerCFrame"
NetMsg.DAMAGE_TIP = "DamageTip"
NetMsg.ELEMENT_ATTACH_TIP = "ElementAttachTip"
NetMsg.PLAYER_AIM_SAMPLE = "PlayerAimSample"
NetMsg.BIND_GROUP_SKILL = "BindGroupSkill"
NetMsg.UNBIND_GROUP_SKILL = "UnbindGroupSkill"

-- 逻辑怪同步（Default 通道 / NetWorkRemoteEvent）
NetMsg.ENEMY_LOGICAL_SPAWN = "逻辑怪生成"
NetMsg.ENEMY_LOGICAL_TRANSFORM = "逻辑怪位姿"
NetMsg.ENEMY_LOGICAL_STATE = "逻辑怪状态"
NetMsg.ENEMY_LOGICAL_DEATH = "逻辑怪死亡"
NetMsg.ENEMY_LOGICAL_DISPLACE = "逻辑怪受击位移"

-- 怪物受击表现（SKILL 通道）
NetMsg.SKILL_HIT_PRESENTATION = "技能命中表现"
NetMsg.NPC_COSMETIC_HIT = "NPC受击表现"

-- 坐骑域（Default 通道 / MountNet）
NetMsg.MOUNT_REQ_ENTER = "MountReqEnter"
NetMsg.MOUNT_REQ_EXIT = "MountReqExit"
NetMsg.MOUNT_SYNC_STATE = "MountSyncState"
NetMsg.MOUNT_FORCE_EXIT = "MountForceExit"
NetMsg.MOUNT_SESSION_CHANGED = "MountSessionChanged"

NetMsg.BAG_LOCK_ITEMS = "锁定物品"
NetMsg.BACKPACK_TOOLBAR_DRAG = "背包工具栏拖拽"

return NetMsg
