--[[
	Module: SystemSDK
	Description: 服务端数数（ThinkingData）上报封装，不改玩家存档与经济结算
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- FirstLogin / SetUserProfile：上报首次登录时间、用户名（userSetOnce / userSet）
	- PayProductItem / PayGamePass：付费成功后上报 payment，并异步校验商品 / Pass 归属
	- CheckProductID / CheckGamePassID：对照本游戏开发者商品列表或创建者 ID，异常则上报 WrongPayData
	- GameTimeOnce / GameTimeOnceNew：userSetOnce 写入时长类字段
	- Flush：立即刷出发送队列（模块加载后每 30s 也会调用；关服由 UpdateManager 再调一次）

	调用关系：
	- SystemBuyRoblox 在付费成功后调用 PayGamePass / PayProductItem
	- UpdateManager 预加载本模块以注册定时 Flush，关服再调 Flush
	- SetUserProfile 由 Pay* 内部调用，不是 Manager Init
	- 底层 HTTP 由同目录 ThinkingAnalyticsAPI（第三方 SDK）发出
	- 不读写 DataStore；发奖与收据校验不在本模块

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemSDK = Utils.SystemSDK

	示例：
		SystemSDK.PayGamePass(player, passId)
		SystemSDK.Flush()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local RunService = Utils.RunService
local Log = Utils.Log
local CfgFind = Utils.CfgFind
local WorldUtil = Utils.WorldUtil
local UpdateModule = Utils.UpdateModule
local MarketplaceService = game:GetService("MarketplaceService")
local ThinkingAnalyticsAPI = require(script.ThinkingAnalyticsAPI)

local SystemSDK = {}

-- ============================================================================
-- 常量
-- ============================================================================

local PROJECT_ID = "RP15"
local CREATOR_TARGET_ID = 15150189
local ANOMALY_ACCOUNT_ID = 1
local INFO_TYPE_GAME_PASS = Enum.InfoType.GamePass
local INFO_TYPE_PRODUCT = Enum.InfoType.Product

-- ============================================================================
-- 私有状态
-- ============================================================================

local ServerName = WorldUtil.GetServerType()
local _productIdList = {}
local _productIdsLoaded = false

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	判断当前环境是否允许向数数上报。

	仅 Dev 服且非 Studio 时返回 true；Official 服或 Studio 一律跳过，避免污染数数数据。

	@return boolean - true 表示允许上报；false 表示调用方应直接 return、不发事件
]]
local function _isContinue(): boolean
	if ServerName ~= "Dev" then
		return false
	end
	if RunService:IsStudio() then
		return false
	end
	return true
end

--[[
	拉取并缓存本游戏开发者商品 ID 列表（分页）。已成功加载则直接返回。

	失败时不把空表当成「已加载」，以便下次重试；调用方据此决定是否做白名单校验。

	@return boolean - true 表示列表已就绪（可为 0 条）；false 表示本次拉取失败
]]
local function _ensureProductIdsLoaded(): boolean
	if _productIdsLoaded then
		return true
	end
	local ok, err = pcall(function()
		local pages: Pages = MarketplaceService:GetDeveloperProductsAsync()
		while true do
			for _, item in pages:GetCurrentPage() do
				table.insert(_productIdList, item.ProductId)
			end
			if pages.IsFinished then
				break
			end
			pages:AdvanceToNextPageAsync()
		end
	end)
	if not ok then
		Log.warn("SystemSDK 拉取开发者商品列表失败", err)
		return false
	end
	_productIdsLoaded = true
	return true
end

--[[
	pcall 包装 MarketplaceService:GetProductInfo，失败只打日志。

	@param assetId number - 商品或 GamePass 的资产 ID
	@param infoType Enum.InfoType - Product 或 GamePass
	@return any? - 成功返回 ProductInfo 表；失败返回 nil
]]
local function _getProductInfo(assetId: number, infoType: Enum.InfoType): any?
	local ok, result = pcall(function()
		return MarketplaceService:GetProductInfo(assetId, infoType)
	end)
	if not ok then
		Log.warn("SystemSDK GetProductInfo 失败", assetId, infoType, result)
		return nil
	end
	return result
end

--[[
	向事件属性表写入全游戏公共字段（当前仅 project_id）。

	就地修改并返回同一张表，供 userSet / track 前统一补字段。
	_player 预留给后续按玩家补 nick_name / tmp_* 等字段，当前实现未读取。

	@param properties table - 待上报的属性表；函数会写入 project_id（值为 PROJECT_ID）
	@param _player Player? - 目标玩家；nil 时仅写项目级字段（如异常付费上报）；当前未读取
	@return table - 补全后的同一张 properties 表
]]
local function _givePublicPro(properties: { [string]: any }, _player: Player?): { [string]: any }
	properties["project_id"] = PROJECT_ID
	return properties
end

--[[
	将属性表逐键打印到日志，便于核对实际上报内容。

	@param properties table - 已补全公共字段的上报属性表（键为字段名，值为对应类型）
]]
local function _printProperties(properties: { [string]: any })
	for key, value in pairs(properties) do
		Log.warn(key, ":", value)
	end
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	上报玩家首次登录时间（userSetOnce，字段 NewPlr_first_login_time）。

	非 Dev 或 Studio 直接跳过。player 无效时静默 return。

	@param player Player - 刚进服的玩家
]]
function SystemSDK.FirstLogin(player: Player)
	if not _isContinue() then
		return
	end
	if not player then
		return
	end

	local accountId = player.UserId
	local userSetProperties = {}
	userSetProperties["NewPlr_first_login_time"] = os.date("%Y-%m-%d %H:%M:%S")
	userSetProperties = _givePublicPro(userSetProperties, player)
	ThinkingAnalyticsAPI.userSetOnce(accountId, nil, userSetProperties)
	Log.warn("数数SDK 首次登录时上报")
	_printProperties(userSetProperties)
end

--[[
	向数数写入当前用户名（userSet，字段 user_name）。

	由 PayProductItem / PayGamePass 在上报 payment 前调用。不是 Manager 启动用的 Init。

	@param player Player - 目标玩家
]]
function SystemSDK.SetUserProfile(player: Player)
	if not _isContinue() then
		return
	end
	if not player then
		return
	end

	local accountId = player.UserId
	local userSetProperties = {}
	userSetProperties["user_name"] = player.Name
	userSetProperties = _givePublicPro(userSetProperties, player)
	ThinkingAnalyticsAPI.userSet(accountId, nil, userSetProperties)
	Log.warn("数数SDK 初始化")
	_printProperties(userSetProperties)
end

--[[
	开发者商品付费成功后上报 payment，并异步校验 ProductId 是否属于本游戏。

	须在 SystemBuyRoblox 服侧结算成功之后调用；本函数不发奖、不写存档。

	@param player Player - 付费玩家
	@param receiptInfo table - ProcessReceipt 收据，须含：
		ProductId number - 开发者商品 ID
		CurrencySpent number - 花费 Robux
		PurchaseId string - 订单号
]]
function SystemSDK.PayProductItem(player: Player, receiptInfo: any)
	if not _isContinue() then
		return
	end
	if not player then
		return
	end
	if type(receiptInfo) ~= "table" then
		Log.warn("SystemSDK.PayProductItem 收据无效")
		return
	end
	local productId = receiptInfo.ProductId
	if productId == nil then
		Log.warn("SystemSDK.PayProductItem 缺少 ProductId", player.UserId)
		return
	end

	SystemSDK.SetUserProfile(player)

	task.spawn(function()
		if not RunService:IsStudio() then
			SystemSDK.CheckProductID(productId)
		end
	end)

	Log.warn("数数SDK 购买普通商品成功", player.DisplayName)

	local properties = {}
	properties["#time"] = os.date("%Y-%m-%d %H:%M:%S")
	properties["Product_Name"] = productId
	properties["Price"] = receiptInfo.CurrencySpent
	properties["OrderId"] = receiptInfo.PurchaseId
	properties = _givePublicPro(properties, player)
	ThinkingAnalyticsAPI.track(player.UserId, nil, "payment", properties)
	_printProperties(properties)
end

--[[
	GamePass 付费成功后上报 payment，并异步校验 Pass 创建者是否为本项目组。

	配表找不到 Pass 时仍会发起归属校验，但不发 payment 事件。

	@param player Player - 付费玩家
	@param passId number - GamePass 资产 ID
]]
function SystemSDK.PayGamePass(player: Player, passId: number)
	if not _isContinue() then
		return
	end
	if not player then
		return
	end
	if passId == nil then
		Log.warn("SystemSDK.PayGamePass 缺少 passId", player.UserId)
		return
	end

	SystemSDK.SetUserProfile(player)

	task.spawn(function()
		if not RunService:IsStudio() then
			SystemSDK.CheckGamePassID(passId)
		end
	end)

	local cfgPass = CfgFind.FindCfgByPassID(passId)
	if not cfgPass then
		return
	end

	Log.warn("数数SDK 购买Pass成功", player.DisplayName, passId)

	local properties = {}
	properties["#time"] = os.date("%Y-%m-%d %H:%M:%S")
	properties["Product_Name"] = cfgPass.OnlyTag
	properties["Price"] = cfgPass.price
	properties = _givePublicPro(properties, player)
	ThinkingAnalyticsAPI.track(player.UserId, nil, "payment", properties)
	_printProperties(properties)
end

--[[
	校验 GamePass 创建者是否为本项目组；否则上报 WrongPayData。

	GetProductInfo 失败时只打日志、不发事件。

	@param passId number - GamePass 资产 ID
]]
function SystemSDK.CheckGamePassID(passId: number)
	if passId == nil then
		return
	end

	local assetData = _getProductInfo(passId, INFO_TYPE_GAME_PASS)
	if not assetData then
		return
	end

	local creator = assetData.Creator
	if creator and creator.CreatorTargetId == CREATOR_TARGET_ID then
		return
	end

	local properties = {}
	properties["#time"] = os.date("%Y-%m-%d %H:%M:%S")
	properties["AssetData"] = assetData
	properties = _givePublicPro(properties)
	ThinkingAnalyticsAPI.track(ANOMALY_ACCOUNT_ID, nil, "WrongPayData", properties)
	_printProperties(properties)
end

--[[
	校验开发者商品 ID 是否在本游戏商品列表中；不在则上报 WrongPayData。

	列表尚未拉到时会同步拉取；拉取失败则跳过本次校验（避免空表把合法商品当异常）。

	@param productId number - 开发者商品 ID
]]
function SystemSDK.CheckProductID(productId: number)
	if productId == nil then
		return
	end
	if not _ensureProductIdsLoaded() then
		return
	end

	for _, knownId in _productIdList do
		if knownId == productId then
			return
		end
	end

	local properties = {}
	properties["#time"] = os.date("%Y-%m-%d %H:%M:%S")

	local assetData = _getProductInfo(productId, INFO_TYPE_PRODUCT)
	if assetData then
		properties["AssetData"] = assetData
	else
		properties["AssetData"] = productId
	end
	Log.warn("SystemSDK 异常开发者商品", productId, assetData)

	properties = _givePublicPro(properties)
	ThinkingAnalyticsAPI.track(ANOMALY_ACCOUNT_ID, nil, "WrongPayData", properties)
	_printProperties(properties)
end

--[[
	立即刷出数数发送队列。Studio 跳过。正式环境不建议在 30s 定时之外频繁调用。
]]
function SystemSDK.Flush()
	if RunService:IsStudio() then
		return
	end
	Log.print("立即上报数据")
	ThinkingAnalyticsAPI.flush()
end

--[[
	userSetOnce 写入 gameTime_once。

	@param player Player - 目标玩家
	@param duration any - 时长或同类数值，原样写入数数字段
]]
function SystemSDK.GameTimeOnce(player: Player, duration: any)
	if not _isContinue() then
		return
	end
	if not player then
		return
	end

	local userSetProperties = {}
	userSetProperties["gameTime_once"] = duration
	userSetProperties = _givePublicPro(userSetProperties, player)
	ThinkingAnalyticsAPI.userSetOnce(player.UserId, nil, userSetProperties)
	_printProperties(userSetProperties)
end

--[[
	userSetOnce 写入 gameTimeNew_once。

	@param player Player - 目标玩家
	@param duration any - 时长或同类数值，原样写入数数字段
]]
function SystemSDK.GameTimeOnceNew(player: Player, duration: any)
	if not _isContinue() then
		return
	end
	if not player then
		return
	end

	local userSetProperties = {}
	userSetProperties["gameTimeNew_once"] = duration
	userSetProperties = _givePublicPro(userSetProperties, player)
	ThinkingAnalyticsAPI.userSetOnce(player.UserId, nil, userSetProperties)
	_printProperties(userSetProperties)
end

-- ============================================================================
-- 加载期注册（保持 require 即 Register，不占用 Manager Init）
-- ============================================================================

task.defer(_ensureProductIdsLoaded)

UpdateModule.Register(UpdateModule.INTERVAL.SEC_30, function(_elapsed: number)
	SystemSDK.Flush()
end, { spawn = true })

return SystemSDK
