--[[
	Module: SystemCDK
	Description: 服务端 CDK 池生成、CAS 兑换与入包失败回滚（经 SystemDataStore STORE.CDK）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- GenerateSingleCDK / IsCDKUnique：生成单码、检查池内是否已存在
	- GenerateAndPrintCDK / GenerateAllPoolsCDK：Studio / 服内命令批量写入池（无 Remote）
	- Redeem：按码扫 type 3 池，UpdateAsync CAS 标记已兑，返回奖励 ID / 数量 / poolId（奖励列表为深拷贝，不是配表原引用）
	- RollbackRedeem：同一玩家、时限内入包失败时解除标记

	调用关系：
	- 仅服务端。发奖只允许 SystemCode.RedeemCode → Redeem → SystemBag.AddItems
	- 禁止把 rewardId 回传客户端当发奖依据；本模块不绑 Remote
	- 池键 CDKPools，经 SystemDataStore.STORE.CDK，禁止直连 DataStoreService

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemCDK = Utils.SystemCDK
		local ok, rewardId, rewardNum, poolId = SystemCDK.Redeem(player, "XXXX-XXXX-XXXX")
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local Copy = Utils.Copy
local CfgFind = Utils.CfgFind
local SystemDataStore = Utils.SystemDataStore

local SystemCDK = {}

-- ============================================================================
-- 常量
-- ============================================================================

local CHARSET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
local CDK_TYPE = 3
local CDK_SEGMENT_COUNT = 3
local CDK_CHARS_PER_SEGMENT = 4
local GENERATE_UNIQUE_ATTEMPT_MUL = 3
local DEFAULT_GENERATE_PER_POOL = 100
local CDK_STORE = SystemDataStore.STORE.CDK
local ROLLBACK_MAX_AGE_SEC = 120

-- ============================================================================
-- 配置缓存（只读配表，不写回）
-- ============================================================================

type CdkPoolConfig = {
	rewardId: { number }?,
	rewardNum: { number }?,
	startTime: number?,
	endTime: number?,
}

local CDK_POOLS: { [string]: CdkPoolConfig } = {}

local Codes = CfgFind.GetCfgByName("codeConf")
if Codes then
	for _, config in pairs(Codes) do
		if tonumber(config.codeType) == CDK_TYPE and type(config.code) == "string" then
			CDK_POOLS[config.code] = {
				rewardId = type(config.rewardId) == "table" and Copy.deepCopy(config.rewardId) or nil,
				rewardNum = type(config.rewardNum) == "table" and Copy.deepCopy(config.rewardNum) or nil,
				startTime = config.startTime or 0,
				endTime = config.endTime or 0,
			}
		end
	end
end

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	生成单个 CDK（格式 XXXX-XXXX-XXXX）
	@return string - 生成的 CDK
]]
local function _generateSingleCdk(): string
	local parts = {}
	for _ = 1, CDK_SEGMENT_COUNT do
		local part = ""
		for _ = 1, CDK_CHARS_PER_SEGMENT do
			local rand = math.random(1, #CHARSET)
			part = part .. string.sub(CHARSET, rand, rand)
		end
		table.insert(parts, part)
	end
	return table.concat(parts, "-")
end

--[[
	池是否在配置时间窗内（start/end 为 0 表示不限制）
	@param poolConfig CdkPoolConfig - { rewardId, rewardNum, startTime, endTime }
	@param now number - os.time()
	@return boolean - 当前可兑为 true
]]
local function _isPoolTimeActive(poolConfig: CdkPoolConfig, now: number): boolean
	if type(poolConfig) ~= "table" then
		return false
	end
	local startTime = tonumber(poolConfig.startTime) or 0
	local endTime = tonumber(poolConfig.endTime) or 0
	if startTime ~= 0 and now < startTime then
		return false
	end
	if endTime ~= 0 and now > endTime then
		return false
	end
	return true
end

--[[
	从 DataStore 读取池内 cdks
	@param poolId string - 池 ID（codeConf.code）
	@return {[string]: any}?, boolean - cdks 字典与是否读成功；无存档时为空表 + true
]]
local function _tryGetPoolCdks(poolId: string): ({ [string]: any }?, boolean)
	local ok, poolData = SystemDataStore.Get(CDK_STORE, poolId)
	if not ok then
		return nil, false
	end
	if type(poolData) == "table" and type(poolData.cdks) == "table" then
		return poolData.cdks, true
	end
	return {}, true
end

--[[
	CAS 标记一码已兑；已兑或不存在则 abort（transform 返回 nil）
	@param userId number - 兑换玩家 UserId
	@param code string - CDK 字符串
	@return (any?) -> any - SystemDataStore.Update 的 transform
]]
local function _markRedeemTransform(userId: number, code: string): (any?) -> any
	return function(oldData: any?): any
		if type(oldData) ~= "table" or type(oldData.cdks) ~= "table" then
			return nil
		end
		local data = Copy.deepCopy(oldData)
		local entry = data.cdks[code]
		if type(entry) ~= "table" or entry.redeemed == true then
			return nil
		end
		entry.redeemed = true
		entry.redeemedBy = userId
		entry.redeemTime = os.time()
		return data
	end
end

--[[
	CAS 回滚：仅当本玩家刚兑过且未超时
	@param userId number - 原兑换玩家 UserId
	@param code string - CDK 字符串
	@return (any?) -> any - SystemDataStore.Update 的 transform
]]
local function _rollbackRedeemTransform(userId: number, code: string): (any?) -> any
	return function(oldData: any?): any
		if type(oldData) ~= "table" or type(oldData.cdks) ~= "table" then
			return nil
		end
		local data = Copy.deepCopy(oldData)
		local entry = data.cdks[code]
		if type(entry) ~= "table" then
			return nil
		end
		if entry.redeemed ~= true or entry.redeemedBy ~= userId then
			return nil
		end
		local redeemTime = tonumber(entry.redeemTime)
		if redeemTime and (os.time() - redeemTime) > ROLLBACK_MAX_AGE_SEC then
			return nil
		end
		entry.redeemed = false
		entry.redeemedBy = nil
		entry.redeemTime = nil
		return data
	end
end

-- ============================================================================
-- 公共 API - CDK 生成（Studio / 服内命令，无 Remote）
-- ============================================================================

--[[
	生成单个 CDK
	@return string - 生成的 CDK
]]
function SystemCDK.GenerateSingleCDK(): string
	return _generateSingleCdk()
end

--[[
	检查 CDK 是否尚未写入该池
	@param poolId string - 池 ID
	@param cdk string - CDK 字符串
	@return boolean - 池中不存在为 true；读失败为 false
]]
function SystemCDK.IsCDKUnique(poolId: string, cdk: string): boolean
	if type(poolId) ~= "string" or type(cdk) ~= "string" then
		return false
	end
	local cdks, getOk = _tryGetPoolCdks(poolId)
	if not getOk or not cdks then
		return false
	end
	return cdks[cdk] == nil
end

--[[
	生成并写入一池 CDK（打印 Lua 表便于拷贝）
	@param poolId string - 池 ID（须为 type 3 的 codeConf.code）
	@param count number - 生成数量
	@return boolean, {string}? - 是否成功，生成的 CDK 列表
]]
function SystemCDK.GenerateAndPrintCDK(poolId: string, count: number): (boolean, { string }?)
	if not CDK_POOLS[poolId] then
		Log.warn("SystemCDK: 无效的 CDK 池 ID", poolId)
		for poolIdKey, _ in pairs(CDK_POOLS) do
			Log.warn("SystemCDK: 可用池", poolIdKey)
		end
		return false
	end

	local want = tonumber(count)
	if not want or want <= 0 then
		return false
	end
	want = math.floor(want)

	local existing, getOk = _tryGetPoolCdks(poolId)
	if not getOk or not existing then
		Log.warn("SystemCDK: 读取 CDK 池失败", poolId)
		return false
	end
	local generatedSet: { [string]: boolean } = {}
	local generatedList: { string } = {}
	local attempts = 0
	local maxAttempts = want * GENERATE_UNIQUE_ATTEMPT_MUL

	while #generatedList < want and attempts < maxAttempts do
		attempts += 1
		local newCdk = _generateSingleCdk()
		if not generatedSet[newCdk] and existing[newCdk] == nil then
			generatedSet[newCdk] = true
			table.insert(generatedList, newCdk)
		end
	end

	local output = "return {\n"
	for _, cdk in ipairs(generatedList) do
		output = output .. string.format('    "%s",\n', cdk)
	end
	output = output .. "}"
	Log.print("\n====== 生成的CDK列表 (" .. poolId .. ") ======")
	Log.print(output)

	local now = os.time()
	local saveOk, _, saveErr = SystemDataStore.Update(CDK_STORE, poolId, function(oldData: any?): any
		local data = Copy.deepCopy(oldData)
		if type(data.cdks) ~= "table" then
			data.cdks = {}
		end
		for _, cdk in ipairs(generatedList) do
			if data.cdks[cdk] == nil then
				data.cdks[cdk] = {
					generated = now,
					redeemed = false,
				}
			end
		end
		return data
	end)

	if not saveOk then
		Log.warn("SystemCDK: 保存 CDK 池失败", poolId, saveErr)
		return false
	end

	Log.print(string.format("成功生成并保存 %d/%d 个CDK到DataStore", #generatedList, want))
	return true, generatedList
end

--[[
	批量为所有 type 3 池生成 CDK
	@param countPerPool number? - 每池数量，默认 DEFAULT_GENERATE_PER_POOL
	@return boolean - 至少一池生成成功为 true
]]
function SystemCDK.GenerateAllPoolsCDK(countPerPool: number?): boolean
	local perPool = tonumber(countPerPool) or DEFAULT_GENERATE_PER_POOL
	if perPool <= 0 then
		return false
	end

	local cdkPools: { string } = {}
	if Codes then
		for _, config in pairs(Codes) do
			if tonumber(config.codeType) == CDK_TYPE and type(config.code) == "string" then
				table.insert(cdkPools, config.code)
			end
		end
	end

	if #cdkPools == 0 then
		Log.warn("SystemCDK: 没有找到任何 CDK 池配置")
		return false
	end

	local anySuccess = false
	local results: { [string]: { success: boolean, count: number } } = {}
	for _, poolId in ipairs(cdkPools) do
		Log.print("正在为池 [" .. poolId .. "] 生成 " .. perPool .. " 个CDK...")
		local success, generated = SystemCDK.GenerateAndPrintCDK(poolId, perPool)
		results[poolId] = {
			success = success,
			count = (success and generated) and #generated or 0,
		}
		if success then
			anySuccess = true
		end
	end

	Log.print("====== CDK生成结果汇总 ======")
	for poolId, result in pairs(results) do
		Log.print(string.format(
			"%-15s: %s (生成%d个)",
			poolId,
			result.success and "成功" or "失败",
			result.count
		))
	end

	return anySuccess
end

-- ============================================================================
-- 公共 API - 兑换 / 回滚
-- ============================================================================

--[[
	兑换 CDK：扫时间窗内 type 3 池，CAS 标记已兑
	@param plr Player - 兑换玩家（须在线）
	@param code string - 玩家输入的 CDK
	@return boolean, {number}?, {number}?, string? - 成功为 true 与奖励 ID、数量、poolId；失败全 nil
]]
function SystemCDK.Redeem(plr: Player, code: string): (boolean, { number }?, { number }?, string?)
	if not plr or not plr:IsA("Player") or plr.Parent == nil then
		return false
	end
	if type(code) ~= "string" or code == "" then
		return false
	end

	local now = os.time()
	local userId = plr.UserId

	for poolId, poolConfig in pairs(CDK_POOLS) do
		if _isPoolTimeActive(poolConfig, now) then
			local getOk, poolData, getErr = SystemDataStore.Get(CDK_STORE, poolId)
			if not getOk then
				Log.warn("SystemCDK: Redeem Get 失败", poolId, getErr)
				return false
			end
			local peek = type(poolData) == "table" and type(poolData.cdks) == "table" and poolData.cdks[code]
			if type(peek) == "table" and peek.redeemed ~= true then
				local ok, newData, err = SystemDataStore.Update(
					CDK_STORE,
					poolId,
					_markRedeemTransform(userId, code)
				)
				if not ok then
					Log.warn("SystemCDK: Redeem Update 失败", poolId, err)
					return false
				end
				if type(newData) == "table" and type(newData.cdks) == "table" then
					local entry = newData.cdks[code]
					if type(entry) == "table" and entry.redeemed == true and entry.redeemedBy == userId then
						local rewardId = type(poolConfig.rewardId) == "table" and Copy.deepCopy(poolConfig.rewardId) or nil
						local rewardNum = type(poolConfig.rewardNum) == "table" and Copy.deepCopy(poolConfig.rewardNum) or nil
						return true, rewardId, rewardNum, poolId
					end
				end
				return false
			end
		end
	end

	return false
end

--[[
	入包失败后回滚本玩家刚写下的已兑标记
	@param plr Player - 原兑换玩家
	@param poolId string - Redeem 返回的池 ID
	@param code string - 同一 CDK
	@return boolean - 回滚写入成功为 true
]]
function SystemCDK.RollbackRedeem(plr: Player, poolId: string, code: string): boolean
	if not plr or not plr:IsA("Player") then
		return false
	end
	if type(poolId) ~= "string" or poolId == "" or type(code) ~= "string" or code == "" then
		return false
	end

	local ok, newData, err = SystemDataStore.Update(
		CDK_STORE,
		poolId,
		_rollbackRedeemTransform(plr.UserId, code)
	)
	if not ok then
		Log.warn("SystemCDK: RollbackRedeem Update 失败", poolId, err)
		return false
	end
	if type(newData) ~= "table" or type(newData.cdks) ~= "table" then
		Log.warn("SystemCDK: RollbackRedeem 未改写（超时、非本人或码不存在）", poolId, plr.UserId)
		return false
	end
	local entry = newData.cdks[code]
	if type(entry) == "table" and entry.redeemed ~= true then
		return true
	end
	return false
end

return SystemCDK
