--[[
	Module: ShowDetail
	Description: 客户端详情弹层显隐、锚点定位，并按类型路由到详情 Frame 下子 ModuleScript
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	功能：
	- HideAllDetail / GetDetailVisible — 批量隐藏与可见性查询
	- ShowDetail / HoldShow — 按背包 onlyID 点击或悬停展示
	- ShowDetailByCfgID — 按配置 id 展示（英雄类型暂跳过，依赖 EnumMgr.ItemType.Hero）
	- ShowDetailByData / HoldShowByData / ShowDetailSpecial — 按数据或具名详情框展示
	- ShowGamePassDetail / HideGamePassDetail — GamePass 说明条（文案走 TranslationHelper）

	与 UIMgr / GetData 的关系：
	- 数据与配置只读查询走 GetData、CfgFind；本模块不修改背包或权威数据
	- UI 列表悬停/点击由 GuiScripts 或 UIMgr 调用本模块
	- 各详情 Frame 下 ModuleScript 实现 ShowByData / HoldShow / ShowByCfgID / ShowSpecial 等入口

	端侧约束：
	- 仅客户端调用；依赖 LocalPlayer.PlayerGui.ScreenGui/详情 层级
	- 不写存档、不发 Remote、不结算奖励

	UI 约定：
	- 详情容器：PlayerGui.ScreenGui 下名为「详情」的 Instance
	- 子 Frame 名称为物品类型 number 或自定义 string（如「通用物品详情」）
	- GamePass 说明框 Frame 名为 100（DETAIL_TYPE_GAME_PASS），不是 EnumMgr.ItemType.GamePass

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local ShowDetail = Utils.ShowDetail

	示例：
		ShowDetail.ShowDetail(onlyID, itemFrame, false)
		ShowDetail.ShowDetailByData(itemData, itemFrame, "通用物品详情", false)
		ShowDetail.ShowGamePassDetail(player, passTag, itemFrame)
		ShowDetail.HideAllDetail()
]]

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local Copy = Utils.Copy
local GetData = Utils.GetData
local Log = Utils.Log
local TranslationHelper = Utils.TranslationHelper
local LocalPlayer = Utils.LocalPlayer

-- ============================================================================
-- 模块定义
-- ============================================================================

local ShowDetail = {}

-- ============================================================================
-- 类型定义
-- ============================================================================

-- 子 ModuleScript.HoldShowByData 等使用的展示数据；字段因详情类型而异
type DetailDisplayData = { [string]: any }

-- 与 Class.Struct.Item 对齐；本模块只作类型约束，不 require Struct（Utils.Struct 无法导出 export type）
type ItemData = {
	id: number,
	tp: number,
	onlyID: number,
	lock: number,
	count: number,
}

-- ============================================================================
-- 常量定义
-- ============================================================================

local PLAYER_GUI_NAME = "PlayerGui"
local MAIN_SCREEN_GUI_NAME = "ScreenGui"
local DETAIL_SCREEN_NAME = "详情"
local GAME_PASS_DES_LABEL_NAME = "Des"
-- 详情 Screen 下 GamePass 说明框的子 Frame 名（不是 EnumMgr.ItemType.GamePass）
local DETAIL_TYPE_GAME_PASS = 100

local ANCHOR_FIXED = 0
local ANCHOR_LEFT = 1
local ANCHOR_RIGHT = 2

-- ============================================================================
-- 私有变量
-- ============================================================================

local _nowShowID: number? = nil
local _nowHover: number? = nil
local _specialData: DetailDisplayData? = nil
local _nowShowPassTag: string? = nil

local _detailScriptCache: { [ModuleScript]: any } = {}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	获取 PlayerGui.ScreenGui 下的详情容器
	@return Instance? - 详情 Screen；层级不存在或非客户端时 nil
]]
local function _getDetailScreen(): Instance?
	if not LocalPlayer then
		return nil
	end

	local plrGui: Instance? = LocalPlayer:FindFirstChild(PLAYER_GUI_NAME)
	if not plrGui then
		return nil
	end

	local screenGui: Instance? = plrGui:FindFirstChild(MAIN_SCREEN_GUI_NAME)
	if not screenGui then
		return nil
	end

	return screenGui:FindFirstChild(DETAIL_SCREEN_NAME)
end

--[[
	按子节点名称或类型 id 获取详情 Frame
	@param childKey string | number - 详情 Screen 下子 Frame 名称或物品类型 id
	@return Frame? - 详情框；层级不存在时 nil
]]
local function _getDetailFrame(childKey: string | number): Frame?
	local detailScreen = _getDetailScreen()
	if not detailScreen then
		return nil
	end

	return detailScreen:FindFirstChild(childKey) :: Frame?
end

--[[
	获取详情 Frame 下子 ModuleScript 模块（按实例缓存，避免函数内重复 require）
	@param detailScript ModuleScript - 详情框内挂载的展示脚本
	@return any? - require 后的模块表；无效时 nil
]]
local function _getDetailScript(detailScript: ModuleScript): any?
	local cached = _detailScriptCache[detailScript]
	if cached then
		return cached
	end

	local ok, result = pcall(require, detailScript)
	if not ok then
		Log.warn("[ShowDetail] require detail ModuleScript failed:", result)
		return nil
	end

	_detailScriptCache[detailScript] = result
	return result
end

--[[
	调用详情 Frame 下子 ModuleScript 的指定方法
	@param detail Frame - 已定位的详情框
	@param methodName string - 子模块方法名（ShowByData / HoldShow / ShowByCfgID / ShowSpecial / HoldShowByData）
	@param ... any - 透传给该方法的参数
	@return nil - 无返回值
]]
local function _invokeDetailScript(detail: Frame, methodName: string, ...: any): nil
	local detailScript: ModuleScript? = detail:FindFirstChildOfClass("ModuleScript")
	if not detailScript then
		return
	end

	local scriptModule = _getDetailScript(detailScript)
	if scriptModule and scriptModule[methodName] then
		scriptModule[methodName](...)
	end
	return
end

--[[
	根据参考 Frame 与屏幕象限设置详情框锚点与位置
	@param detail Frame - 待定位的详情框
	@param anchorFrame Frame - 参考控件（通常为物品格）
	@param useFixedPos boolean? - true 时固定左上锚点，不按象限翻转
	@return boolean - 定位成功 true；父级 ScreenGui 不可用时 false
]]
local function _setDetailPos(detail: Frame, anchorFrame: Frame, useFixedPos: boolean?): boolean
	local detailScreen = detail.Parent
	if not detailScreen then
		return false
	end

	local screenGui = detailScreen.Parent
	if not screenGui or not screenGui:IsA("ScreenGui") then
		return false
	end

	local uiScaleInst = screenGui:FindFirstChildOfClass("UIScale")
	local uiScale: number = if uiScaleInst then uiScaleInst.Scale else 1
	if uiScale <= 0 then
		uiScale = 1
	end

	local screenOffset: Vector2 = screenGui.AbsolutePosition

	detail.Visible = true
	local pos: Vector2 = anchorFrame.AbsolutePosition - screenOffset
	pos = Vector2.new(pos.X / uiScale, pos.Y / uiScale)

	if useFixedPos == true then
		detail.AnchorPoint = Vector2.new(0, 0)
		detail:SetAttribute("LeftRight", ANCHOR_FIXED)
		detail.Position = UDim2.new(0, pos.X + anchorFrame.AbsoluteSize.X / 2, 0, pos.Y + anchorFrame.AbsoluteSize.Y / 2)
		return true
	end

	local screenSize: Vector2 = screenGui.AbsoluteSize
	local rawAnchorSize: Vector2 = anchorFrame.AbsoluteSize
	local anchorSize: Vector2 = Vector2.new(rawAnchorSize.X / uiScale, rawAnchorSize.Y / uiScale)

	local isLeft = pos.X <= screenSize.X / 2
	local isTop = pos.Y <= screenSize.Y / 2

	if isLeft and isTop then
		detail.AnchorPoint = Vector2.new(0, 0)
		detail:SetAttribute("LeftRight", ANCHOR_LEFT)
		detail.Position = UDim2.new(0, pos.X + anchorSize.X, 0, pos.Y)
	elseif (not isLeft) and isTop then
		detail.AnchorPoint = Vector2.new(1, 0)
		detail:SetAttribute("LeftRight", ANCHOR_RIGHT)
		detail.Position = UDim2.new(0, pos.X, 0, pos.Y)
	elseif isLeft and (not isTop) then
		detail.AnchorPoint = Vector2.new(0, 1)
		detail:SetAttribute("LeftRight", ANCHOR_LEFT)
		detail.Position = UDim2.new(0, pos.X + anchorSize.X, 0, pos.Y + anchorSize.Y)
	else
		detail.AnchorPoint = Vector2.new(1, 1)
		detail:SetAttribute("LeftRight", ANCHOR_RIGHT)
		detail.Position = UDim2.new(0, pos.X, 0, pos.Y + anchorSize.Y)
	end

	return true
end

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	隐藏所有详情框并重置模块内展示状态
	@return nil - 无返回值
]]
function ShowDetail.HideAllDetail(): nil
	local detailScreen = _getDetailScreen()
	if not detailScreen then
		_nowShowID = nil
		_nowHover = nil
		_specialData = nil
		_nowShowPassTag = nil
		return
	end

	for _, child in ipairs(detailScreen:GetChildren()) do
		if child:IsA("Frame") and child.Visible == true then
			child.Visible = false
		end
	end

	_nowShowID = nil
	_nowHover = nil
	_specialData = nil
	_nowShowPassTag = nil
	return
end

--[[
	查询指定类型详情框是否可见
	@param tp number - 物品类型 id，对应详情 Screen 下子 Frame 名称
	@return boolean - 存在且 Visible 为 true 时 true
]]
function ShowDetail.GetDetailVisible(tp: number): boolean
	local detail: Frame? = _getDetailFrame(tp)
	if not detail then
		return false
	end

	return detail.Visible == true
end

--[[
	根据配置 id 显示详情（同 id 再次调用则关闭）
	@param cfgID number - CfgFind 配置表 id
	@param anchorFrame Frame - 参考控件，用于定位详情框
	@return nil - 无返回值
]]
function ShowDetail.ShowDetailByCfgID(cfgID: number, anchorFrame: Frame): nil
	if _nowShowID == cfgID then
		ShowDetail.HideAllDetail()
		return
	end

	ShowDetail.HideAllDetail()

	local cfg = CfgFind.FindCfgByID(cfgID)
	if not cfg then
		return
	end

	-- EnumMgr.ItemType.Hero 尚未注册时条件恒为假；补齐枚举后自动跳过英雄详情
	if cfg.tp == EnumMgr.ItemType.Hero then
		return
	end

	local detail: Frame? = _getDetailFrame(cfg.tp)
	if not detail then
		return
	end

	if not _setDetailPos(detail, anchorFrame) then
		return
	end

	_nowShowID = cfgID
	_invokeDetailScript(detail, "ShowByCfgID", cfg, cfgID)
	return
end

--[[
	根据背包 onlyID 显示详情（同 onlyID 再次调用则关闭）
	@param onlyID number - 背包条目唯一 id
	@param anchorFrame Frame - 参考控件
	@param useFixedPos boolean? - true 时固定锚点，nil/false 按屏幕象限适配
	@return nil - 无返回值
]]
function ShowDetail.ShowDetail(onlyID: number, anchorFrame: Frame, useFixedPos: boolean?): nil
	if _nowShowID == onlyID then
		ShowDetail.HideAllDetail()
		return
	end

	ShowDetail.HideAllDetail()

	local thisData, cfg = GetData.GetDataAndCfg(onlyID)
	if not thisData or not cfg then
		return
	end

	local detail: Frame? = _getDetailFrame(cfg.tp)
	if not detail then
		return
	end

	if not _setDetailPos(detail, anchorFrame, useFixedPos) then
		return
	end

	_nowShowID = onlyID
	_invokeDetailScript(detail, "ShowByData", thisData, cfg, anchorFrame)
	return
end

--[[
	根据背包 onlyID 悬停显示详情（同 onlyID 再次调用则关闭）
	@param onlyID number - 背包条目唯一 id
	@param anchorFrame Frame - 参考控件
	@param useFixedPos boolean? - true 时固定锚点，nil/false 按屏幕象限适配
	@return nil - 无返回值
]]
function ShowDetail.HoldShow(onlyID: number, anchorFrame: Frame, useFixedPos: boolean?): nil
	if _nowHover == onlyID then
		ShowDetail.HideAllDetail()
		return
	end

	ShowDetail.HideAllDetail()

	local thisData, cfg = GetData.GetDataAndCfg(onlyID)
	if not thisData or not cfg then
		return
	end

	local detail: Frame? = _getDetailFrame(cfg.tp)
	if not detail then
		return
	end

	if not _setDetailPos(detail, anchorFrame, useFixedPos) then
		return
	end

	_nowHover = onlyID
	_invokeDetailScript(detail, "HoldShow", thisData, cfg, anchorFrame)
	return
end

--[[
	根据外部数据悬停显示详情（同 onlyID 再次调用则关闭）
	@param onlyID number - 用于 toggle 判定的逻辑 id（可与背包 onlyID 一致）
	@param anchorFrame Frame - 参考控件
	@param frameName string - 详情 Screen 下子 Frame 名称（如「通用物品详情」）
	@param displayData DetailDisplayData - 传给子 ModuleScript 的展示数据；字段由该脚本约定
	@param useFixedPos boolean? - true 时固定锚点，nil/false 按屏幕象限适配
	@return nil - 无返回值
]]
function ShowDetail.HoldShowByData(
	onlyID: number,
	anchorFrame: Frame,
	frameName: string,
	displayData: DetailDisplayData,
	useFixedPos: boolean?
): nil
	if _nowHover == onlyID then
		ShowDetail.HideAllDetail()
		return
	end

	ShowDetail.HideAllDetail()

	local detail: Frame? = _getDetailFrame(frameName)
	if not detail then
		return
	end

	if not _setDetailPos(detail, anchorFrame, useFixedPos) then
		return
	end

	_nowHover = onlyID
	_invokeDetailScript(detail, "HoldShowByData", anchorFrame, displayData)
	return
end

--[[
	显示带附加特殊数据的详情（同 onlyID 且 data 相等时再次调用则关闭）
	@param onlyID number - 背包条目唯一 id
	@param anchorFrame Frame - 参考控件
	@param frameName string - 详情 Screen 下子 Frame 名称
	@param useFixedPos boolean? - true 时固定锚点，nil/false 按屏幕象限适配
	@param specialData DetailDisplayData - 传给子 ModuleScript.ShowSpecial 的附加数据；字段由该脚本约定
	@return nil - 无返回值
]]
function ShowDetail.ShowDetailSpecial(
	onlyID: number,
	anchorFrame: Frame,
	frameName: string,
	useFixedPos: boolean?,
	specialData: DetailDisplayData
): nil
	if _nowShowID == onlyID and Copy.IsEqual(_specialData, specialData) then
		ShowDetail.HideAllDetail()
		return
	end

	ShowDetail.HideAllDetail()

	local thisData, cfg = GetData.GetDataAndCfg(onlyID)
	if not thisData or not cfg then
		return
	end

	local detail: Frame? = _getDetailFrame(frameName)
	if not detail then
		return
	end

	if not _setDetailPos(detail, anchorFrame, useFixedPos) then
		return
	end

	_nowShowID = onlyID
	_specialData = specialData
	_invokeDetailScript(detail, "ShowSpecial", thisData, cfg, anchorFrame, specialData)
	return
end

--[[
	根据 Struct.Item 数据对象显示详情（同 onlyID 再次调用则关闭）
	@param itemData ItemData - 背包条目；字段与 Class.Struct.Item 对齐（须含 onlyID）
	@param anchorFrame Frame - 参考控件
	@param frameName string - 详情 Screen 下子 Frame 名称
	@param useFixedPos boolean? - true 时固定锚点，nil/false 按屏幕象限适配
	@param ... any - 透传给子 ModuleScript.ShowByData 的额外参数
	@return nil - 无返回值
]]
function ShowDetail.ShowDetailByData(
	itemData: ItemData,
	anchorFrame: Frame,
	frameName: string,
	useFixedPos: boolean?,
	...
): nil
	if itemData == nil then
		ShowDetail.HideAllDetail()
		return
	end

	if _nowShowID == itemData.onlyID then
		ShowDetail.HideAllDetail()
		return
	end

	ShowDetail.HideAllDetail()

	local detail: Frame? = _getDetailFrame(frameName)
	if not detail then
		return
	end

	if not _setDetailPos(detail, anchorFrame, useFixedPos) then
		return
	end

	_nowShowID = itemData.onlyID
	_invokeDetailScript(detail, "ShowByData", itemData, ...)
	return
end

--[[
	显示 GamePass 说明详情（同 passTag 再次调用则关闭；已拥有通行证则不展示）
	@param plr Player - 目标玩家
	@param passTag string - GamePass 配置标签（CfgFind.FindCfgByOnlyTag）
	@param anchorFrame Frame - 参考控件
	@return nil - 无返回值
]]
function ShowDetail.ShowGamePassDetail(plr: Player, passTag: string, anchorFrame: Frame): nil
	if _nowShowPassTag == passTag then
		ShowDetail.HideAllDetail()
		return
	end

	ShowDetail.HideAllDetail()

	if GetData.IsHasPass(plr, passTag) then
		return
	end

	local cfg = CfgFind.FindCfgByOnlyTag(passTag)
	if not cfg then
		return
	end

	local detail: Frame? = _getDetailFrame(DETAIL_TYPE_GAME_PASS)
	if not detail then
		return
	end

	local desLabel: TextLabel? = detail:FindFirstChild(GAME_PASS_DES_LABEL_NAME) :: TextLabel?
	if not desLabel then
		return
	end

	if type(cfg.ZhDes) ~= "string" or cfg.ZhDes == "" then
		return
	end

	TranslationHelper.SetText(desLabel, cfg.ZhDes)

	if not _setDetailPos(detail, anchorFrame) then
		return
	end

	_nowShowPassTag = passTag
	return
end

--[[
	隐藏指定 GamePass 标签的详情
	@param passTag string - 与 ShowGamePassDetail 传入的 passTag 一致
	@return nil - 无返回值
]]
function ShowDetail.HideGamePassDetail(passTag: string): nil
	if _nowShowPassTag == passTag then
		ShowDetail.HideAllDetail()
	end
	return
end

return ShowDetail
