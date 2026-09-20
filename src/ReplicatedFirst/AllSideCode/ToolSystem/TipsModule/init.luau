--[[
	Module: TipsModule
	Description: 提示网络接口（服务端向客户端下发 / 本地 Bindable 路由）
	Author: 林奥宇
	Created: 2026-01-19
	Last Modified: 2026-09-04

	功能：
	- 服务端：向指定玩家下发各类提示事件
	- 客户端：通过 Bindable 触发本地提示（由 TipsManager 监听并渲染）
	- 不直接操作 UI，实际渲染在 TipsRenderer 中完成
	- ShowAwardPop：历史兼容，打开 AwardPop 发奖展示窗（非 Tips 条），仅服务端

	子模块：
	- TipsConfig.luau           常量、模板与资源引用
	- TipsRenderer.luau         客户端提示 UI 渲染
	- TipsTemplateBuilder.luau  服务端模板类型 → 提示数据构建

	================================================================================
	使用说明
	================================================================================

	【引入方式】
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local TipsModule = Utils.TipsModule       -- 网络 / 本地路由（推荐大多数调用方使用）
	local TipsRenderer = Utils.TipsRenderer   -- 直接渲染（客户端高级场景）

	【架构与调用链】
	服务端 NormalTips → NetWork.FireLocalOrClient(SHOW_TIPS) → TipsManager → TipsRenderer.templateTip
	客户端 NormalTips → 同上（客户端走 Bindable）
	双键提示：showTips_2Key → SHOW_TIPS_2KEY → TipsManager → TipsRenderer.templateTip
	结构化提示：NewShowTips / NewShowTipsTemplate → 对应 msg → TipsRenderer

	客户端 TipsManager 位于 StarterPlayerScripts/Manager/TipsManager.client.luau，
	负责监听 Remote / Bindable，业务代码不应重复注册 SHOW_TIPS 等事件。

	【运行环境】
	| API                    | 调用端   | 说明                              |
	|------------------------|----------|-----------------------------------|
	| NormalTips / ErrorTips | 双端     | 翻译键提示，经 FireLocalOrClient  |
	| NewShowTips*           | 双端     | 结构化 / 模板提示                 |
	| ShowAwardPop           | 仅服务端 | 打开 AwardPop 发奖窗（非 Tips 条） |
	| TipsRenderer           | 仅客户端 | 含 PlayerGui 副作用               |

	【调用示例】
	-- 服务端：普通提示
	TipsModule.NormalTips(player, "领取成功")

	-- 服务端：物品不足
	TipsModule.TipsNotEnoughItem(player, itemId, needNum, hasNum)

	-- 客户端：本地错误提示
	TipsModule.ErrorTips(LocalPlayer, "Code不能为空")

	-- 服务端：结构化获得奖励提示
	TipsModule.NewShowTipsTemplate(player, { Type = TipsConfig.SERVER_TEMPLATE_REWARD, ID = 1001, Count = 5 })
]]

-- ========================================
-- Requires
-- ========================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local MathMgr = Utils.MathMgr
local Log = Utils.Log

-- ========================================
-- Module definition
-- ========================================

local TipsModule = {}

local UI_NAME_AWARD_POP = "AwardPop"

-- ========================================
-- Private functions
-- ========================================

--[[
	按 TipTp 类型转发至 showTips
	@param player Player - 接收提示的目标玩家
	@param tp number - 提示类型，取 EnumMgr.TipTp.Normal 或 EnumMgr.TipTp.Error
	@param key string - LanguageCfg 翻译键
	@param arg any? - 翻译占位符参数；无占位符时传 nil
	@return nil - 转发至 showTips，无独立返回值
]]
local function _showTipsByKey(player: Player, tp: number, key: string, arg: any?)
	TipsModule.showTips(player, key, arg, tp)
end

-- ========================================
-- Public API
-- ========================================

--[[
	显示提示（通用，单翻译键）
	@param player Player - 接收提示的目标玩家；服务端下发时须在线
	@param key string - LanguageCfg 翻译键，非直接展示文案
	@param arg any? - 翻译占位符参数数组或单值；无则 nil
	@param tp number? - 提示类型，EnumMgr.TipTp；nil 时客户端按 Normal 处理
	@param times number? - 预留：重复展示次数，当前未消费
	@return nil - 经 FireLocalOrClient 下发，无返回值
]]
function TipsModule.showTips(player: Player, key: string, arg: any?, tp: number?, times: number?)
	NetWork.FireLocalOrClient(player, NetMsg.SHOW_TIPS, key, arg, tp, times)
end

--[[
	显示提示（双翻译键，拼接展示）
	@param player Player - 接收提示的目标玩家；服务端下发时须在线
	@param key1 string - 第一段 LanguageCfg 翻译键
	@param key2 string - 第二段 LanguageCfg 翻译键，翻译后与 key1 结果拼接
	@param arg any? - 两段翻译共用的占位符参数；无则 nil
	@param tp number? - 提示类型，EnumMgr.TipTp；nil 时按 Normal 处理
	@return nil - 经 FireLocalOrClient 下发，无返回值
]]
function TipsModule.showTips_2Key(player: Player, key1: string, key2: string, arg: any?, tp: number?)
	NetWork.FireLocalOrClient(player, NetMsg.SHOW_TIPS_2KEY, key1, key2, arg, tp)
end

--[[
	普通样式提示（单翻译键）
	@param player Player - 接收提示的目标玩家
	@param key string - LanguageCfg 翻译键
	@param arg any? - 翻译占位符参数；无则 nil
	@return nil - 走 _showTipsByKey(Normal)
]]
function TipsModule.NormalTips(player: Player, key: string, arg: any?)
	_showTipsByKey(player, EnumMgr.TipTp.Normal, key, arg)
end

--[[
	错误/警告样式提示（单翻译键）
	@param player Player - 接收提示的目标玩家
	@param key string - LanguageCfg 翻译键
	@param arg any? - 翻译占位符参数；无则 nil
	@return nil - 走 _showTipsByKey(Error)
]]
function TipsModule.ErrorTips(player: Player, key: string, arg: any?)
	_showTipsByKey(player, EnumMgr.TipTp.Error, key, arg)
end

--[[
	普通样式提示（双翻译键）
	@param player Player - 接收提示的目标玩家
	@param key1 string - 第一段 LanguageCfg 翻译键
	@param key2 string - 第二段 LanguageCfg 翻译键
	@param arg any? - 两段翻译共用的占位符参数；无则 nil
	@return nil - 走 showTips_2Key(Normal)
]]
function TipsModule.NormalTips_2Key(player: Player, key1: string, key2: string, arg: any?)
	TipsModule.showTips_2Key(player, key1, key2, arg, EnumMgr.TipTp.Normal)
end

--[[
	错误/警告样式提示（双翻译键）
	@param player Player - 接收提示的目标玩家
	@param key1 string - 第一段 LanguageCfg 翻译键
	@param key2 string - 第二段 LanguageCfg 翻译键
	@param arg any? - 两段翻译共用的占位符参数；无则 nil
	@return nil - 走 showTips_2Key(Error)
]]
function TipsModule.ErrorTips_2Key(player: Player, key1: string, key2: string, arg: any?)
	TipsModule.showTips_2Key(player, key1, key2, arg, EnumMgr.TipTp.Error)
end

--[[
	物品不足错误提示（自动拼装翻译参数）
	@param player Player - 接收提示的目标玩家
	@param needId number - CfgFind 物品配置 ID
	@param needNum number - 需要的数量
	@param hasNum number - 玩家当前持有数量
	@return nil - 配置不存在或缺少 ZhName 时静默 return
]]
function TipsModule.TipsNotEnoughItem(player: Player, needId: number, needNum: number, hasNum: number)
	local lessNum = MathMgr.getNumStr(needNum - hasNum)
	local itemCfg = CfgFind.FindCfgByID(needId)
	if not itemCfg or not itemCfg.ZhName then
		return
	end

	TipsModule.ErrorTips(player, "还差多少道具", { lessNum, { itemCfg.ZhName } })
end

--[[
	获得奖励提示（预留，请优先使用 NewShowTipsTemplate）
	@param player Player - 接收提示的目标玩家
	@param award any - 预留奖励数据结构，尚未定义
	@param count number - 预留展示数量
	@return nil - 当前为空实现，调用时 Log.warn 提示改用 NewShowTipsTemplate
]]
function TipsModule.ShowTipsAward(_player: Player, _award: any, _count: number)
	-- TODO(林奥宇, 2026-07-02): 实现 ShowTipsAward，或统一迁移至 NewShowTipsTemplate
	Log.warn("[TipsModule] ShowTipsAward 尚未实现，请改用 NewShowTipsTemplate")
end

--[[
	结构化多段提示（自定义文本配置数组）
	@param player Player - 接收提示的目标玩家
	@param data {any} - 已翻译的文本段配置数组（Text、TextSize、Font、UIGradientString 等）；本 API 不再查表
	@return nil - 经 FireLocalOrClient 下发，无返回值
]]
function TipsModule.NewShowTips(player: Player, data: { any })
	NetWork.FireLocalOrClient(player, NetMsg.NEW_SHOW_TIPS, data)
end

--[[
	单句提示并按 TipsConfig 模板名渲染
	@param player Player - 接收提示的目标玩家
	@param text string - 已翻译的展示文案（调用方须先 TranslateByKey；本 API 不再查表）
	@param templateName string - TipsConfig 模板名，如 TEMPLATE_NORMAL / TEMPLATE_ERROR
	@return nil - 经 FireLocalOrClient 下发，无返回值
]]
function TipsModule.NewShowTipsWithType(player: Player, text: string, templateName: string)
	NetWork.FireLocalOrClient(player, NetMsg.NEW_SHOW_TIPS_WITH_TYPE, text, templateName)
end

--[[
	服务端模板类型提示（由 TipsTemplateBuilder 构建多段数据）
	@param player Player - 接收提示的目标玩家
	@param data { [string]: any } - 须含 Type（string）；载具合成须 Lv、ID、Number（Xyd 可选）；获得奖励须 ID、Count
	@return nil - 经 FireLocalOrClient 下发；客户端按 Type 查表翻译
]]
function TipsModule.NewShowTipsTemplate(player: Player, data: { [string]: any })
	NetWork.FireLocalOrClient(player, NetMsg.NEW_SHOW_TIPS_WITH_TEMP, data)
end

--[[
	打开 AwardPop 发奖展示窗（非 Tips 条，服务端专用；历史兼容 API）
	@param player Player - 接收 UI 的目标玩家；须在线
	@param itemIdList {number} - 奖励物品 ID 列表，与 itemCountList 下标一一对应
	@param itemCountList {number} - 奖励数量列表，与 itemIdList 等长
	@return nil - 非服务端或参数非 table 时 Log.warn 并 return
]]
function TipsModule.ShowAwardPop(player: Player, itemIdList: { number }, itemCountList: { number })
	if type(itemIdList) ~= "table" or type(itemCountList) ~= "table" then
		Log.warn("ShowAwardPop 传入类型不对 不是table")
		return
	end

	local uiData = {
		AwardID = itemIdList,
		Count = itemCountList,
	}
	local fired = NetWork.FireClientIfServer(player, NetMsg.SHOW_LOCAL_UI, UI_NAME_AWARD_POP, uiData, true)
	if not fired then
		Log.warn("ShowAwardPop 仅服务端可用")
	end
end

return TipsModule