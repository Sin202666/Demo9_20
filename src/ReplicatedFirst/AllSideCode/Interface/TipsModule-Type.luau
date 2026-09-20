local module = {}

--[[
	显示提示（通用，单翻译键）
	@param player Player - 接收提示的目标玩家
	@param key string - LanguageCfg 翻译键
	@param arg any? - 翻译占位符参数
	@param tp number? - EnumMgr.TipTp；nil 时客户端按 Normal 处理
	@param times number? - 预留重复次数，当前未消费
	@return nil - 经 FireLocalOrClient 下发
]]
function module.showTips(player: Player, key: string, arg: any?, tp: number?, times: number?)
end

--[[
	显示提示（双翻译键，拼接展示）
	@param player Player - 接收提示的目标玩家
	@param key1 string - 第一段 LanguageCfg 翻译键
	@param key2 string - 第二段 LanguageCfg 翻译键
	@param arg any? - 两段共用的翻译占位符参数
	@param tp number? - EnumMgr.TipTp；nil 时按 Normal 处理
	@return nil - 经 FireLocalOrClient 下发
]]
function module.showTips_2Key(player: Player, key1: string, key2: string, arg: any?, tp: number?)
end

--[[
	普通样式提示（单翻译键）
	@param player Player - 接收提示的目标玩家
	@param key string - LanguageCfg 翻译键
	@param arg any? - 翻译占位符参数
	@return nil - 普通样式单键提示
]]
function module.NormalTips(player: Player, key: string, arg: any?)
end

--[[
	错误/警告样式提示（单翻译键）
	@param player Player - 接收提示的目标玩家
	@param key string - LanguageCfg 翻译键
	@param arg any? - 翻译占位符参数
	@return nil - 错误样式单键提示
]]
function module.ErrorTips(player: Player, key: string, arg: any?)
end

--[[
	普通样式提示（双翻译键）
	@param player Player - 接收提示的目标玩家
	@param key1 string - 第一段 LanguageCfg 翻译键
	@param key2 string - 第二段 LanguageCfg 翻译键
	@param arg any? - 两段共用的翻译占位符参数
	@return nil - 普通样式双键提示
]]
function module.NormalTips_2Key(player: Player, key1: string, key2: string, arg: any?)
end

--[[
	错误/警告样式提示（双翻译键）
	@param player Player - 接收提示的目标玩家
	@param key1 string - 第一段 LanguageCfg 翻译键
	@param key2 string - 第二段 LanguageCfg 翻译键
	@param arg any? - 两段共用的翻译占位符参数
	@return nil - 错误样式双键提示
]]
function module.ErrorTips_2Key(player: Player, key1: string, key2: string, arg: any?)
end

--[[
	物品不足错误提示
	@param player Player - 接收提示的目标玩家
	@param needId number - CfgFind 物品配置 ID
	@param needNum number - 需要的数量
	@param hasNum number - 玩家当前持有数量
	@return nil - 配置不存在或缺少 ZhName 时静默 return
]]
function module.TipsNotEnoughItem(player: Player, needId: number, needNum: number, hasNum: number)
end

--[[
	获得奖励提示（预留，优先使用 NewShowTipsTemplate）
	@param player Player - 接收提示的目标玩家
	@param award any - 预留奖励数据结构，尚未实现
	@param count number - 预留展示数量
	@return nil - 当前为空实现，调用时 Log.warn
]]
function module.ShowTipsAward(player: Player, award: any, count: number)
end

--[[
	结构化多段提示
	@param player Player - 接收提示的目标玩家
	@param data {any} - 已翻译的文本段配置数组
	@return nil - 经 FireLocalOrClient 下发
]]
function module.NewShowTips(player: Player, data: { any })
end

--[[
	单句提示并按模板名渲染
	@param player Player - 接收提示的目标玩家
	@param text string - 已翻译的展示文案
	@param templateName string - TipsConfig 模板名
	@return nil - 经 FireLocalOrClient 下发
]]
function module.NewShowTipsWithType(player: Player, text: string, templateName: string)
end

--[[
	服务端模板类型提示
	@param player Player - 接收提示的目标玩家
	@param data { [string]: any } - 须含 Type；载具合成须 Lv、ID、Number；获得奖励须 ID、Count
	@return nil - 经 FireLocalOrClient 下发
]]
function module.NewShowTipsTemplate(player: Player, data: { [string]: any })
end

--[[
	打开 AwardPop 发奖展示窗（服务端专用）
	@param player Player - 接收 UI 的目标玩家
	@param itemIdList {number} - 物品 ID 列表，与 itemCountList 下标对应
	@param itemCountList {number} - 物品数量列表
	@return nil - 非服务端或参数非 table 时 Log.warn 并 return
]]
function module.ShowAwardPop(player: Player, itemIdList: { number }, itemCountList: { number })
end

return module
