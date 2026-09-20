local module = {}

-- NetMsg 是通信 msgName 常量表，非延迟加载白名单模块

module.PLAYER_DATA_SYNC = "玩家数据同步"
module.PLAYER_DATA_REQUEST = "请求玩家数据"
module.SHOW_LOCAL_UI = "显示本地界面"
module.REFRESH_LOCAL_UI = "刷新本地界面"
module.SHOW_TIPS = "显示提示"
module.SHOW_TIPS_2KEY = "显示提示双键"
module.NEW_SHOW_TIPS = "新显示提示"
module.NEW_SHOW_TIPS_WITH_TYPE = "新显示提示带类型"
module.NEW_SHOW_TIPS_WITH_TEMP = "新显示提示带模板"
module.PLAY_SOUND = "播放声音"
module.STOP_SOUND = "停止声音"
module.RNG_SHOW_EFFECT = "随机显示特效"

module.CLAIM_LEVEL_AWARD = "领取等级奖励"
module.CLAIM_DAILY_AWARD = "领取每日奖励"
module.CLAIM_ONLINE_AWARD = "领取在线奖励"
module.EMAIL_CLAIM_AWARD = "邮件领取奖励"
module.EMAIL_DELETE = "邮件删除"
module.EMAIL_READ = "阅读邮件"
module.UPDATE_LOG_READ = "阅读公告"
module.SETTING_CHANGE = "设置变更"
module.INPUT_BINDINGS_GET = "输入键位获取"
module.INPUT_BINDINGS_SET = "输入键位设置"
module.REDEEM_CODE = "兑换码"
module.CANCEL_GIFT = "取消赠送"
module.SET_GIFT = "设置赠送"
module.SUBMIT_FEEDBACK = "提交反馈"

module.DEBUG_BAG = "调试背包"
module.DEBUG_SPECIAL = "调试特殊"
module.DEBUG_RESET = "调试重置"
module.DEBUG_EMAIL = "调试发邮件"
module.AFK_MOVE = "挂机移动"
module.PRIVATE_SERVER_OWNER_ID = "私人服务器玩家id"

module.GRANT_AWARD = "发放奖励"
module.RECORD_ITEM_GAIN = "记录获得物品"
module.RECORD_ITEM_REMOVE = "记录删除物品"
module.GET_EMAIL_COUNT = "获取邮件数量"
module.OBTAIN_HERO = "获得英雄"

module.LIGHTING_CHANGE = "光照变更" -- 兼容：等同 LIGHTING_BASELINE_CHANGE
module.LIGHTING_BASELINE_CHANGE = "光照基线变更"
module.LIGHTING_ACQUIRE = "光照租约取得"
module.LIGHTING_RELEASE = "光照租约释放"
module.LIGHTING_FORCE_CLEAR = "光照租约强制清空"
module.CLOCK_CHANGE = "时钟变更"
module.LIGHT_CUSTOM_CHANGE = "光照自定义变更"
module.UPDATE_CHARACTER_SPEED = "更新角色速度"
module.FOOT_STEP = "脚步事件"
module.SHIFT_LOCK = "视角锁定"
module.EVENT_NOTIFY = "事件通知"

module.MOUNT_REQ_ENTER = "MountReqEnter"
module.MOUNT_REQ_EXIT = "MountReqExit"
module.MOUNT_SYNC_STATE = "MountSyncState"
module.MOUNT_FORCE_EXIT = "MountForceExit"
module.MOUNT_SESSION_CHANGED = "MountSessionChanged"

module.BAG_LOCK_ITEMS = "锁定物品"
module.BACKPACK_TOOLBAR_DRAG = "背包工具栏拖拽"

return module
