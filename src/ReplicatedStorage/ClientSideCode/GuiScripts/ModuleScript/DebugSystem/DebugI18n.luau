--[[
	Module: DebugI18n
	Description: DebugSystem 已知翻译键的字面量查表（Caption / 输入组）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-22

	功能：
	- applyButtonText：TextButton 子 Caption 走 SetText（TranslationHelper 不支持 TextButton 本身）
	- applyInputGroupTexts：标签 + 占位符「请输入{1}」

	约束：
	- Key 必须在 SetText 实参处写字面量（本地化规范 §6.2.1），故用 if/elseif 而非 KEY 表
	- 未知键只 Log.warn，不把变量传入本地化 API
	- 新动态按钮须在本文件补分支，并同步 LocalizationTable

	加载：仅 DebugSystem 目录内 require(script.DebugI18n)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TranslationHelper = Utils.TranslationHelper
local Log = Utils.Log

local DebugI18n = {}

--[[
	在 TextButton 内铺一层 Caption，供 SetText 绑定
	@param button TextButton - 父按钮
	@return TextLabel - 文案标签
]]
local function _ensureCaptionLabel(button: TextButton): TextLabel
	local existing = button:FindFirstChild("Caption")
	if existing and existing:IsA("TextLabel") then
		return existing
	end
	button.Text = ""
	local label = Instance.new("TextLabel")
	label.Name = "Caption"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Active = false
	label.TextColor3 = button.TextColor3
	label.TextSize = button.TextSize
	label.Font = button.Font
	label.ZIndex = button.ZIndex
	label.Parent = button
	return label
end

--[[
	给按钮 Caption 写入已知翻译键
	@param button TextButton - 目标按钮（文案写在子 TextLabel Caption 上）
	@param key string - 翻译键；未知键不调用本地化 API
	@return nil
]]
function DebugI18n.applyButtonText(button: TextButton, key: string)
	local label = _ensureCaptionLabel(button)
	if key == "添加" then
		TranslationHelper.SetText(label, "添加")
	elseif key == "减少" then
		TranslationHelper.SetText(label, "减少")
	elseif key == "清空" then
		TranslationHelper.SetText(label, "清空")
	elseif key == "调试窗口" then
		TranslationHelper.SetText(label, "调试窗口")
	elseif key == "关闭调试" then
		TranslationHelper.SetText(label, "关闭调试")
	elseif key == "修改记录" then
		TranslationHelper.SetText(label, "修改记录")
	elseif key == "初始化角色数据" then
		TranslationHelper.SetText(label, "初始化角色数据")
	elseif key == "短视频界面" then
		TranslationHelper.SetText(label, "短视频界面")
	elseif key == "自动战斗" then
		TranslationHelper.SetText(label, "自动战斗")
	elseif key == "中止自动战斗" then
		TranslationHelper.SetText(label, "中止自动战斗")
	else
		Log.warn("[DebugSystem] unknown button key:", key)
		label.Text = key
	end
end

--[[
	给输入组标签与占位符写入已知翻译键
	@param label TextLabel - 左侧标签
	@param textBox TextBox - 输入框（SetText 写 PlaceholderText）
	@param key string - 标签翻译键；未知键不调用本地化 API
	@return nil
]]
function DebugI18n.applyInputGroupTexts(label: TextLabel, textBox: TextBox, key: string)
	if key == "ID" then
		TranslationHelper.SetText(label, "ID")
		TranslationHelper.SetText(textBox, "请输入{1}", { { "ID" } })
	elseif key == "物品数量" then
		TranslationHelper.SetText(label, "物品数量")
		TranslationHelper.SetText(textBox, "请输入{1}", { { "物品数量" } })
	elseif key == "记录名称" then
		TranslationHelper.SetText(label, "记录名称")
		TranslationHelper.SetText(textBox, "请输入{1}", { { "记录名称" } })
	elseif key == "修改值" then
		TranslationHelper.SetText(label, "修改值")
		TranslationHelper.SetText(textBox, "请输入{1}", { { "修改值" } })
	else
		Log.warn("[DebugSystem] unknown input key:", key)
		label.Text = key
		textBox.PlaceholderText = key
	end
end

return DebugI18n
