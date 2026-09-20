--[[
	Module: GmEmailRewardSlots
	Description: GM 发邮件面板奖励格展示（普通物品 / 称号 / 通行证图标）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-18

	功能：
	- 普通物品走 UIMgr.SetAward
	- 称号：ZhName 翻译 + 渐变（titleConf 无 Icon）
	- 通行证：gamepassitemConf 名称 + 商城 Icon（OnlyTag）；发放仍按物品入包，此处仅预览

	加载方式：require(script.GmEmailRewardSlots)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local TranslationHelper = Utils.TranslationHelper
local UIMgr = Utils.UIMgr

-- ========================================
-- 模块定义
-- ========================================
local GmEmailRewardSlots = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	设置 ImageLabel/ImageButton 的图片（支持 rbxasset / 数字 assetId）

	@param imageLabel ImageLabel | ImageButton - 目标图片控件
	@param image any - 资源 id 或 rbxasset 字符串；空/0 则清空
	@return nil
]]
local function _setImage(imageLabel: ImageLabel | ImageButton, image: any)
	if not imageLabel or (not imageLabel:IsA("ImageLabel") and not imageLabel:IsA("ImageButton")) then
		return
	end
	if image == nil then
		imageLabel.Image = ""
		return
	end
	local imageStr = tostring(image)
	if imageStr == "" or imageStr == "0" then
		imageLabel.Image = ""
		return
	end
	if string.find(imageStr, "rbxasset", 1, true) then
		imageLabel.Image = imageStr
		return
	end
	local num = tonumber(imageStr)
	if num and num > 0 then
		imageLabel.Image = "rbxassetid://" .. imageStr
		return
	end
	imageLabel.Image = ""
end

--[[
	解析奖励格 ZhName 文本节点（与 UIMgr.SetAward 一致）

	@param frame GuiObject - 奖励格
	@return TextLabel? - 名称标签
]]
local function _findAwardZhNameLabel(frame: GuiObject): TextLabel?
	local zhName = frame:FindFirstChild("ZhName")
	if zhName and zhName:IsA("TextLabel") then
		return zhName
	end
	if zhName then
		return zhName:FindFirstChildWhichIsA("TextLabel", true)
	end
	return nil
end

--[[
	是否为称号配置 ID

	@param itemId any - 奖励 ID
	@return boolean - true 表示 titleConf 命中
]]
local function _isTitleRewardItem(itemId: any): boolean
	itemId = tonumber(itemId)
	if not itemId or itemId <= 0 then
		return false
	end
	return CfgFind.FindCfgByID(itemId, EnumMgr.ItemType.Title) ~= nil
end

--[[
	是否为通行证配置 ID（预览用；发放仍入包）

	@param itemId any - 奖励 ID
	@return boolean - true 表示 gamepassitemConf 命中
]]
local function _isGamePassRewardItem(itemId: any): boolean
	itemId = tonumber(itemId)
	if not itemId or itemId <= 0 then
		return false
	end
	return CfgFind.FindCfgByID(itemId, EnumMgr.ItemType.GamePass) ~= nil
end

--[[
	称号奖励格：ZhName 翻译键 + 称号渐变（不走 SetAward）

	@param frame Frame - 奖励格
	@param itemId number - 称号 ID
	@return nil
]]
local function _applyTitleRewardSlot(frame: Frame, itemId: number)
	local titleCfg = CfgFind.FindCfgByID(itemId, EnumMgr.ItemType.Title)
	local nameText = _findAwardZhNameLabel(frame)
	if nameText and titleCfg and titleCfg.ZhName then
		nameText.Visible = true
		TranslationHelper.SetText(nameText, titleCfg.ZhName)
		UIMgr.ApplyTitleTextByTitleId(nameText, itemId)
	end
	local zhNameRoot = frame:FindFirstChild("ZhName")
	if zhNameRoot and zhNameRoot:IsA("GuiObject") and zhNameRoot ~= nameText then
		zhNameRoot.Visible = true
	end
	local viewport = frame:FindFirstChild("ViewportFrame")
	if viewport and viewport:IsA("GuiObject") then
		viewport.Visible = false
	end
	local icon = frame:FindFirstChild("Icon")
	if icon and icon:IsA("GuiObject") then
		icon.Visible = false
	end
	local countLabel = frame:FindFirstChild("Count")
	if countLabel and countLabel:IsA("GuiObject") then
		countLabel.Visible = false
	end
end

--[[
	通行证奖励格：gamepassitemConf 名称 + 商城 Icon（OnlyTag）

	@param frame Frame - 奖励格
	@param itemId number - 通行证物品 ID
	@param count number - 数量（>1 时显示）
	@return nil
]]
local function _applyGamePassRewardSlot(frame: Frame, itemId: number, count: number)
	local passCfg = CfgFind.FindCfgByID(itemId, EnumMgr.ItemType.GamePass)
	if not passCfg then
		return
	end

	local nameText = _findAwardZhNameLabel(frame)
	if nameText and passCfg.ZhName then
		nameText.Visible = true
		TranslationHelper.SetText(nameText, passCfg.ZhName)
		local colorKey = passCfg.ColorStr
		if type(colorKey) == "string" and colorKey ~= "" then
			UIMgr.AddGradientColor(colorKey, nameText, true)
		elseif passCfg.xyd then
			UIMgr.AddGradientColor(tostring(passCfg.xyd), nameText, true)
		end
	end
	local zhNameRoot = frame:FindFirstChild("ZhName")
	if zhNameRoot and zhNameRoot:IsA("GuiObject") and zhNameRoot ~= nameText then
		zhNameRoot.Visible = true
	end

	local iconUrl = ""
	local passIcon = passCfg.Icon
	if passIcon and tostring(passIcon) ~= "" and tostring(passIcon) ~= "0" then
		iconUrl = tostring(passIcon)
	end
	if iconUrl == "" and passCfg.OnlyTag then
		local shopCfg = CfgFind.FindCfgByOnlyTag(passCfg.OnlyTag)
		if shopCfg and shopCfg.Icon then
			local shopIcon = tostring(shopCfg.Icon)
			if shopIcon ~= "" and shopIcon ~= "0" then
				iconUrl = shopIcon
			end
		end
	end

	local icon = frame:FindFirstChild("Icon")
	local viewport = frame:FindFirstChild("ViewportFrame")
	if iconUrl ~= "" and icon and icon:IsA("ImageLabel") then
		icon.Visible = true
		_setImage(icon, iconUrl)
		if viewport and viewport:IsA("GuiObject") then
			viewport.Visible = false
		end
	else
		if icon and icon:IsA("GuiObject") then
			icon.Visible = false
		end
		if viewport and viewport:IsA("GuiObject") then
			viewport.Visible = false
		end
	end

	local countLabel = frame:FindFirstChild("Count")
	if countLabel and countLabel:IsA("TextLabel") then
		local rewardCount = count or 1
		if rewardCount > 1 then
			countLabel.Visible = true
			countLabel.Text = "x" .. tostring(rewardCount)
		else
			countLabel.Visible = false
		end
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	按物品类型填充奖励格展示

	@param frame Frame - 奖励格
	@param itemId number - 配置 ID
	@param count number - 数量
	@return nil
]]
function GmEmailRewardSlots.setupRewardSlot(frame: Frame, itemId: number, count: number)
	if _isTitleRewardItem(itemId) then
		_applyTitleRewardSlot(frame, itemId)
		return
	end
	if _isGamePassRewardItem(itemId) then
		_applyGamePassRewardSlot(frame, itemId, count or 1)
		return
	end
	UIMgr.SetAward(frame, itemId, count or 1)
end

return GmEmailRewardSlots
