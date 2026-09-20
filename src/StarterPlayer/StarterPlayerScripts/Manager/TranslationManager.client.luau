--[[
	Module: TranslationManager
	Description: 监听玩家 LocaleId 变化并刷新已绑定本地化的 UI
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-08-31
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TranslationHelper = Utils.TranslationHelper
local Log = Utils.Log
local LocalPlayer = Utils.LocalPlayer
local CollectionService = Utils.CollectionService

local STATIC_TAG = "本地化"
local CODE_TAG = "代码本地化"

--[[
	按实例上缓存的翻译键与参数刷新文案
	@param v Instance - 带 _key / _maxIndex / _arg* 属性的本地化控件
]]
local function _changeText(v)
	local _key = v:GetAttribute("_key")
	local _maxIndex = v:GetAttribute("_maxIndex")
	local _args = nil

	if _maxIndex then
		_args = {}

		for i = 1, _maxIndex do
			if v:GetAttribute("_arg" .. i) then
				_args[i] = v:GetAttribute("_arg" .. i)
			elseif v:GetAttribute("_arg_table" .. i) then
				_args[i] = { v:GetAttribute("_arg_table" .. i) }
			end
		end
	end
	TranslationHelper.SetText(v, _key, _args)
end

--[[
	LocaleId 变化时同步 TranslationHelper 并刷新代码本地化标签
]]
local function _onLocaleIdChanged()
	if TranslationHelper.GetLocaleId() == LocalPlayer.LocaleId then
		return
	end

	TranslationHelper.SetLocaleId(LocalPlayer.LocaleId)

	Log.warn("===============切换了本地语言:", TranslationHelper.GetLocaleId())

	for _, v in pairs(CollectionService:GetTagged(CODE_TAG)) do
		_changeText(v)
	end
end

--[[
	静态本地化标签：用 Instance.Name 作为翻译键写回 Text
	@param ignorePart TextLabel - CollectionService 标签「本地化」的控件
]]
local function _addLocalText(ignorePart: TextLabel)
	TranslationHelper.SetText(ignorePart, ignorePart.Name)
end

LocalPlayer:GetPropertyChangedSignal("LocaleId"):Connect(_onLocaleIdChanged)

TranslationHelper.SetLocaleId(LocalPlayer.LocaleId)

for _, ignorePart in pairs(CollectionService:GetTagged(STATIC_TAG)) do
	_addLocalText(ignorePart)
end

CollectionService:GetInstanceAddedSignal(STATIC_TAG):Connect(function(ignorePart: TextLabel)
	_addLocalText(ignorePart)
end)

for _, ignorePart in pairs(CollectionService:GetTagged(CODE_TAG)) do
	_changeText(ignorePart)
end

CollectionService:GetInstanceAddedSignal(CODE_TAG):Connect(function(v: TextLabel)
	_changeText(v)
end)
