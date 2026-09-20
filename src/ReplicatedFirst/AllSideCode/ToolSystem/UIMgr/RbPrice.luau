--[[
	Module: UIMgr/RbPrice
	Description: UIMgr 子模块 — Robux 价格展示：同步写价、按付费项 ID / OnlyTag 异步拉平台价并缓存（由 init 合并导出至 Utils.UIMgr）
	Author: 程莘
	Created: 2026-09-17
	Last Modified: 2026-09-17

	功能：
	- SetRbPrice：同步写入 TextLabel（默认带 Robux 符号）
	- SetRbPriceByProduct：按 productId + EnumMgr.RobuxType 异步 GetProductInfo，进程内按类型+ID 缓存成功价
	- SetRbPriceByOnlyTag：弹窗常用入口，查 itemshopdataConf.OnlyTag 后转调 ByProduct
	- 同 Label 快速切换付费项时，仅最新期望项允许异步回写，避免旧请求晚到覆盖

	与 init：业务只调 Utils.UIMgr，不要直接 require 本文件。

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local UIMgr = Utils.UIMgr

	示例：
		UIMgr.SetRbPrice(priceLabel, 79)
		UIMgr.SetRbPrice(priceLabel, 79, false)
		UIMgr.SetRbPriceByProduct(priceLabel, passId, EnumMgr.RobuxType.GamePass)
		UIMgr.SetRbPriceByOnlyTag(priceLabel, "OnlineAwardClaimAll")
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local TranslationHelper = Utils.TranslationHelper
local MarketplaceService = Utils.MarketplaceService
local Log = Utils.Log

local RbPrice = {}

-- 客户端进程内缓存：同「InfoType + 付费项 ID」只向 Roblox 请求一次成功价
local _rbPriceCache: { [string]: number } = {}
-- 同 key 请求未完成时，后到的 TextLabel 挂入等待列表，避免重复 GetProductInfo
local _rbPricePending: { [string]: { TextLabel } } = {}
local _rbPriceInflight: { [string]: boolean } = {}
-- 每个 Label 当前期望展示的付费项 key / 是否带符号（弱键，防销毁后泄漏；用于丢弃过期异步回写）
local _rbPriceDesiredKey: { [TextLabel]: string } = setmetatable({}, { __mode = "k" }) :: any
local _rbPriceDesiredSymbol: { [TextLabel]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Roblox 私有区货币字形（依赖字体支持；与官方商店价签一致）
local ROBUX_GLYPH = utf8.char(0xE002)

--[[
	将 EnumMgr.RobuxType 映射为 MarketplaceService InfoType
	@param robuxType number - EnumMgr.RobuxType.RobuxItem | GamePass
	@return Enum.InfoType? - Product / GamePass；非法类型 nil
]]
local function _resolveRobuxInfoType(robuxType: number): Enum.InfoType?
	if robuxType == EnumMgr.RobuxType.GamePass then
		return Enum.InfoType.GamePass
	elseif robuxType == EnumMgr.RobuxType.RobuxItem then
		return Enum.InfoType.Product
	end
	return nil
end

--[[
	付费项价格缓存键（类型名 + ID，避免 GamePass 与 DeveloperProduct 同号冲突）
	@param productId number - 付费项资产 ID
	@param infoType Enum.InfoType - Product 或 GamePass
	@return string - 缓存键
]]
local function _rbPriceCacheKey(productId: number, infoType: Enum.InfoType): string
	return infoType.Name .. ":" .. tostring(productId)
end

--[[
	设置 Robux 价格显示
	@param _text TextLabel - 文本标签
	@param _price number - 价格
	@param withSymbol boolean? - 是否前置 Robux 符号；默认 true
	@return () - 无返回值
]]
function RbPrice.SetRbPrice(_text: TextLabel, _price: number, withSymbol: boolean?): ()
	if not _text:IsA("TextLabel") then
		return
	end

	-- 移除现有的 UIStroke
	local uiS: UIStroke? = _text:FindFirstChildOfClass("UIStroke") :: UIStroke?
	if uiS then
		uiS:Destroy()
	end

	_text.RichText = true
	local showSymbol = withSymbol ~= false
	local priceText = if showSymbol then (ROBUX_GLYPH .. " " .. _price) else (" " .. _price)
	TranslationHelper.SetRawText(_text, priceText)
end

--[[
	仅当 Label 仍期望本 requestKey 时写价，避免同 Label 快速切换付费项时旧请求回写覆盖
	@param labels { TextLabel } - 等待刷新的标签
	@param price number - Robux 价格
	@param requestKey string - 本次完成请求对应的缓存键
	@return () - 无返回值
]]
local function _applyRbPriceToLabels(labels: { TextLabel }, price: number, requestKey: string)
	for _, label in ipairs(labels) do
		if label.Parent and label:IsA("TextLabel") and _rbPriceDesiredKey[label] == requestKey then
			RbPrice.SetRbPrice(label, price, _rbPriceDesiredSymbol[label])
		end
	end
end

--[[
	按付费项 ID / 类型异步向 Roblox 拉取真实售价并写入 TextLabel。
	同进程内每个「类型 + ID」成功价只请求一次；并发调用会合并等待，失败不写入缓存以便下次重试。
	同一 TextLabel 快速切换不同付费项时，仅最新期望项允许回写，避免旧请求晚到覆盖。
	展示走 SetRbPrice（数字不翻译）。适合客户端商店/活动按钮价格，勿当作结算依据。

	@param _text TextLabel - 价格文本标签
	@param productId number - GamePass 或 Developer Product 资产 ID（itemshopdataConf.passID 等）
	@param robuxType number - EnumMgr.RobuxType.GamePass | RobuxItem（分别对应 InfoType.GamePass / Product）
	@param withSymbol boolean? - 是否前置 Robux 符号；默认 true
	@return () - 无返回值（异步完成后才改 Text；缓存命中则同步改）
]]
function RbPrice.SetRbPriceByProduct(_text: TextLabel, productId: number, robuxType: number, withSymbol: boolean?): ()
	if not _text or not _text:IsA("TextLabel") then
		return
	end

	local id = tonumber(productId)
	if not id or id <= 0 then
		return
	end

	local infoType = _resolveRobuxInfoType(robuxType)
	if not infoType then
		Log.warn("UIMgr.SetRbPriceByProduct 非法 robuxType", robuxType)
		return
	end

	local showSymbol = withSymbol ~= false
	local key = _rbPriceCacheKey(id, infoType)
	-- 先登记期望项，再读缓存 / 入队，保证途中切换时旧回调会被丢弃
	_rbPriceDesiredKey[_text] = key
	_rbPriceDesiredSymbol[_text] = showSymbol

	local cached = _rbPriceCache[key]
	if cached ~= nil then
		RbPrice.SetRbPrice(_text, cached, showSymbol)
		return
	end

	local pending = _rbPricePending[key]
	if not pending then
		pending = {}
		_rbPricePending[key] = pending
	end
	table.insert(pending, _text)

	if _rbPriceInflight[key] then
		return
	end
	_rbPriceInflight[key] = true

	task.spawn(function()
		local ok, result = pcall(function()
			return MarketplaceService:GetProductInfo(id, infoType)
		end)

		_rbPriceInflight[key] = nil
		local waiters = _rbPricePending[key]
		_rbPricePending[key] = nil

		if not ok or type(result) ~= "table" then
			Log.warn("UIMgr.SetRbPriceByProduct GetProductInfo 失败", id, infoType, result)
			return
		end

		local price = tonumber(result.PriceInRobux)
		if price == nil then
			Log.warn("UIMgr.SetRbPriceByProduct 缺少 PriceInRobux", id, infoType)
			return
		end

		_rbPriceCache[key] = price
		if waiters then
			_applyRbPriceToLabels(waiters, price, key)
		end
	end)
end

--[[
	按 itemshopdataConf.OnlyTag 查表后异步设置 Robux 价格（弹窗 UI 常用入口）。
	内部取 passID + cost（EnumMgr.RobuxType），再转调 SetRbPriceByProduct；缓存与请求去重共用底层逻辑。

	@param _text TextLabel - 价格文本标签
	@param onlyTag string - 商城条目 OnlyTag（如 "OnlineAwardClaimAll"、"LuckX2"）
	@param withSymbol boolean? - 是否前置 Robux 符号；默认 true
	@return () - 无返回值；配置缺失或 passID/cost 非法时打日志并跳过
]]
function RbPrice.SetRbPriceByOnlyTag(_text: TextLabel, onlyTag: string, withSymbol: boolean?): ()
	if not _text or not _text:IsA("TextLabel") then
		return
	end
	if type(onlyTag) ~= "string" or onlyTag == "" then
		return
	end

	local cfg = CfgFind.FindCfgByOnlyTag(onlyTag)
	if not cfg then
		Log.warn("UIMgr.SetRbPriceByOnlyTag 未找到商城配置", onlyTag)
		return
	end

	local productId = tonumber(cfg.passID)
	local robuxType = tonumber(cfg.cost)
	if not productId or productId <= 0 or not robuxType then
		Log.warn("UIMgr.SetRbPriceByOnlyTag passID/cost 无效", onlyTag, cfg.passID, cfg.cost)
		return
	end

	RbPrice.SetRbPriceByProduct(_text, productId, robuxType, withSymbol)
end

return RbPrice