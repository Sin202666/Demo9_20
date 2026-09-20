--[[
	Module: UIMgr
	Description: UI 工具模块：奖励展示、列表/网格尺寸、主界面可见性、ScreenGui 启停、背景模糊/景深、弹窗批量关闭，以及 UI 渐变、稀有度配色与循环表现；Robux 价格见子模块 RbPrice。
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-17

	子模块（业务只经本 façade / Utils.UIMgr，不要直接 require 子文件）：
	- Award.luau       奖励格 / SetRoleIcon
	- BagSlot.luau     背包格子皮肤（V1 AwardStyle 填格）
	- Visibility.luau  主界面显隐、模糊/景深、弹窗关闭
	- Layout.luau      UIList / UIGrid 尺寸
	- RbPrice.luau     Robux 价签（同步 / 按 productId·OnlyTag 异步拉价与缓存）
	- Gradients/       稀有度/元素/称号渐变与循环表现（Anim / Core / Rarity / Element / Title）
	- GradientCfg.luau 渐变别名表（由 Gradients.Core 查询）
	- GradientAnimCfg.luau 循环自动播映射（由 Gradients.Anim 查询）

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local UIMgr = Utils.UIMgr

	示例：
		UIMgr.SetAward(frame, itemId, count)
		UIMgr.BagSlot.Bind(frame, vm)
		UIMgr.SetMainUIVisible()
		UIMgr.SetUIlistSize_New(listFrame)
		UIMgr.setXydLabel(textLabel, 5)
		UIMgr.SetRbPrice(priceLabel, 79)
		UIMgr.SetRbPriceByOnlyTag(priceLabel, "OnlineAwardClaimAll")
		UIMgr.AddGradientColor("蓝", frame)
		UIMgr.AddGradientColor("彩虹", frame)
		UIMgr.PlayGradientAnim(gradient, "Rotation", { degPerSec = 50 })
		UIMgr.ApplyTitleTextByTitleId(titleLabel, titleItemId)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr

local UIMgr = {}

local LENGTH_ADJUSTMENT_SCRIPT_NAME = "LengthAdjustment"

--[[
	将子模块公开函数合并到 UIMgr façade（后合并覆盖同名键）
	@param source { [string]: any } - 子模块导出表
	@return () - 无返回值
]]
local function _mergeExport(source: { [string]: any })
	for apiName, apiFn in source do
		UIMgr[apiName] = apiFn
	end
end

--[[
	设置标题
	@param _title number - 标题ID
	@param Title ImageLabel - 标题图片标签
	@return () - 无返回值
]]
function UIMgr.SetTitel(_title: number, Title: ImageLabel): ()
	if _title <= 0 then
		Title.Image = ""
		Title.Visible = false
		return
	end

	local cfgTitle = CfgFind.FindCfgByID(_title, EnumMgr.ItemType.Title)
	if not cfgTitle then
		return
	end

	Title.Visible = true
	Title.Image = "rbxassetid://" .. cfgTitle.Icon

	local aspectRatioConstraint: UIAspectRatioConstraint? = Title:FindFirstChildOfClass("UIAspectRatioConstraint") :: UIAspectRatioConstraint?
	if aspectRatioConstraint and cfgTitle.Size and #cfgTitle.Size >= 2 then
		aspectRatioConstraint.AspectRatio = cfgTitle.Size[1] / cfgTitle.Size[2]
	end
end

--[[
	添加文本长度调整脚本
	@param _text TextLabel - 文本标签
	@return () - 无返回值
]]
function UIMgr.AddTextLength(_text: TextLabel): ()
	if _text:FindFirstChild(LENGTH_ADJUSTMENT_SCRIPT_NAME) then
		return
	end

	if not _text:IsA("TextLabel") then
		return
	end

	local CharLenAda: LocalScript? = script:FindFirstChild(LENGTH_ADJUSTMENT_SCRIPT_NAME) :: LocalScript?
	if not CharLenAda then
		return
	end

	local newScript: LocalScript = CharLenAda:Clone() :: LocalScript
	newScript.Parent = _text
end

_mergeExport(require(script.Award)(UIMgr))
UIMgr.BagSlot = require(script.BagSlot)(UIMgr)
_mergeExport(require(script.Visibility))
_mergeExport(require(script.Layout))
_mergeExport(require(script.RbPrice))
_mergeExport(require(script.Gradients))

return UIMgr