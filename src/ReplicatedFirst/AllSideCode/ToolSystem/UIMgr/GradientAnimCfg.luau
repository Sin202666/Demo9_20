--[[
	Module: UIMgr.GradientAnimCfg
	Description: 渐变预设名 / 别名 → 循环样式列表；由 Gradients.Anim 查询，业务勿直接改写
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	用途：
	- AddGradientColor / PlayGradientAnimForPreset 按逻辑名或 Gridient 预设名自动 Play
	- 旋转类预设名未确认前不写 Rotation 自动播，业务显式 PlayGradientAnim(..., "Rotation")

	条目：{ style: string, opts: table? }[]
	opts 透传给对应样式（ColorScroll 的 period/step/palette/colors，Rotation 的 degPerSec）

	ColorScroll 色板名见 Gradients.Anim（彩虹满 / 彩虹柔 / 彩虹柔金 / 彩虹艳 / 彩虹粉 / 红脉）。
	预制体也可设 Attribute GradientAnimPalette。

	加载：require(script.Parent.GradientAnimCfg)；业务经 Utils.UIMgr。
]]

local COLOR_SCROLL_SOFT = { style = "ColorScroll", opts = { palette = "彩虹柔" } }

local GradientAnimCfg: { [string]: { { style: string, opts: { [string]: any }? } } } = {
	["彩虹"] = { COLOR_SCROLL_SOFT },
	["彩虹-BG"] = { COLOR_SCROLL_SOFT },
	["彩虹-Text"] = { COLOR_SCROLL_SOFT },
	["5"] = { COLOR_SCROLL_SOFT },
	["5-BG"] = { COLOR_SCROLL_SOFT },
	["5-Text"] = { COLOR_SCROLL_SOFT },
	["武器边框-6"] = { COLOR_SCROLL_SOFT },
}

return GradientAnimCfg
