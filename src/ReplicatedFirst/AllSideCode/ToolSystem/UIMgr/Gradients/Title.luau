--[[
	Module: UIMgr.Gradients.Title
	Description: 称号 TextLabel 模板套用（由 Gradients/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-09-01

	功能：
	- ApplyTitleTextFromTemplate / ApplyTitleTextByTitleId
	- 套用前结束 Core 上该控件的 UIGradient 过渡，并 Stop 循环表现
	- 克隆后 PrepareClonedGradient，再按模板名 PlayGradientAnimForPreset
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local EnumMgr = Utils.EnumMgr
local CfgFind = Utils.CfgFind

--[[
	挂载称号 API 到 Gradients 表。
	@param Gradients table - 与 init 同一份导出表
	@param Core table - finishGradientTransition / TitleTemplateFolder
	@return () - 无返回值
]]
return function(Gradients, Core)
	local TitleTemplateFolder = Core.TitleTemplateFolder
	local _finishGradientTransition = Core.finishGradientTransition

	--[[
		按 ModelRes.Title 下与 cfg.Model 同名的 TextLabel 模板，为目标文本克隆 UIGradient（可选 UIStroke）。
		templateName 为空或找不到模板时：移除上述子物体并将 TextColor3 置白（便于后续不配渐变时的统一基底）。
		@param text TextLabel - 目标称号文本
		@param templateName string? - 称号配置 Model 字段，与 Assets/ModelRes/Title 下子级同名
		@param applyStroke boolean? - 是否同步模板上的 UIStroke（默认 true）
		@return () - 无返回值
	]]
	function Gradients.ApplyTitleTextFromTemplate(text: TextLabel, templateName: string?, applyStroke: boolean?)
		if not text or not text:IsA("TextLabel") then
			return
		end
		local useStroke = applyStroke ~= false

		_finishGradientTransition(text)
		Gradients.StopGradientAnim(text)

		for _, ch in text:GetChildren() do
			if ch:IsA("UIGradient") or (useStroke and ch:IsA("UIStroke")) then
				ch:Destroy()
			end
		end

		local nameStr = templateName and tostring(templateName) or ""
		if nameStr == "" then
			text.TextColor3 = Color3.new(1, 1, 1)
			text:SetAttribute("titleTemplate", nil)
			return
		end

		local folder = TitleTemplateFolder
		if not folder then
			text.TextColor3 = Color3.new(1, 1, 1)
			return
		end

		local template: Instance? = folder:FindFirstChild(nameStr)
		if not template or not template:IsA("TextLabel") then
			text.TextColor3 = Color3.new(1, 1, 1)
			text:SetAttribute("titleTemplate", nil)
			return
		end

		text.TextColor3 = Color3.new(1, 1, 1)

		local srcGrad: UIGradient? = template:FindFirstChildOfClass("UIGradient")
		if srcGrad then
			local g = srcGrad:Clone()
			Gradients.PrepareClonedGradient(g)
			g.Parent = text
			Gradients.PlayGradientAnimForPreset(g, nameStr)
		end
		if useStroke then
			local srcStroke: UIStroke? = template:FindFirstChildOfClass("UIStroke")
			if srcStroke then
				local s = srcStroke:Clone()
				s.Parent = text
			end
		end
		text:SetAttribute("titleTemplate", nameStr)
	end

	--[[
		根据称号道具配置 id（ItemType.Title）解析 Model 并套用 ApplyTitleTextFromTemplate；id≤0 为卸下/无
		@param text TextLabel - 目标文本
		@param titleId number? - 称号道具配置 id
		@param applyStroke boolean? - 是否同步模板 UIStroke（默认 true）
		@return () - 无返回值
	]]
	function Gradients.ApplyTitleTextByTitleId(text: TextLabel, titleId: number?, applyStroke: boolean?)
		local id = tonumber(titleId) or 0
		if id <= 0 then
			Gradients.ApplyTitleTextFromTemplate(text, nil, applyStroke)
			return
		end
		local cfg = CfgFind.FindCfgByID(id, EnumMgr.ItemType.Title)
		local model = cfg and cfg.Model
		Gradients.ApplyTitleTextFromTemplate(text, model and tostring(model) or nil, applyStroke)
	end
end
