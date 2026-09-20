--[[
	Module: UIMgr/Gradients
	Description: UIMgr 子模块 — UI 渐变与稀有度配色（由 init 合并导出至 Utils.UIMgr）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- 稀有度（xyd）标签/边框/背景渐变与主色查询
	- 通用渐变类型挂载（Gridient 预设 + GradientCfg 别名）
	- 元素类型渐变、Color3 丝滑过渡、称号 TextLabel 模板套用
	- PassItem / 人种界面等专用配色 API
	- UIGradient 循环表现（ColorScroll / Rotation，可 RegisterGradientAnimStyle）

	子模块（业务只经 Utils.UIMgr，不要直接 require）：
	- Anim.luau     循环表现、样式注册
	- Core.luau     UIGradient/Color3 过渡、AddGradientColor
	- Rarity.luau   稀有度 xyd
	- Element.luau  元素类型
	- Title.luau    称号模板
	- GradientAnimCfg.luau 循环自动播映射（与 GradientCfg 同级）

	资源路径（ReplicatedStorage/Assets/AllGridients）：
	- Gridient、RarityGridient、ElementGradients、HumanRace、英雄框
	- 框特效模板仍在 UIMgr 目录下

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local UIMgr = Utils.UIMgr

	示例：
		UIMgr.setXydLabel(textLabel, 5)
		UIMgr.AddGradientColor("蓝", frame)
		UIMgr.AddGradientColor("彩虹", frame)
		UIMgr.PlayGradientAnim(gradient, "Rotation", { degPerSec = 50 })
		UIMgr.ApplyTitleTextByTitleId(titleLabel, titleItemId)

	命名说明：getXydName / setXydLabel / addGradients 为历史 camelCase API，新接口请用 Get/Set/Add 前缀 PascalCase。
]]

local Gradients = {}

require(script.Anim)(Gradients)
local Core = require(script.Core)(Gradients)
require(script.Rarity)(Gradients, Core)
require(script.Element)(Gradients, Core)
require(script.Title)(Gradients, Core)

return Gradients
