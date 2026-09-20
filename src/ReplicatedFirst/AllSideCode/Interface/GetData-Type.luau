--[[
	Module: GetData-Type
	Description: GetData 类型声明（完整使用说明见 ToolSystem/GetData/init.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-04
]]

local Bag = {}
local BagEntry = {}
local BagCapacity = {}
local BagViewFilter = {}
local BagView = {
	Filter = BagViewFilter,
}
local PlayerMirror = {}
local Combat = {}
local GetData = {
	Bag = Bag,
	Entry = BagEntry,
	BagCapacity = BagCapacity,
	BagView = BagView,
	Mirror = PlayerMirror,
	Combat = Combat,
}

--[[
	客户端获取物品数量（通过 id）
	@param itemID number - 物品 id
	@return number? - 物品数量；非客户端调用返回 nil
]]
function Bag.GetItemCountByIDOnClient(itemID: number): number?
end

--[[
	获取玩家背包或 Shard 内物品数量
	@param plr Player - 玩家对象
	@param itemID number - 物品 id
	@return number - 物品数量；未找到为 0
]]
function Bag.GetItemCountByID(plr: Player, itemID: number): number
end

--[[
	等待背包数值 Instance 出现
	@param plr Player - 玩家对象
	@param itemID number - 物品 id
	@return NumberValue - Bag 下对应 NumberValue
]]
function Bag.WaitBagNumberValue(plr: Player, itemID: number): NumberValue
end

--[[
	等待玩家 RedPoint 文件夹下指定红点 NumberValue
	@param plr Player - 玩家对象
	@param redName string - 红点名，如「在线奖励红点」
	@return NumberValue - 对应 NumberValue
]]
function PlayerMirror.WaitRedPointValue(plr: Player, redName: string): NumberValue
end

--[[
	读取玩家红点当前数值（文件夹未就绪时为 0）
	@param plr Player - 玩家对象
	@param redName string - 红点名
	@return number - 红点数值（≥0）
]]
function PlayerMirror.GetRedPointValue(plr: Player, redName: string): number
end

--[[
	根据 onlyID 获取背包条目与配置（条目深拷贝，配置冻结引用）
	@param onlyID number - 背包条目 onlyID
	@param bagData table? - 可选 Bag 数组；省略时客户端从 LocalPlayer 读取
	@return table? - 背包条目深拷贝
	@return table? - 配置行冻结引用
]]
function BagEntry.GetDataAndCfg(onlyID: number, bagData: { any }?): ({ [string]: any }?, { [string]: any }?)
end

BagCapacity.Stack = {
	Default = "Default",
}

BagCapacity.Capacity = {
	None = "None",
	Warehouse = "Warehouse",
	Pet = "Pet",
	Backpack = "Backpack",
}

BagCapacity.Filter = {
	Window = "Window",
	Toolbar = "Toolbar",
}

BagCapacity.Tab = {
	All = "All",
	Potion = "Potion",
	Material = "Material",
}

--[[
	判断配置是否按指定堆叠策略可叠加（省略策略时用 Stack.Default）
	@param cfg table? - 物品配置行，字段含 hasCount: number?
	@param stackName string? - BagCapacity.Stack 键；默认 Default
	@return boolean - 是否可叠加；未知策略或配置无效为 false
]]
function BagCapacity.IsStackable(cfg: any, stackName: string?): boolean
end

--[[
	策略名是否在闭集表中
	@param policyName any - 容量策略名
	@return boolean - 是否为已登记键（含未启用的 Warehouse / Pet）
]]
function BagCapacity.HasCapacityPolicy(policyName: any): boolean
end

--[[
	把调用方传入的策略名收成闭集键；nil / 空串视为 None
	@param policyName string? - opts.capacity 或查询用策略名
	@return string? - 合法键；未知名为 nil
]]
function BagCapacity.ResolvePolicy(policyName: string?): string?
end

--[[
	读取策略格子上限；nil 表示不检满仓
	@param policyName string? - 容量策略名；非法或省略视为 None
	@return number? - 最大占用格数；不拦为 nil
]]
function BagCapacity.GetMaxSlots(policyName: string?): number?
end

--[[
	统计背包当前占用格数（字典条目数，含 count==0 的残留格）
	@param bagData table? - PlayerData.Bag 字典
	@return number - 占用格数；无效表为 0
]]
function BagCapacity.CountSlots(bagData: any): number
end

--[[
	加入一批数量后相对当前占用会新增的格子数（堆叠进已有格为 0）
	@param bagData table? - 当前 Bag 字典
	@param itemId number - 物品 id
	@param addCount number - 计划加入数量
	@param cfg table? - 物品配置行
	@param pendingNewStacks { [number]: boolean }? - 同批次已记入的新建堆叠；可省略
	@return number - 新增格数（≥0）
]]
function BagCapacity.GetAddSlotDelta(
	bagData: any,
	itemId: number,
	addCount: number,
	cfg: any,
	pendingNewStacks: { [number]: boolean }?
): number
end

--[[
	单次加入是否会超过策略上限（max 为 nil 时永不超）
	@param bagData table? - 当前 Bag 字典
	@param itemId number - 物品 id
	@param addCount number - 计划加入数量
	@param cfg table? - 物品配置行
	@param policyName string? - 容量策略名
	@return boolean - 会超限为 true
]]
function BagCapacity.WouldExceed(
	bagData: any,
	itemId: number,
	addCount: number,
	cfg: any,
	policyName: string?
): boolean
end

--[[
	批量加入是否会超过策略上限（先模拟整批再判定）
	@param bagData table? - 当前 Bag 字典
	@param items { { id: number, count: number, cfg: any } } - 仅含已有配置的项
	@param policyName string? - 容量策略名
	@return boolean - 会超限为 true
]]
function BagCapacity.WouldExceedBatch(bagData: any, items: { any }, policyName: string?): boolean
end

--[[
	快捷栏槽数（Bag.equip 1~N）
	@return number - 槽数，钳制在 1~9
]]
function BagCapacity.GetToolbarSlotCount(): number
end

--[[
	equip 是否落在快捷栏 1~N
	@param equip any - Bag.equip
	@return boolean - 在栏为 true
]]
function BagCapacity.IsToolbarEquipSlot(equip: any): boolean
end

--[[
	条目 tp 是否属于闭集 Filter
	@param filterName string - BagCapacity.Filter 键
	@param tp any - 物品类型
	@return boolean - 属于该 Filter 为 true
]]
function BagCapacity.IsFilterType(filterName: string, tp: any): boolean
end

--[[
	闭集 Filter 的类型列表深拷贝
	@param filterName string - BagCapacity.Filter 键
	@return { number } - 类型枚举数组
]]
function BagCapacity.GetFilterTypes(filterName: string): { number }
end

--[[
	页签 id 是否在 Tabs 闭集中
	@param tabId any - Place 页签 Frame.Name
	@return boolean - 已登记为 true
]]
function BagCapacity.HasTab(tabId: any): boolean
end

--[[
	页签 id 列表深拷贝（All / Potion / Material）
	@return { string } - 闭集页签 id
]]
function BagCapacity.GetTabIds(): { string }
end

--[[
	条目 tp 是否属于该页签（All = Filter.Window）
	@param tabId string - BagCapacity.Tab 键
	@param tp any - 物品类型
	@return boolean - 属于该页签为 true
]]
function BagCapacity.IsTabType(tabId: string, tp: any): boolean
end

--[[
	页签类型列表深拷贝；All 返回 Window 类型
	@param tabId string - BagCapacity.Tab 键
	@return { number } - 类型枚举数组
]]
function BagCapacity.GetTabTypes(tabId: string): { number }
end

--[[
	Window 白名单占用（可叠按 count，其余一行 1）
	@param bagData table? - PlayerData.Bag 字典
	@param cfgById ((number) -> any)? - 可选配置查找
	@return number - 占用值
]]
function BagCapacity.CountWindowOccupancy(bagData: any, cfgById: ((number) -> any)?): number
end

--[[
	策略占用：Backpack 走 Window 占用，其余走字典格数
	@param bagData table? - PlayerData.Bag 字典
	@param policyName string? - 容量策略名
	@param cfgById ((number) -> any)? - Backpack 占用查配置用
	@return number - 占用值
]]
function BagCapacity.CountOccupancy(bagData: any, policyName: string?, cfgById: ((number) -> any)?): number
end

--[[
	Backpack 策略 Window 占用增量
	@param bagData table? - 当前 Bag 字典
	@param itemId number - 物品 id
	@param addCount number - 计划加入数量
	@param cfg table? - 物品配置行
	@return number - 占用增量
]]
function BagCapacity.GetAddWindowOccupancyDelta(bagData: any, itemId: number, addCount: number, cfg: any): number
end

--[[
	按物品类型过滤（返回谓词，交给 Query）
	@param tp number - 物品类型，对齐 EnumMgr.ItemType / 条目 tp
	@return (any) -> boolean - 匹配该 tp 的条目谓词
]]
function BagViewFilter.ByType(tp: number): (any) -> boolean
end

--[[
	配置 isShow == InBag 的条目（不是任何窗的默认数据源）
	@param entry table - 背包条目，字段含 id / tp
	@return boolean - 是否在背包中展示
]]
function BagViewFilter.AllShowInBag(entry: any): boolean
end

--[[
	窗白名单类型
	@param entry table - 背包条目
	@return boolean - Filter.Window 为 true
]]
function BagViewFilter.Window(entry: any): boolean
end

--[[
	栏白名单类型
	@param entry table - 背包条目
	@return boolean - Filter.Toolbar 为 true
]]
function BagViewFilter.Toolbar(entry: any): boolean
end

--[[
	仓库网格：Window 且未上栏
	@param entry table - 背包条目
	@return boolean - 进仓库网格为 true
]]
function BagViewFilter.WarehouseGrid(entry: any): boolean
end

--[[
	从玩家或 Bag 表查出条目深拷贝列表（按 onlyID 升序）
	@param bagCopyOrPlr Player | table - 玩家对象，或已有 Bag 字典（不会写回）
	@param filter ((any) -> boolean)? - 谓词；nil 表示不过滤
	@return { table } - 条目深拷贝数组；无效输入为空表
]]
function BagView.Query(bagCopyOrPlr: any, filter: ((any) -> boolean)?): { any }
end

--[[
	只读占用：当前格数与策略上限（上限 nil 表示不检满仓）
	@param plr Player - 玩家对象
	@param policyName string? - BagCapacity.Capacity 键；nil 视为 None
	@return table - 深拷贝 { used: number, max: number? }
]]
function BagView.Occupancy(plr: Player, policyName: string?): { [string]: any }
end

--[[
	只读：加入 1 个该物品是否会满（策略无上限则为 false）
	@param plr Player - 玩家对象
	@param itemId number - 物品 id
	@param policyName string? - BagCapacity.Capacity 键；nil 视为 None
	@return boolean - 视为满仓为 true；玩家/配置无效为 false
]]
function BagView.IsFull(plr: Player, itemId: number, policyName: string?): boolean
end

--[[
	条目 → 格子 VM（id/tp/count/onlyID/lock/equip），深拷贝
	@param entry table - 背包条目或已有拷贝
	@return table? - VM 深拷贝；entry 无效为 nil
]]
function BagView.ToSlotVM(entry: any): { [string]: any }?
end

--[[
	译名搜索：TranslateByKey(ZhName) 子串；失败（未本地化/空）不回退中文键
	@param entry table - 背包条目
	@param searchText string? - 搜索原文；nil/空串视为全匹配
	@return boolean - 命中为 true
]]
function BagView.MatchesSearch(entry: any, searchText: string?): boolean
end

--[[
	仓库网格查询：Window 且未上栏；可选类型页签与译名搜索
	@param bagCopyOrPlr Player | table - 玩家或 Bag 字典
	@param tabTp number? - 页签类型；nil 表示 All
	@param searchText string? - 译名子串
	@return { table } - 条目深拷贝数组
]]
function BagView.QueryWarehouse(bagCopyOrPlr: any, tabTp: number?, searchText: string?): { any }
end

--[[
	读取快捷栏某槽物品
	@param bagCopyOrPlr Player | table - 玩家或 Bag 字典
	@param slotIndex number - 槽 1~N
	@return table? - 条目深拷贝；空槽为 nil
]]
function BagView.QueryToolbarSlot(bagCopyOrPlr: any, slotIndex: number): any?
end

--[[
	第一个空快捷槽；无空位为 0
	@param bagCopyOrPlr Player | table - 玩家或 Bag 字典
	@return number - 空槽 1~N；无空位 0
]]
function BagView.GetFirstFreeToolbarSlot(bagCopyOrPlr: any): number
end

--[[
	PLAYER_DATA_SYNC 是否应刷新快捷栏
	@param key string | { string }? - 同步路径
	@param value any - 同步值
	@param plr Player? - 玩家
	@param toolbarCachedOnlyIds { [number]: number }? - 槽 → onlyID 缓存
	@return boolean - 需要刷新为 true
]]
function BagView.ShouldRefreshToolbarOnPlayerDataSync(
	key: string | { string }?,
	value: any,
	plr: Player?,
	toolbarCachedOnlyIds: { [number]: number }?
): boolean
end

--[[
	PLAYER_DATA_SYNC 是否应刷新仓库网格
	@param key string | { string }? - 同步路径
	@param value any - 同步值
	@param plr Player? - 玩家
	@param toolbarCachedOnlyIds { [number]: number }? - 预留
	@param warehouseCachedOnlyIds { [number]: boolean }? - 仓库 onlyID 缓存
	@return boolean - 需要刷新为 true
]]
function BagView.ShouldRefreshWarehouseOnPlayerDataSync(
	key: string | { string }?,
	value: any,
	plr: Player?,
	toolbarCachedOnlyIds: { [number]: number }?,
	warehouseCachedOnlyIds: { [number]: boolean }?
): boolean
end

--[[
	读取玩家设置项数值
	@param plr Player - 玩家对象
	@param setName string - 设置项 ShowName
	@return number? - 设置值；未找到为 nil
]]
function PlayerMirror.GetSetting(plr: Player, setName: string): number?
end

--[[
	检查玩家是否拥有指定 GamePass
	@param plr Player - 玩家对象
	@param onlyTag string - 通行证唯一标签
	@return boolean - 是否拥有
]]
function PlayerMirror.IsHasPass(plr: Player, onlyTag: string): boolean
end

--[[
	战斗系统总开关
	@return boolean - false 时伤害/无敌/Buff 权威路径应 no-op
]]
function Combat.IsCombatEnabled(): boolean
end

--[[
	写入会话战斗属性 NumberValue（仅服务端 SystemPlrAttr 应调用）
	@param target any - Player 或角色 Model
	@param attr string - EnumMgr.PlrAttr 键
	@param value number - 写入值
]]
function Combat.SetPlrAttr(target: any, attr: string, value: number)
end

--[[
	读取会话战斗属性
	@param target any - Player 或角色 Model
	@param attr string - EnumMgr.PlrAttr 键
	@return number - 属性值或默认
]]
function Combat.GetPlrAttr(target: any, attr: string): number
end

--[[
	GetPlrAttr 旧名别名
	@param target any - Player 或角色 Model
	@param attr string - EnumMgr.PlrAttr 键
	@return number - 属性值或默认
]]
function Combat.GetPlrAttrValue(target: any, attr: string): number
end

--[[
	玩家是否处于闪避无敌窗
	@param plr Player - 玩家
	@return boolean - 无敌中为 true
]]
function Combat.IsPlrDodgeInvincible(plr: Player): boolean
end

--[[
	技能纯度 → 伤害倍率
	@param skillPurity any - 纯度 0～1；非数字或 nil 按 1
	@return number - 伤害倍率 ∈ [0.5, 1]
]]
function Combat.GetSkillPurityDamageRateMul(skillPurity: any): number
end

--[[
	计算伤害（finalDamage 须为服预结算）
	@param atk any - 攻击方 Player 或 Model
	@param beHit any? - 受击 Player/Model；nil 为可破坏物
	@param hitData table? - finalDamage / isCrit / damageRate / skillPurity / eleTp
	@return number - 非负整数伤害
	@return boolean - 是否暴击
]]
function Combat.GetDmg(atk: any, beHit: any?, hitData: any?): (number, boolean)
end

-- 门面扁平 API（与子模块同签名，由 init 聚合）
function GetData.GetItemCountByIDOnClient(itemID: number): number?
end

function GetData.GetItemCountByID(plr: Player, itemID: number): number
end

function GetData.WaitBagNumberValue(plr: Player, itemID: number): NumberValue
end

--[[
	等待玩家 RedPoint 文件夹下指定红点 NumberValue
	@param plr Player - 玩家对象
	@param redName string - 红点名，如「在线奖励红点」
	@return NumberValue - 对应 NumberValue
]]
function GetData.WaitRedPointValue(plr: Player, redName: string): NumberValue
end

--[[
	读取玩家红点当前数值（文件夹未就绪时为 0）
	@param plr Player - 玩家对象
	@param redName string - 红点名
	@return number - 红点数值（≥0）
]]
function GetData.GetRedPointValue(plr: Player, redName: string): number
end

function GetData.GetDataAndCfg(onlyID: number, bagData: { any }?): ({ [string]: any }?, { [string]: any }?)
end

function GetData.GetSetting(plr: Player, setName: string): number?
end

function GetData.IsHasPass(plr: Player, onlyTag: string): boolean
end

function GetData.IsCombatEnabled(): boolean
end

function GetData.SetPlrAttr(target: any, attr: string, value: number)
end

function GetData.GetPlrAttr(target: any, attr: string): number
end

function GetData.GetPlrAttrValue(target: any, attr: string): number
end

function GetData.IsPlrDodgeInvincible(plr: Player): boolean
end

function GetData.GetSkillPurityDamageRateMul(skillPurity: any): number
end

function GetData.GetDmg(atk: any, beHit: any?, hitData: any?): (number, boolean)
end

function GetData.IsPlrInPotionFlow(_plr: Player): boolean
end

function GetData.GetIsFly(_plr: Player): boolean
end

function GetData.GetSkillMpTierEffects(_mpTp: string?): { damageRateMul: number }
end

function GetData.GetSkillMpTierDamageRateMul(mpTp: string?): number
end

export type Bag = typeof(Bag)
export type Entry = typeof(BagEntry)
export type BagCapacity = typeof(BagCapacity)
export type BagView = typeof(BagView)
export type Mirror = typeof(PlayerMirror)
export type Combat = typeof(Combat)

return GetData
