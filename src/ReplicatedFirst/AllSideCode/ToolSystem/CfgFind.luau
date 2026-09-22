--[[
	Module: CfgFind
	Description: 配置表查询工具（按 ID/标签/表名查找）；对外一律返回深拷贝，禁止泄漏 ConfigInstance 原表
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-22

	功能：
	- FindCfgByID：按物品 ID + 可选 ItemType 查配置行（item / pet / petegg / gamepass / skill / mount / anime 等）
	- 商城：按 passID、GiftID、OnlyTag 查 itemshopdataConf（启动时建索引，O(1)）
	- GetCfgByName / GetCfgByNameAndID：按 ConfigInstance 表名（及行 ID）取整表或单行
	- GetDailyAward：按轮次 + 天数取签到奖励；GetNowVisionCfg：取 UpdateTime 最新的更新日志行
	- GetOnlineAward / GetOnlineAwardList：在线奖励档位行；IsOnlineTierClaimable 等为双端可领判定
	- GetGamePassItemIDByOnlyTag：由 OnlyTag 取 gamePassItemID（旧名 GetGamePassItemIDByOnlyID 仍可用）
	- GetMountCfg：坐骑/载具行深拷贝，供 Driver 本地扩展 ExtJson

	与相关模块的关系：
	- ConfigInstance：导表纯数据，禁止手改；键名 remap 与 freeze 由 ConfigPrepare 完成
	- ConfigPrepare / Utils.ConfigInstance：首次取配置时已 remap+freeze，本模块只做查询与索引
	- SystemGameConfig：签到最大轮次等全局数值走 SystemGameConfig，不走本模块
	- EnumMgr.ItemType：FindCfgByID 的 chooseType 取值来源；类型→表映射见 _ITEM_TYPE_TO_CONF
	- Copy：查询出口统一 deepCopy；freeze 只保护内存表，不代替拷贝

	FindCfgByID 扩展约定：
	- 新 ItemType 挂已有表：只在 _ITEM_TYPE_TO_CONF 加一行
	- 新独立配置表且走 FindCfgByID：缓存 ConfigInstance 子表后写入 _ITEM_TYPE_TO_CONF；
	  若需 chooseType 为 nil 时兜底扫描，再追加到 _FALLBACK_CONF_ORDER
	- 不走 ItemType 的表：用 GetCfgByName / GetCfgByNameAndID，不必进上述两表

	关键约束：
	- 有明确类型时务必传 chooseType；nil 仅兼容旧调用，跨表 ID 冲突时按 _FALLBACK_CONF_ORDER 前表为准
	- 对外返回深拷贝，调用方可改副本；禁止写回 ConfigInstance
	- 双端可用；配置在模块加载时已准备完毕，无需 Init
	- 历史 API 名保留：GetNowVisionCfg（Vision 非 Version）、FindCfgByPassID_Gift

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local CfgFind = Utils.CfgFind
		local EnumMgr = Utils.EnumMgr

	使用示例：
		-- 按类型查单行（推荐）
		local petCfg = CfgFind.FindCfgByID(petId, EnumMgr.ItemType.Pet)

		-- 按表名 + ID
		local buff = CfgFind.GetCfgByNameAndID("buffdataConf", buffId)

		-- 商城 / 签到 / 在线奖励
		local shop = CfgFind.FindCfgByOnlyTag("LuckX2")
		local award = CfgFind.GetDailyAward(weekId, dayIndex)
		local onlineList = CfgFind.GetOnlineAwardList()

		-- 坐骑/载具（深拷贝，可本地扩展 ExtJson 解析结果）
		local mountCfg = CfgFind.GetMountCfg(6001001)
		local mountByType = CfgFind.FindCfgByID(6001001, EnumMgr.ItemType.Mount)
]]

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local ConfigInstance = Utils.ConfigInstance
local EnumMgr = Utils.EnumMgr
local Copy = Utils.Copy
local SystemGameConfig = Utils.SystemGameConfig

-- ============================================================================
-- 模块定义
-- ============================================================================

local CfgFind = {}

-- ============================================================================
-- 常量
-- ============================================================================

local CFG_NAME_UPDATE_LOG = "updatelogConf"
local DAILY_AWARD_MAX_WEEK_PATH = { "每日签到", "每日签到最大多少轮次" }
local DAILY_AWARD_INDEX_SCALE = 1000

-- ============================================================================
-- 私有变量
-- ============================================================================

local _maxWeekID = SystemGameConfig.GetValue(DAILY_AWARD_MAX_WEEK_PATH)

local _itemdataConf = ConfigInstance.itemdataConf
local _itemshopdataConf = ConfigInstance.itemshopdataConf
local _petConf = ConfigInstance.petConf
local _peteggConf = ConfigInstance.peteggConf
local _dailyawardConf = ConfigInstance.dailyawardConf
local _onlineawardConf = ConfigInstance.onlineawardConf
local _gamepassitemConf = ConfigInstance.gamepassitemConf
local _skillConf = ConfigInstance.skillConf
local _mountConf = ConfigInstance.mountConf
local _animeConf = ConfigInstance.animeConf

-- ItemType → 配置表（多类型可指向同一表）；新增类型只改本表
local _ITEM_TYPE_TO_CONF = {
	[EnumMgr.ItemType.Item] = _itemdataConf,
	[EnumMgr.ItemType.UseItem] = _itemdataConf,
	[EnumMgr.ItemType.Title] = _itemdataConf,
	[EnumMgr.ItemType.Anime] = _animeConf,
	[EnumMgr.ItemType.Pet] = _petConf,
	[EnumMgr.ItemType.PetEgg] = _peteggConf,
	[EnumMgr.ItemType.GamePass] = _gamepassitemConf,
	[EnumMgr.ItemType.Skill] = _skillConf,
	[EnumMgr.ItemType.Mount] = _mountConf,
}

-- chooseType 为 nil 时的扫描顺序（与 _ITEM_TYPE_TO_CONF 覆盖的表对齐，冲突以前表为准）
local _FALLBACK_CONF_ORDER = {
	_itemdataConf,
	_petConf,
	_peteggConf,
	_skillConf,
	_gamepassitemConf,
	_mountConf,
	_animeConf,
}

-- 商城 O(1) 索引（内部持有内存行引用，出口再拷贝）
local _shopByPassID: { [number]: { [any]: any } } = {}
local _shopByOnlyTag: { [string]: { [any]: any } } = {}
local _shopByGiftID: { [number]: { [any]: any } } = {}

if type(_itemshopdataConf) == "table" then
	for _, row in pairs(_itemshopdataConf) do
		if type(row) == "table" then
			local passID = tonumber(row.passID)
			if passID then
				_shopByPassID[passID] = row
			end
			local passIDOld = tonumber(row.passID_old)
			if passIDOld then
				_shopByPassID[passIDOld] = row
			end
			if row.OnlyTag ~= nil and row.OnlyTag ~= "" then
				_shopByOnlyTag[tostring(row.OnlyTag)] = row
			end
			local giftID = tonumber(row.GiftID)
			if giftID then
				_shopByGiftID[giftID] = row
			end
		end
	end
end

-- 签到 O(1) 索引：week * SCALE + index
local _dailyAwardIndex: { [number]: { [any]: any } } = {}
if type(_dailyawardConf) == "table" then
	for _, row in pairs(_dailyawardConf) do
		if type(row) == "table" and row.week ~= nil and row.index ~= nil then
			_dailyAwardIndex[row.week * DAILY_AWARD_INDEX_SCALE + row.index] = row
		end
	end
end

-- 更新日志：UpdateTime 最大的一行（加载时缓存内存引用）
local _nowVisionCfg: { [any]: any }? = nil
do
	local visionCfg = ConfigInstance[CFG_NAME_UPDATE_LOG]
	if type(visionCfg) == "table" then
		local recordTime = 0
		for _, v in pairs(visionCfg) do
			if type(v) == "table" and v.UpdateTime ~= nil and recordTime < v.UpdateTime then
				recordTime = v.UpdateTime
				_nowVisionCfg = v
			end
		end
	end
end

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	深拷贝配置表或配置行，避免调用方拿到 ConfigInstance 原表
	@param cfg table? - 内存配置表/行；非 table 视为无数据
	@return table? - 深拷贝副本；cfg 非 table 时返回 nil（不把 Copy.deepCopy(nil) 的空表泄漏出去）
]]
local function _copyCfg(cfg: { [any]: any }?): { [any]: any }?
	if type(cfg) ~= "table" then
		return nil
	end
	return Copy.deepCopy(cfg)
end

--[[
	在配置子表中按主键取值；number 与数字字符串互通
	@param conf table - 已 remap 的配置子表
	@param id number|string - 调用方传入的主键
	@return table? - 配置行内存引用；无匹配为 nil
]]
local function _getRowById(conf: { [any]: any }, id: number | string): { [any]: any }?
	local row = conf[id]
	if type(row) == "table" then
		return row
	end
	local numId = tonumber(id)
	if numId ~= nil then
		row = conf[numId]
		if type(row) == "table" then
			return row
		end
	end
	local strId = tostring(id)
	if strId ~= id then
		row = conf[strId]
		if type(row) == "table" then
			return row
		end
	end
	return nil
end

-- ============================================================================
-- 公共 API - 配置查找
-- ============================================================================

--[[
	根据 ID 查找配置（类型 → 表映射见 _ITEM_TYPE_TO_CONF）
	@param itemID number - 物品/宠物/宠物蛋/通行证/技能/坐骑等配置 ID
	@param chooseType number? - 物品类型；有明确类型时务必传入。nil 时按 _FALLBACK_CONF_ORDER 依次查（兼容旧调用，跨表 ID 冲突时以前表为准）；
		取值见 EnumMgr.ItemType（Item、UseItem、Title、GamePass、Pet、PetEgg、Skill、Mount）
	@return table? - 配置行深拷贝；字段因表而异（完整字段见 ConfigInstance.key）；无匹配返回 nil
]]
function CfgFind.FindCfgByID(itemID: number, chooseType: number?)
	local numID = tonumber(itemID)
	if not numID then
		return nil
	end

	if chooseType == nil then
		for _, conf in ipairs(_FALLBACK_CONF_ORDER) do
			if type(conf) == "table" then
				local cfg = _getRowById(conf, numID)
				if cfg then
					return _copyCfg(cfg)
				end
			end
		end
		return nil
	end

	local conf = _ITEM_TYPE_TO_CONF[chooseType]
	if type(conf) ~= "table" then
		return nil
	end
	return _copyCfg(_getRowById(conf, numID))
end

--[[
	根据通行证 ID 查找商城配置
	@param passID number - Roblox 通行证 ID（匹配 passID 或 passID_old；二者冲突时后写入的行覆盖）
	@return table? - itemshopdataConf 行深拷贝；字段含 ZhName、OnlyTag、passID、gamePassItemID、price、itemID、itemCount、Icon 等
]]
function CfgFind.FindCfgByPassID(passID: number)
	local numPassID = tonumber(passID)
	if not numPassID then
		return nil
	end
	return _copyCfg(_shopByPassID[numPassID])
end

--[[
	根据通行证礼品 ID 查找商城配置
	@param giftID number - 礼品 ID（对应 itemshopdataConf.GiftID）
	@return table? - itemshopdataConf 行深拷贝；字段含 ZhName、OnlyTag、GiftID、gamePassItemID、price 等
]]
function CfgFind.FindCfgByPassID_Gift(giftID: number)
	local numGiftID = tonumber(giftID)
	if not numGiftID then
		return nil
	end
	return _copyCfg(_shopByGiftID[numGiftID])
end

--[[
	根据唯一标签查找商城配置
	@param onlyTag string - 商城条目唯一标签（itemshopdataConf.OnlyTag）
	@return table? - itemshopdataConf 行深拷贝；字段含 ZhName、OnlyTag、passID、gamePassItemID、price 等
]]
function CfgFind.FindCfgByOnlyTag(onlyTag: string)
	return _copyCfg(_shopByOnlyTag[tostring(onlyTag)])
end

--[[
	根据唯一标签获取游戏通行证物品 ID
	@param onlyTag string - 商城条目唯一标签（itemshopdataConf.OnlyTag）
	@return number|string? - gamePassItemID；空字符串或未找到时返回 nil
]]
function CfgFind.GetGamePassItemIDByOnlyTag(onlyTag: string)
	local row = _shopByOnlyTag[tostring(onlyTag)]
	if not row then
		return nil
	end
	if row.gamePassItemID ~= nil and row.gamePassItemID ~= "" then
		return row.gamePassItemID
	end
	return nil
end

-- 兼容旧名
CfgFind.GetGamePassItemIDByOnlyID = CfgFind.GetGamePassItemIDByOnlyTag

-- ============================================================================
-- 公共 API - 配置获取
-- ============================================================================

--[[
	根据名称获取整张配置表
	@param name string|number - ConfigInstance 表名，如 itemdataConf、settingConf
	@return table? - 配置表深拷贝（{ [id]: row }）；调用方可改副本，不影响内存配置
]]
function CfgFind.GetCfgByName(name: string | number)
	return _copyCfg(ConfigInstance[name])
end

--[[
	根据名称和 ID 获取单条配置
	@param name string|number - ConfigInstance 表名
	@param id number|string - 配置行主键 ID（number 与数字字符串互通）
	@return table? - 配置行深拷贝；字段结构见 ConfigInstance.key 对应表映射
]]
function CfgFind.GetCfgByNameAndID(name: string | number, id: number | string)
	local conf = ConfigInstance[name]
	if type(conf) ~= "table" then
		return nil
	end
	return _copyCfg(_getRowById(conf, id))
end

--[[
	获取当前版本更新日志配置（UpdateTime 最大的一条，模块加载时缓存）
	@return table? - updatelogConf 行深拷贝；字段含 UpdateTime 等
]]
function CfgFind.GetNowVisionCfg()
	return _copyCfg(_nowVisionCfg)
end

--[[
	根据轮次和天数索引获取每日签到奖励配置
	@param weekId number - 当前轮次；超过 SystemGameConfig 最大轮次时钳制为上限
	@param index number - 该轮次第几天（1-7）
	@return table? - dailyawardConf 行深拷贝；字段含 index、week、AwardID、CountID 等；无匹配返回 nil
]]
function CfgFind.GetDailyAward(weekId: number, index: number)
	local numWeek = tonumber(weekId)
	local numIndex = tonumber(index)
	if not numWeek or not numIndex then
		return nil
	end
	if type(_maxWeekID) == "number" and numWeek > _maxWeekID then
		numWeek = _maxWeekID
	end
	return _copyCfg(_dailyAwardIndex[numWeek * DAILY_AWARD_INDEX_SCALE + numIndex])
end

--[[
	获取坐骑/载具配置行（深拷贝，供 Driver 可变扩展；禁止写回 ConfigInstance）
	@param mountId number|string - mountConf 主键 ID
	@return table? - 配置行副本；无匹配返回 nil
]]
function CfgFind.GetMountCfg(mountId: number | string)
	if type(_mountConf) ~= "table" then
		return nil
	end
	return _copyCfg(_getRowById(_mountConf, mountId))
end

local ONLINE_STATE_CLAIMED = 1

--[[
	按档位获取在线奖励配置
	@param tierId number - onlineawardConf 主键
	@return table? - 行副本（深拷贝）；字段含 AwardID、CountID、OnlinTime、Icon；无匹配为 nil
]]
function CfgFind.GetOnlineAward(tierId: number): { [string]: any }?
	local numId = tonumber(tierId)
	if not numId then
		return nil
	end
	if type(_onlineawardConf) ~= "table" then
		return nil
	end
	return _copyCfg(_getRowById(_onlineawardConf, numId))
end

--[[
	获取全部在线奖励配置（附带 id 字段，按 id 升序）
	@return { { [string]: any } } - 行深拷贝列表；无表时为空数组
]]
function CfgFind.GetOnlineAwardList(): { { [string]: any } }
	local list: { { [string]: any } } = {}
	if type(_onlineawardConf) ~= "table" then
		return list
	end
	local ids: { number } = {}
	for id in pairs(_onlineawardConf) do
		local numId = tonumber(id)
		if numId then
			table.insert(ids, numId)
		end
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local copy = _copyCfg(_onlineawardConf[id])
		if copy then
			copy.id = id
			table.insert(list, copy)
		end
	end
	return list
end

--[[
	档位是否已领取
	@param onlineSave table? - OnlineBox
	@param tierId number - 档位 id
	@return boolean - 已领为 true
]]
function CfgFind.IsOnlineTierClaimed(onlineSave: { [any]: any }?, tierId: number): boolean
	if type(onlineSave) ~= "table" or not tierId then
		return false
	end
	local tierData = onlineSave[tostring(tierId)]
	return type(tierData) == "table" and tonumber(tierData.State) == ONLINE_STATE_CLAIMED
end

--[[
	档位当前是否可领（未领 且 时长达标或该档 Unlock=1）
	@param onlineSave table? - OnlineBox：OnlineSeconds / [tierId]={ State|Unlock }
	@param cfg table - onlineawardConf 行（须含 id / OnlinTime）
	@return boolean - 可领为 true
]]
function CfgFind.IsOnlineTierClaimable(onlineSave: { [any]: any }?, cfg: { [string]: any }): boolean
	if type(onlineSave) ~= "table" or type(cfg) ~= "table" then
		return false
	end
	local tierId = tonumber(cfg.id)
	if not tierId or CfgFind.IsOnlineTierClaimed(onlineSave, tierId) then
		return false
	end
	local tierData = onlineSave[tostring(tierId)]
	if type(tierData) == "table" and tonumber(tierData.Unlock) == 1 then
		return true
	end
	local need = tonumber(cfg.OnlinTime) or 0
	local seconds = tonumber(onlineSave.OnlineSeconds) or 0
	return seconds >= need
end

--[[
	根据 OnlineBox 存档判断是否存在可领取档位（纯查询，双端可用）
	@param onlineSave table? - OnlineBox：OnlineSeconds / [tierId]={ State|Unlock }
	@return boolean - 有可领档位为 true
]]
function CfgFind.HasClaimableOnlineAward(onlineSave: { [any]: any }?): boolean
	return CfgFind.CountClaimableOnlineAward(onlineSave) > 0
end

--[[
	根据 OnlineBox 存档统计可领取档位数量（纯查询，双端可用）
	@param onlineSave table? - OnlineBox：OnlineSeconds / [tierId]={ State=1已领 | Unlock=1付费可领 }
	@return number - 可领档位数（≥0）
]]
function CfgFind.CountClaimableOnlineAward(onlineSave: { [any]: any }?): number
	if type(onlineSave) ~= "table" then
		return 0
	end
	local count = 0
	local list = CfgFind.GetOnlineAwardList()
	for _, cfg in ipairs(list) do
		if CfgFind.IsOnlineTierClaimable(onlineSave, cfg) then
			count += 1
		end
	end
	return count
end

return CfgFind
