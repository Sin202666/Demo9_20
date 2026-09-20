--[[
	Module: UiAssets
	Description: 短视频 UI 资源解析（assetId → Image 字符串）与点赞态切图
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-14

	能力:
		- ToImage：配置值转 rbxassetid 字符串
		- ApplyButtonImage：写到按钮；若存在子层 LikeIcon / Icon（ImageLabel）则只改子层，按钮自身 Image 置空
		- ApplyLikeState：按已赞/未赞切换图

	用法:
		local UiAssets = require(...Client.UiAssets)
		UiAssets.ApplyButtonImage(btn, cfg.ImageLike, cfg.FallbackLike)
		UiAssets.ApplyLikeState(btn, liked, cfg.ImageLike, cfg.ImageLiked, cfg.FallbackLike, cfg.FallbackLiked)
]]

local UiAssets = {}

--[[
	将配置值转为 Image 可用字符串
	@param value any - number / "123" / "rbxassetid://123" / 0 / nil
	@return string - 空串表示无图
]]
function UiAssets.ToImage(value: any): string
	if value == nil or value == 0 or value == "" or value == "0" then
		return ""
	end
	if typeof(value) == "number" then
		if value <= 0 then
			return ""
		end
		return "rbxassetid://" .. tostring(math.floor(value))
	end
	if typeof(value) == "string" then
		local s = value
		if string.find(s, "rbxassetid://", 1, true) == 1 then
			return s
		end
		local n = tonumber(s)
		if n and n > 0 then
			return "rbxassetid://" .. tostring(math.floor(n))
		end
		return s
	end
	return ""
end

--[[
	查找按钮图标子层（评论行 LikeIcon；通用 Icon）
	@param btn GuiButton - 按钮
	@return ImageLabel? - 图标层
]]
local function findButtonIcon(btn: GuiButton): ImageLabel?
	local likeIcon = btn:FindFirstChild("LikeIcon")
	if likeIcon and likeIcon:IsA("ImageLabel") then
		return likeIcon
	end
	local icon = btn:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		return icon
	end
	return nil
end

--[[
	确保 ImageButton 下有文字占位 Label（ImageButton 无 Font/Text）
	@param btn ImageButton - 按钮
	@return TextLabel
]]
local function ensureFallbackLabel(btn: ImageButton): TextLabel
	local existing = btn:FindFirstChild("FallbackLabel")
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	local label = Instance.new("TextLabel")
	label.Name = "FallbackLabel"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(245, 245, 245)
	label.TextSize = 12
	label.TextScaled = false
	label.ZIndex = btn.ZIndex + 1
	label.Parent = btn
	return label
end

--[[
	应用图片；优先写子层 LikeIcon/Icon；否则 ImageButton.Image / TextButton.Text
	@param btn GuiButton - ImageButton 或 TextButton
	@param image any - 资源配置
	@param fallbackText string? - 无图占位
]]
function UiAssets.ApplyButtonImage(btn: GuiButton, image: any, fallbackText: string?)
	local uri = UiAssets.ToImage(image)
	local icon = findButtonIcon(btn)

	if icon then
		-- 有子图标层：按钮自身不显示图（评论行 LikeBtn 等）
		if btn:IsA("ImageButton") then
			btn.Image = ""
		elseif btn:IsA("TextButton") then
			btn.Text = ""
		end
		icon.Image = uri
		icon.Visible = uri ~= ""
		if btn:IsA("ImageButton") then
			local label = ensureFallbackLabel(btn)
			if uri ~= "" then
				label.Text = ""
				label.Visible = false
			else
				label.Text = fallbackText or ""
				label.Visible = true
			end
		elseif btn:IsA("TextButton") and uri == "" then
			btn.Text = fallbackText or btn.Text
		end
		return
	end

	if btn:IsA("ImageButton") then
		btn.Image = uri
		local label = ensureFallbackLabel(btn)
		if uri ~= "" then
			label.Text = ""
			label.Visible = false
		else
			label.Text = fallbackText or ""
			label.Visible = true
		end
	elseif btn:IsA("TextButton") then
		if uri ~= "" then
			btn.Text = ""
		else
			btn.Text = fallbackText or btn.Text
		end
	end
end

--[[
	按点赞态切换图片
	@param btn GuiButton - 点赞按钮
	@param liked boolean - 是否已赞
	@param imageLike any - 未赞图
	@param imageLiked any - 已赞图
	@param fallbackLike string? - 未赞文字
	@param fallbackLiked string? - 已赞文字
]]
function UiAssets.ApplyLikeState(
	btn: GuiButton,
	liked: boolean,
	imageLike: any,
	imageLiked: any,
	fallbackLike: string?,
	fallbackLiked: string?
)
	if liked then
		UiAssets.ApplyButtonImage(btn, imageLiked, fallbackLiked or "Liked")
	else
		UiAssets.ApplyButtonImage(btn, imageLike, fallbackLike or "Like")
	end
end

return UiAssets
