--[[
	Module: UIMgr.Gradients.Rarity
	Description: 稀有度（xyd）标签/边框/背景与人种配色（由 Gradients/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-09-01

	功能：
	- getXydName / setXydLabel / SetItemXyd / SetHeroXyd / SetStroke / addGradients
	- GetXydColor / GetXydColorHex / NormalizeXyd / GetRarityBgPatternColor / GetXydPassBgStyle
	- SetHumanRaceColor / GetRaceByxyd / GetPotionScrollInnerGradientByXyd
	- addGradients 克隆后 Prepare，并按 xyd PlayGradientAnimForPreset

	与 Core：AddGradientColor 等经 Gradients 表运行时查找；过渡走 Core internals。
	历史 camelCase（getXydName / setXydLabel / addGradients）不改名。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local Copy = Utils.Copy
local EnumMgr = Utils.EnumMgr
local TranslationHelper = Utils.TranslationHelper
local SequenceModule = Utils.SequenceManager

local XYD_MAX = 6

local RARITY_NAMES = {
	"普通", "精良", "稀有", "史诗", "传说", "神话",
}

local XYD_MAIN_COLORS: { [number]: Color3 } = {
	[1] = Color3.fromHex("9F9F9F"),
	[2] = Color3.fromHex("85D887"),
	[3] = Color3.fromHex("858DD8"),
	[4] = Color3.fromHex("9E46DB"),
	[5] = Color3.fromHex("DB9A46"),
	[6] = Color3.fromHex("D95A5A"),
}

local XYD_BG_PATTERN_COLORS: { [number]: Color3 } = {
	[1] = Color3.fromHex("3d3d3d"),
	[2] = Color3.fromHex("1c3b20"),
	[3] = Color3.fromHex("142a40"),
	[4] = Color3.fromHex("35233a"),
	[5] = Color3.fromHex("52341d"),
	[6] = Color3.fromHex("562727"),
}

local XYD_PASS_BG_STYLE: { [number]: {
	Enter: { Color: ColorSequence },
	Normal: { Color: ColorSequence },
	UIStroke: { Color: Color3 },
	BGIcon: { ImageColor3: Color3 },
	Effect: { ImageColor3: Color3 },
} } = {
	[1] = {
		Enter = { Color = ColorSequence.new(Color3.fromHex("#454545"), Color3.fromHex("#01050B")) },
		Normal = { Color = ColorSequence.new(Color3.fromHex("#303030"), Color3.fromHex("#01050B")) },
		UIStroke = { Color = Color3.fromHex("#6F6F6F") },
		BGIcon = { ImageColor3 = Color3.fromHex("#9F9F9F") },
		Effect = { ImageColor3 = Color3.fromHex("#9F9F9F") },
	},
	[2] = {
		Enter = { Color = ColorSequence.new(Color3.fromHex("#355C2F"), Color3.fromHex("#01050B")) },
		Normal = { Color = ColorSequence.new(Color3.fromHex("#243822"), Color3.fromHex("#01050B")) },
		UIStroke = { Color = Color3.fromHex("#517347") },
		BGIcon = { ImageColor3 = Color3.fromHex("#85D887") },
		Effect = { ImageColor3 = Color3.fromHex("#85D887") },
	},
	[3] = {
		Enter = { Color = ColorSequence.new(Color3.fromHex("#214267"), Color3.fromHex("#01050B")) },
		Normal = { Color = ColorSequence.new(Color3.fromHex("#192A3C"), Color3.fromHex("#01050B")) },
		UIStroke = { Color = Color3.fromHex("#234E8F") },
		BGIcon = { ImageColor3 = Color3.fromHex("#3c6fd7") },
		Effect = { ImageColor3 = Color3.fromHex("#00d8ff") },
	},
	[4] = {
		Enter = { Color = ColorSequence.new(Color3.fromHex("#592F5F"), Color3.fromHex("#01050B")) },
		Normal = { Color = ColorSequence.new(Color3.fromHex("#503454"), Color3.fromHex("#01050B")) },
		UIStroke = { Color = Color3.fromHex("#8D529C") },
		BGIcon = { ImageColor3 = Color3.fromHex("#9E3CD7") },
		Effect = { ImageColor3 = Color3.fromHex("#9E3CD7") },
	},
	[5] = {
		Enter = { Color = ColorSequence.new(Color3.fromHex("#573B1D"), Color3.fromHex("#01050B")) },
		Normal = { Color = ColorSequence.new(Color3.fromHex("#3C2B19"), Color3.fromHex("#01050B")) },
		UIStroke = { Color = Color3.fromHex("#8F5B23") },
		BGIcon = { ImageColor3 = Color3.fromHex("#d7853c") },
		Effect = { ImageColor3 = Color3.fromHex("#d7853c") },
	},
	[6] = {
		Enter = { Color = ColorSequence.new(Color3.fromHex("#562727"), Color3.fromHex("#01050B")) },
		Normal = { Color = ColorSequence.new(Color3.fromHex("#3A1818"), Color3.fromHex("#01050B")) },
		UIStroke = { Color = Color3.fromHex("#8F4040") },
		BGIcon = { ImageColor3 = Color3.fromHex("#D95A5A") },
		Effect = { ImageColor3 = Color3.fromHex("#D95A5A") },
	},
}

local XYD_HEXCOLOR: { [number]: string } = {
	[1] = "#9F9F9F",
	[2] = "#85D887",
	[3] = "#858DD8",
	[4] = "#9E46DB",
	[5] = "#DB9A46",
	[6] = "#D95A5A",
}

local POTION_SCROLL_INNER_GRADIENT_SLOTS = 6
local HUMAN_RACE_GRADIENT_LERP = 0.18
local XYD_LABEL_STROKE_THICKNESS = 1
local GRADIENT_TEXT_STROKE_THICKNESS = 2
local HUMAN_RACE_GRADIENT_ROTATION = 90
local XYDEFFECT_FRAME_NAME = "框特效"
local XYDEFFECT_INNER_NAME = "框特效"
local XYDEFFECT_SEQUENCE_RAINBOW = "彩虹框"
local XYDEFFECT_SEQUENCE_SECRET = "秘密框"
local XYDEFFECT_SECONDS_PER_FRAME = 0.08

--[[
	将 xyd 夹取到 1～XYD_MAX
	@param xyd number? - 原始稀有度，无效时视为 1
	@return number - 夹取后的整数稀有度
]]
local function _normalizeXyd(xyd: number?): number
	local n = math.floor(tonumber(xyd) or 1)
	if n < 1 then
		n = 1
	elseif n > XYD_MAX then
		n = XYD_MAX
	end
	return n
end

--[[
	挂载稀有度 API 到 Gradients 表。
	@param Gradients table - 与 init 同一份导出表（AddGradientColor 等已由 Core 挂上）
	@param Core table - finishGradientTransition / 资源 Folder
	@return () - 无返回值
]]
return function(Gradients, Core)
	local XydColorFolder = Core.XydColorFolder
	local HeroFrameFolder = Core.HeroFrameFolder
	local XydEffectTemplate = Core.XydEffectTemplate
	local AllGridientsFolder = Core.AllGridientsFolder
	local _resetParentWhiteBase = Core.resetParentWhiteBase

	--[[
		刷新英雄框稀有度序列特效（与 UIMgr 共用框特效模板）
		同控件重播由 SequenceManager 停旧播；控件 Destroy/出树由 Lifecycle 自动停作兜底。
		@param frame Frame - 英雄 UI 框架
		@param xyd number - 稀有度值
	]]
	local function _refreshXydEffect(frame: Frame, xyd: number)
		local oriXyd = frame:GetAttribute("xydEffect")
		if oriXyd == xyd then
			return
		end

		if not frame:FindFirstChild(XYDEFFECT_FRAME_NAME) then
			if XydEffectTemplate then
				local new = XydEffectTemplate:Clone()
				new.Parent = frame
			end
		end

		local effectFrame = frame:FindFirstChild(XYDEFFECT_FRAME_NAME)
		if not effectFrame then
			return
		end

		local innerEffect = effectFrame:FindFirstChild(XYDEFFECT_INNER_NAME)
		if xyd == EnumMgr.Rare.Xyd4 then
			effectFrame.Visible = true
			if innerEffect then
				local ok, err, handle = SequenceModule:PlaySequence(innerEffect, XYDEFFECT_SEQUENCE_RAINBOW, {
					secondsPerFrame = XYDEFFECT_SECONDS_PER_FRAME,
					loop = true,
					presentMode = SequenceModule.PresentMode.CloneAll,
				})
				if not ok or not handle then
					Log.warn("[Gradients] 彩虹框序列播放失败:", err)
					effectFrame.Visible = false
					return
				end
			end
		elseif xyd == EnumMgr.Rare.Xyd5 or xyd == EnumMgr.Rare.Xyd6 then
			effectFrame.Visible = true
			if innerEffect then
				local ok, err, handle = SequenceModule:PlaySequence(innerEffect, XYDEFFECT_SEQUENCE_SECRET, {
					secondsPerFrame = XYDEFFECT_SECONDS_PER_FRAME,
					loop = true,
					presentMode = SequenceModule.PresentMode.CloneAll,
				})
				if not ok or not handle then
					Log.warn("[Gradients] 秘密框序列播放失败:", err)
					effectFrame.Visible = false
					return
				end
			end
		else
			effectFrame.Visible = false
			if innerEffect then
				-- 无跨次 handle 缓存；同 label 停播用 StopSequence（Destroy 由 Lifecycle 兜底）
				SequenceModule:StopSequence(innerEffect)
			end
		end

		frame:SetAttribute("xydEffect", xyd)
	end

	--[[
		将稀有度中文名写入文本。Key 必须是调用处字面量，供本地化插件抽取（本地化 §6.2.1）。
		@param text TextLabel - 目标文本
		@param xyd number - 稀有度档位，越界按 1～XYD_MAX 夹取
		@return () - 无返回值
	]]
	local function _applyXydDisplayName(text: TextLabel, xyd: number)
		local n = _normalizeXyd(xyd)
		if n == 1 then
			TranslationHelper.SetText(text, "普通")
		elseif n == 2 then
			TranslationHelper.SetText(text, "精良")
		elseif n == 3 then
			TranslationHelper.SetText(text, "稀有")
		elseif n == 4 then
			TranslationHelper.SetText(text, "史诗")
		elseif n == 5 then
			TranslationHelper.SetText(text, "传说")
		else
			TranslationHelper.SetText(text, "神话")
		end
	end

	--[[
		获取稀有度名称（本地化 Key 字符串，不直接写 UI；展示请用 setXydLabel）
		@param xyd number - 稀有度值
		@return string? - 对应档位 Key（普通/精良/稀有/史诗/传说/神话）；越界 nil
	]]
	function Gradients.getXydName(xyd: number): string?
		return RARITY_NAMES[tonumber(xyd)]
	end

	--[[
		设置稀有度标签（文本和渐变）
		文字 UIGradient 与 AddGradientColor(xyd, text, true) 相同（Gridient / *-Text）
		@param text TextLabel - 文本标签
		@param xyd number - 稀有度值
		@param _isStroke boolean? - 是否按稀有度添加 UIStroke（默认 true；AddGradientColor 不含描边）
		@param useColorTransition boolean? - 是否对 UIGradient 做旧色→新色过渡（默认 true）
		@return () - 无返回值
	]]
	function Gradients.setXydLabel(text: TextLabel, xyd: number, _isStroke: boolean?, useColorTransition: boolean?)
		if not text:IsA("TextLabel") then
			return
		end

		_applyXydDisplayName(text, xyd)

		_isStroke = _isStroke ~= false

		Gradients.AddGradientColor(tostring(xyd), text, true, nil, useColorTransition)

		if _isStroke then
			for _, v in text:GetChildren() do
				if v:IsA("UIStroke") then
					v:Destroy()
				end
			end
			local colorFolder: Folder? = Gradients.GetXydColor(xyd)
			if colorFolder then
				local newUIStroke: UIStroke = Instance.new("UIStroke")
				newUIStroke.Thickness = XYD_LABEL_STROKE_THICKNESS
				newUIStroke.Color = colorFolder:FindFirstChild("Board") and colorFolder.Board.Value or Color3.new(1, 1, 1)
				newUIStroke.Parent = text
			end
		end
	end

	--[[
		设置物品稀有度
		@param _frame Frame - 物品框架
		@param _xyd number - 稀有度值
		@return () - 无返回值
	]]
	function Gradients.SetItemXyd(_frame: Frame, _xyd: number)
		local bg = _frame:FindFirstChild("BG")
		if bg then
			Gradients.AddGradientColor(tostring(_xyd) .. "-BG", bg)
		end

		Gradients.AddGradientColor(_xyd, _frame)

		local xydStr = _frame:FindFirstChild("xydStr")
		if xydStr and xydStr:IsA("TextLabel") then
			_applyXydDisplayName(xydStr, _xyd)
			Gradients.AddGradientColor(_xyd, xydStr)
		end
	end

	--[[
		设置英雄稀有度
		@param _frame Frame - 英雄框架
		@param _xyd number - 稀有度值
		@return () - 无返回值
	]]
	function Gradients.SetHeroXyd(_frame: Frame, _xyd: number)
		local oriXyd = _frame:GetAttribute("OriXyd")
		if oriXyd == _xyd then
			return
		end

		-- 设置背景渐变
		local BG: Frame = _frame:FindFirstChild("BG")
		if BG then
			local BGicon = BG:FindFirstChild("Icon")
			if BGicon then
				local gradient = BGicon:FindFirstChildOfClass("UIGradient")
				if gradient then
					gradient:Destroy()
				end

				local heroXydFolder = HeroFrameFolder and HeroFrameFolder:FindFirstChild(tostring(_xyd))
				local bgTemplate = heroXydFolder and heroXydFolder:FindFirstChild("BG")
				if bgTemplate then
					local new = bgTemplate:Clone()
					new.Parent = BGicon
					new.Enabled = true
				end
			end
		end

		-- 设置描边渐变
		local Stroke: Frame = _frame:FindFirstChild("Stroke")
		if Stroke then
			local Strokeicon = Stroke:FindFirstChild("Icon")
			if Strokeicon then
				local gradient = Strokeicon:FindFirstChildOfClass("UIGradient")
				if gradient then
					gradient:Destroy()
				end

				local heroXydFolder = HeroFrameFolder and HeroFrameFolder:FindFirstChild(tostring(_xyd))
				local strokeTemplate = heroXydFolder and heroXydFolder:FindFirstChild("Stroke")
				if strokeTemplate then
					local new = strokeTemplate:Clone()
					new.Parent = Strokeicon
					new.Enabled = true
				end
			end
		end

		_refreshXydEffect(_frame, _xyd)
		_frame:SetAttribute("OriXyd", _xyd)
	end

	--[[
		设置描边
		@param _frame Frame - 框架
		@param xyd number - 稀有度值
		@param _stroke number? - 描边宽度（有值时按 2 倍缩小 BG）
		@return () - 无返回值
	]]
	function Gradients.SetStroke(_frame: Frame, xyd: number, _stroke: number?)
		local strokeFrame = _frame:FindFirstChild("Stroke")
		if strokeFrame then
			Gradients.AddGradientColor(xyd, strokeFrame)
		end

		local bgFrame = _frame:FindFirstChild("BG")
		if bgFrame and bgFrame:IsA("GuiObject") then
			Gradients.AddGradientColor(tostring(xyd) .. "-BG", bgFrame)
			if _stroke then
				local inset = _stroke * 2
				bgFrame.Size = UDim2.new(1, -inset, 1, -inset)
			end
		end
	end

	--[[
		获取稀有度主色 HEX 字符串（与 XYD_MAIN_COLORS 同源）
		@param xyd number? - 稀有度值，越界按 1～XYD_MAX 夹取
		@return string? - 形如 "#9F9F9F" 的 HEX，无配置时 nil
	]]
	function Gradients.GetXydColorHex(_xyd: number?): string?
		return XYD_HEXCOLOR[_normalizeXyd(_xyd)]
	end

	--[[
		获取稀有度颜色文件夹（Assets 活引用，只读；勿改子 Color3Value）
		@param _xyd number? - 稀有度值；nil 时取档位 "0"
		@return Folder? - 颜色文件夹；资源未就绪或档位不存在时 nil
	]]
	function Gradients.GetXydColor(_xyd: number?): Folder?
		if not XydColorFolder then
			return nil
		end
		if not _xyd then
			return XydColorFolder:FindFirstChild("0")::Folder?
		end

		local colorFolder = XydColorFolder:FindFirstChild(tostring(_xyd))
		return colorFolder::Folder?
	end

	--[[
		材料选择界面 _ScrollPotion 中 Potion.BG.内圆：按药水配置 xyd（稀有度）选用「药水temp背景渐变1」～「药水temp背景渐变6」；
		xyd≤0 视为 1；xyd>6 时复用渐变 6（与资源数量一致）。
		@param xyd number? - 药水 cfg.xyd
		@return UIGradient? - 克隆的 UIGradient，未找到预设时 nil
	]]
	function Gradients.GetPotionScrollInnerGradientByXyd(xyd: number?): UIGradient?
		local n = math.floor(tonumber(xyd) or 1)
		if n < 1 then
			n = 1
		end
		local idx = n
		if idx > POTION_SCROLL_INNER_GRADIENT_SLOTS then
			idx = POTION_SCROLL_INNER_GRADIENT_SLOTS
		end
		return Gradients.GetGradientColor("药水temp背景渐变" .. tostring(idx))
	end

	--[[
		为文本添加渐变
		@param text TextLabel - 文本标签
		@param xyd number - 稀有度值
		@param _isStroke boolean? - 是否添加描边（默认 true）
		@return () - 无返回值
	]]
	function Gradients.addGradients(text: TextLabel, xyd: number, _isStroke: boolean?)
		if not text:IsA("TextLabel") then
			return
		end

		_isStroke = _isStroke ~= false -- 默认为true

		text.TextColor3 = Color3.new(1, 1, 1)

		Gradients.StopGradientAnim(text)

		-- 清理旧的渐变和描边
		for _, v in pairs(text:GetChildren()) do
			if v.ClassName == "UIGradient" then
				v:Destroy()
			end

			if _isStroke and v.ClassName == "UIStroke" then
				v:Destroy()
			end
		end

		-- 添加新的渐变和描边
		local colorFolder: Folder? = Gradients.GetXydColor(xyd)
		if colorFolder then
			if _isStroke then
				local newUIStroke: UIStroke = Instance.new("UIStroke")
				newUIStroke.Thickness = GRADIENT_TEXT_STROKE_THICKNESS
				newUIStroke.Color = colorFolder:FindFirstChild("Board") and colorFolder.Board.Value or Color3.new(1, 1, 1)
				newUIStroke.Parent = text
			end

			local UIGradient: UIGradient? = colorFolder:FindFirstChildOfClass("UIGradient")
			if UIGradient then
				local newUIGradient = UIGradient:Clone()
				Gradients.PrepareClonedGradient(newUIGradient)
				newUIGradient.Parent = text
				Gradients.PlayGradientAnimForPreset(newUIGradient, tostring(xyd))
			end
		end
	end

	--[[
		将 xyd 夹取到 1～XYD_MAX（对外暴露，供各模块统一规范化）
		@param xyd number? - 原始稀有度
		@return number - 夹取后的整数 1～XYD_MAX
	]]
	function Gradients.NormalizeXyd(xyd: number?): number
		return _normalizeXyd(xyd)
	end

	--[[
		获取 Bg亮底纹染色（背包/商店/图鉴等 ImageLabel.ImageColor3）
		@param xyd number? - 稀有度值
		@return Color3 - 深色底纹，越界时回退到 1 档
	]]
	function Gradients.GetRarityBgPatternColor(xyd: number?): Color3
		local n = _normalizeXyd(xyd)
		return XYD_BG_PATTERN_COLORS[n] or XYD_BG_PATTERN_COLORS[1]
	end

	--[[
		获取 PassItem / SellTemp 稀有度 BG 样式（EventShop、RandomShop、UIMgr 共用）
		@param xyd number? - 稀有度值
		@return table? - Enter/Normal/UIStroke/BGIcon/Effect 样式表深拷贝，无档位时 nil
	]]
	function Gradients.GetXydPassBgStyle(xyd: number?): {
		Enter: { Color: ColorSequence },
		Normal: { Color: ColorSequence },
		UIStroke: { Color: Color3 },
		BGIcon: { ImageColor3: Color3 },
		Effect: { ImageColor3: Color3 },
	}?
		local n = _normalizeXyd(xyd)
		local style = XYD_PASS_BG_STYLE[n]
		if not style then
			return nil
		end
		return Copy.deepCopy(style)
	end

	--[[
		获取稀有档位主色（与 XYD_MAIN_COLORS 一致）
		@param xyd number - 稀有度值，越界按 1～XYD_MAX 夹取
		@return Color3? - 主色，无配置时 nil
	]]
	function Gradients.GetColor3ByXYD(xyd: number): Color3?
		local n = _normalizeXyd(xyd)
		return XYD_MAIN_COLORS[n]
	end

	--[[
		人种/种族界面：按策划给定档位的「主色」挂 UIGradient（与白底文字/图标相乘）
		@param target Instance? - TextLabel/Frame/ImageLabel 等 GuiObject
		@param xyd number - 稀有度档位
		@return () - 无返回值
	]]
	function Gradients.SetHumanRaceColor(target: Instance?, xyd: number)
		if not target or not target:IsA("GuiObject") then
			return
		end
		local n = _normalizeXyd(xyd)
		Gradients.RemoveGradientColor(target)
		local c0 = XYD_MAIN_COLORS[n]
		if not c0 then
			return
		end
		local c1 = c0:Lerp(Color3.new(1, 1, 1), HUMAN_RACE_GRADIENT_LERP)
		_resetParentWhiteBase(target)
		local grad = Instance.new("UIGradient")
		grad.Name = "UIGradient"
		grad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, c0),
			ColorSequenceKeypoint.new(1, c1),
		})
		grad.Rotation = HUMAN_RACE_GRADIENT_ROTATION
		grad.Parent = target
		target:SetAttribute("xyd", tostring(n))
	end

	--[[
		人种界面：按 xyd 挂载 HumanRace 文件夹下「物品背景渐变N」预设（历史 Get 前缀，实际为写入）
		@param frame Frame? - 目标框架
		@param xyd number? - 稀有度值
		@return () - 无返回值
	]]
	function Gradients.GetRaceByxyd(frame: Frame?, xyd: number?)
		if not frame then
			return
		end

		for _, child in ipairs(frame:GetChildren()) do
			if child:IsA("UIGradient") then
				child:Destroy()
			end
		end

		local gradientName = "物品背景渐变" .. tostring(xyd)
		local humanRaceFolder = AllGridientsFolder and AllGridientsFolder:FindFirstChild("HumanRace")
		if not humanRaceFolder then
			return
		end
		local template = humanRaceFolder:FindFirstChild(gradientName)
		if not template then
			return
		end
		local gradient = template:Clone()
		gradient.Parent = frame
	end
end
