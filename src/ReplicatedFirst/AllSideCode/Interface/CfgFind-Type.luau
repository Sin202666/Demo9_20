--[[
	Module: CfgFind-Type
	Description: CfgFind 类型声明（完整使用说明见 ToolSystem/CfgFind.luau 文件头）
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-09-04
]]

local CfgFind = {}

--[[
	根据 ID 查找配置
	@param itemID number - 物品/宠物/宠物蛋/通行证/技能/坐骑等配置 ID
	@param chooseType number? - 物品类型；有明确类型时务必传入。nil 时依次查 item / pet / petegg / skill / gamepass / mount；
		取值见 EnumMgr.ItemType（Item、UseItem、Title、GamePass、Pet、PetEgg、Skill、Mount）
	@return table? - 配置行深拷贝
]]
function CfgFind.FindCfgByID(itemID: number, chooseType: number?): { [string]: any }?
end

--[[
	根据通行证 ID 查找商城配置
	@param passID number - Roblox 通行证 ID
	@return table? - itemshopdataConf 行深拷贝
]]
function CfgFind.FindCfgByPassID(passID: number): { [string]: any }?
end

--[[
	根据通行证礼品 ID 查找商城配置
	@param giftID number - 礼品 ID
	@return table? - itemshopdataConf 行深拷贝
]]
function CfgFind.FindCfgByPassID_Gift(giftID: number): { [string]: any }?
end

--[[
	根据唯一标签查找商城配置
	@param onlyTag string - 商城条目唯一标签
	@return table? - itemshopdataConf 行深拷贝
]]
function CfgFind.FindCfgByOnlyTag(onlyTag: string): { [string]: any }?
end

--[[
	根据唯一标签获取游戏通行证物品 ID
	@param onlyTag string - 商城条目唯一标签
	@return number|string? - gamePassItemID；空字符串或未找到时返回 nil
]]
function CfgFind.GetGamePassItemIDByOnlyTag(onlyTag: string): number | string?
end

--[[
	兼容旧名，等同 GetGamePassItemIDByOnlyTag
	@param onlyTag string - 商城条目唯一标签
	@return number|string? - gamePassItemID
]]
function CfgFind.GetGamePassItemIDByOnlyID(onlyTag: string): number | string?
end

--[[
	根据名称获取整张配置表
	@param name string|number - ConfigInstance 表名
	@return table? - 配置表深拷贝（{ [id]: row }）
]]
function CfgFind.GetCfgByName(name: string | number): { [any]: any }?
end

--[[
	根据名称和 ID 获取单条配置
	@param name string|number - ConfigInstance 表名
	@param id number|string - 配置行主键 ID（number 与数字字符串互通）
	@return table? - 配置行深拷贝
]]
function CfgFind.GetCfgByNameAndID(name: string | number, id: number | string): { [string]: any }?
end

--[[
	获取当前版本更新日志配置
	@return table? - updatelogConf 行深拷贝（UpdateTime 最大的一条）
]]
function CfgFind.GetNowVisionCfg(): { [string]: any }?
end

--[[
	根据轮次和天数索引获取每日签到奖励配置
	@param weekId number - 当前轮次
	@param index number - 该轮次第几天
	@return table? - dailyawardConf 行深拷贝
]]
function CfgFind.GetDailyAward(weekId: number, index: number): { [string]: any }?
end

--[[
	获取坐骑/载具配置行（深拷贝）
	@param mountId number|string - mountConf 主键 ID
	@return table? - 配置行副本
]]
function CfgFind.GetMountCfg(mountId: number | string): { [string]: any }?
end

--[[
	按档位获取在线奖励配置
	@param tierId number - onlineawardConf 主键
	@return table? - 行深拷贝；无匹配为 nil
]]
function CfgFind.GetOnlineAward(tierId: number): { [string]: any }?
end

--[[
	获取全部在线奖励配置（附带 id，升序）
	@return { { [string]: any } } - 行深拷贝列表
]]
function CfgFind.GetOnlineAwardList(): { { [string]: any } }
end

--[[
	档位是否已领取
	@param onlineSave table? - OnlineBox
	@param tierId number - 档位 id
	@return boolean - 已领为 true
]]
function CfgFind.IsOnlineTierClaimed(onlineSave: { [any]: any }?, tierId: number): boolean
end

--[[
	档位当前是否可领（未领 且 时长达标或 Unlock=1）
	@param onlineSave table? - OnlineBox
	@param cfg table - onlineawardConf 行（须含 id / OnlinTime）
	@return boolean - 可领为 true
]]
function CfgFind.IsOnlineTierClaimable(onlineSave: { [any]: any }?, cfg: { [string]: any }): boolean
end

--[[
	根据 OnlineBox 判断是否存在可领取档位
	@param onlineSave table? - OnlineBox
	@return boolean - 有可领档位为 true
]]
function CfgFind.HasClaimableOnlineAward(onlineSave: { [any]: any }?): boolean
end

--[[
	根据 OnlineBox 统计可领取档位数量
	@param onlineSave table? - OnlineBox
	@return number - 可领档位数（≥0）
]]
function CfgFind.CountClaimableOnlineAward(onlineSave: { [any]: any }?): number
end

return CfgFind
