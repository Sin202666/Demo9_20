--[[
	Module: UIMgr.GradientCfg
	Description: 渐变别名表（逻辑名 ≠ Gridient 预设名时才登记）；由 Gradients 查询，勿直接改写
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	只收「键 ≠ 资源名」：GetGradientColor 先按传入名 FindFirstChild，命中则不必查本表。
	资源就叫 橙 / 彩虹 / GameTime 时直接 AddGradientColor("橙")，不要在这里自映射。

	加载：require(script.Parent.GradientCfg)；业务经 Utils.UIMgr / Gradients API。
]]

local GradientCfg = {}

-- 文本后缀落到无 -Text 的预设
GradientCfg["彩虹-Text"] = "彩虹"

-- 排行榜（RankConfig.RANK_TITLE_GRADIENT / RANK_DEFS.gradient）
GradientCfg["排行榜标题"] = "4"
GradientCfg["排行榜标题-Text"] = "5"
GradientCfg["排行榜-金币"] = "5"
GradientCfg["排行榜-罗宝"] = "2"
GradientCfg["排行榜-时长"] = "3"

-- 稀有度数字 → 预设名
GradientCfg["1"] = "白"
GradientCfg["2"] = "蓝"
GradientCfg["3"] = "紫"
GradientCfg["4"] = "橙"
GradientCfg["5"] = "彩虹"
GradientCfg["6"] = "红稀有度"
GradientCfg["1-BG"] = "白-BG"
GradientCfg["2-BG"] = "蓝-BG"
GradientCfg["3-BG"] = "紫-BG"
GradientCfg["4-BG"] = "橙-BG"
GradientCfg["5-BG"] = "彩虹-BG"
GradientCfg["6-BG"] = "红稀有度-BG"

GradientCfg["胜利结算-首次"] = "紫渐浅"
GradientCfg["胜利结算-非首次"] = "蓝渐浅"

GradientCfg["每日奖励-橙-Stroke"] = "橙"
GradientCfg["每日奖励-橙-BG"] = "橙-BG"
GradientCfg["每日奖励-绿深蓝-Stroke"] = "绿深蓝"
GradientCfg["每日奖励-绿深蓝-BG"] = "绿深蓝-BG"
GradientCfg["每日奖励-蓝-Stroke"] = "蓝"
GradientCfg["每日奖励-蓝-BG"] = "蓝-BG"
GradientCfg["每日奖励-红-Stroke"] = "红"
GradientCfg["每日奖励-红-BG"] = "红-BG"
GradientCfg["每日奖励-紫-Stroke"] = "紫"
GradientCfg["每日奖励-紫-BG"] = "紫-BG"
GradientCfg["每日奖励-绿-Stroke"] = "绿"
GradientCfg["每日奖励-绿-BG"] = "绿-BG"
GradientCfg["每日奖励-暗紫-Stroke"] = "暗紫"
GradientCfg["每日奖励-暗紫-BG"] = "暗紫-BG"

-- 武器边框
GradientCfg["武器边框-1"] = "白"
GradientCfg["武器边框-2"] = "蓝"
GradientCfg["武器边框-3"] = "紫"
GradientCfg["武器边框-4"] = "橙"
GradientCfg["武器边框-5"] = "红"
GradientCfg["武器边框-6"] = "彩虹"
GradientCfg["武器边框-7"] = "暗紫"

return GradientCfg
