--[[
	Module: InitTop
	Description: Main.Top 资源数量 TextLabel 与背包 NumberValue 双向同步及获得动画
	Author: 林奥宇
	Created: 2026-01-16
	Last Modified: 2026-08-31

	功能：
	- 监听背包 Coin / Diamond NumberValue 变化
	- 数量增加时播放 GetItemAnimation 飞入动画并延迟刷新文本
	- 数量减少或持平时直接更新文本

	依赖：
	- Utils.GetData.WaitBagNumberValue：等待背包数值实例
	- Utils.UIanima.GetItemAnimation：资源飞入 Top 栏动画
	- Utils.TranslationHelper.SetRawText：数量为纯数字，不参与查表

	约定：
	- 本文件为 StarterPlayerScripts LocalScript，启动即绑定；无 Init() / 模块表
	- 只读展示服务端写入的背包镜像，不改存档、不结算奖励
	- Main.Top 下须存在 资源/资源1/数量 与 资源/资源2/数量 TextLabel

	加载方式：
		本脚本由 StarterPlayer 自动运行，无需 require
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local AddListen = Utils.AddListen
local EnumMgr = Utils.EnumMgr
local GetData = Utils.GetData
local LocalPlayer = Utils.LocalPlayer
local MathMgr = Utils.MathMgr
local SoundModule = Utils.SoundModule
local TranslationHelper = Utils.TranslationHelper
local UIanima = Utils.UIanima

-- ========================================
-- 常量
-- ========================================
local NUMBER_ANIM_DELAY_SEC = 1
local GAIN_RESOURCE_SOUND = "获得金币钻石"

-- ========================================
-- 私有变量
-- ========================================
local _coinNumberValue: NumberValue = GetData.WaitBagNumberValue(LocalPlayer, EnumMgr.ItemID.Coin)
local _diamondNumberValue: NumberValue = GetData.WaitBagNumberValue(LocalPlayer, EnumMgr.ItemID.Diamond)

local _playerGui: PlayerGui = LocalPlayer:WaitForChild("PlayerGui", math.huge) :: PlayerGui
local _screenGui: ScreenGui = _playerGui:WaitForChild("ScreenGui", math.huge) :: ScreenGui
local _mainUI: Frame = _screenGui:WaitForChild("Main", math.huge) :: Frame
local _topUI: Frame = _mainUI.Top
local _coinTextLabel: TextLabel = _topUI["资源"]["资源1"]["数量"]
local _diamondTextLabel: TextLabel = _topUI["资源"]["资源2"]["数量"]

-- ========================================
-- 私有函数
-- ========================================

--[[
	资源数量变化时的文本与飞入动画表现
	@param itemId number - EnumMgr.ItemID，决定飞入图标类型
	@param lastNumber number? - 变化前数量；nil 时跳过增加动画
	@param newNumber number - 变化后数量
	@param textLabel TextLabel - Top 栏数量文本
	@param callback (() -> ())? - 增加动画触发后的回调（如播放音效）
	@return nil - 无返回值
]]
local function _onNumberChange(
	itemId: number,
	lastNumber: number?,
	newNumber: number,
	textLabel: TextLabel,
	callback: (() -> ())?
)
	local displayText = MathMgr.getNumStr(math.floor(newNumber))
	if lastNumber ~= nil and lastNumber < newNumber then
		UIanima.GetItemAnimation(itemId, newNumber - lastNumber, textLabel)
		task.delay(NUMBER_ANIM_DELAY_SEC, function()
			TranslationHelper.SetRawText(textLabel, displayText)
		end)

		if callback then
			callback()
		end
	else
		TranslationHelper.SetRawText(textLabel, displayText)
	end
end

--[[
	绑定 NumberValue 变化到 TextLabel 刷新
	@param numberValue NumberValue - 背包资源数值实例
	@param itemId number - EnumMgr.ItemID，与 numberValue 对应
	@param textLabel TextLabel - Top 栏数量文本
	@param callback (() -> ())? - 数量增加时的附加回调
	@return nil - 无返回值
]]
local function _bindNumberValueChange(
	numberValue: NumberValue,
	itemId: number,
	textLabel: TextLabel,
	callback: (() -> ())?
)
	local lastNumber = numberValue.Value
	AddListen.NumValueAdd(numberValue, function(number: number)
		_onNumberChange(itemId, lastNumber, number, textLabel, callback)
		lastNumber = number
	end)
end

-- ========================================
-- 初始化
-- ========================================
_bindNumberValueChange(_coinNumberValue, EnumMgr.ItemID.Coin, _coinTextLabel, function()
	SoundModule:PlaySoundLocal(GAIN_RESOURCE_SOUND)
end)

_bindNumberValueChange(_diamondNumberValue, EnumMgr.ItemID.Diamond, _diamondTextLabel, function()
	SoundModule:PlaySoundLocal(GAIN_RESOURCE_SOUND)
end)
