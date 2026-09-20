--[[
	Module: ShowDetail-Type
	Description: ShowDetail 类型声明（完整使用说明见 ToolSystem/ShowDetail.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01
]]

local ShowDetail = {}

type StructItem = {
	id: number,
	tp: number,
	onlyID: number,
	lock: number,
	count: number,
}

type DetailDisplayData = { [string]: any }

--[[
	隐藏所有详情框并重置模块内展示状态
	@return nil - 无返回值
]]
function ShowDetail.HideAllDetail(): nil
end

--[[
	查询指定类型详情框是否可见
	@param tp number - 物品类型 id
	@return boolean - 存在且可见时 true
]]
function ShowDetail.GetDetailVisible(tp: number): boolean
end

--[[
	根据配置 id 显示详情
	@param cfgID number - CfgFind 配置表 id
	@param anchorFrame Frame - 参考控件
	@return nil - 无返回值
]]
function ShowDetail.ShowDetailByCfgID(cfgID: number, anchorFrame: Frame): nil
end

--[[
	根据背包 onlyID 显示详情
	@param onlyID number - 背包条目唯一 id
	@param anchorFrame Frame - 参考控件
	@param useFixedPos boolean? - true 时固定锚点
	@return nil - 无返回值
]]
function ShowDetail.ShowDetail(onlyID: number, anchorFrame: Frame, useFixedPos: boolean?): nil
end

--[[
	根据背包 onlyID 悬停显示详情
	@param onlyID number - 背包条目唯一 id
	@param anchorFrame Frame - 参考控件
	@param useFixedPos boolean? - true 时固定锚点
	@return nil - 无返回值
]]
function ShowDetail.HoldShow(onlyID: number, anchorFrame: Frame, useFixedPos: boolean?): nil
end

--[[
	根据外部数据悬停显示详情
	@param onlyID number - toggle 判定用逻辑 id
	@param anchorFrame Frame - 参考控件
	@param frameName string - 详情子 Frame 名称
	@param displayData DetailDisplayData - 子 ModuleScript 展示数据
	@param useFixedPos boolean? - true 时固定锚点
	@return nil - 无返回值
]]
function ShowDetail.HoldShowByData(
	onlyID: number,
	anchorFrame: Frame,
	frameName: string,
	displayData: DetailDisplayData,
	useFixedPos: boolean?
): nil
end

--[[
	显示带附加特殊数据的详情
	@param onlyID number - 背包条目唯一 id
	@param anchorFrame Frame - 参考控件
	@param frameName string - 详情子 Frame 名称
	@param useFixedPos boolean? - true 时固定锚点
	@param specialData DetailDisplayData - 附加展示数据
	@return nil - 无返回值
]]
function ShowDetail.ShowDetailSpecial(
	onlyID: number,
	anchorFrame: Frame,
	frameName: string,
	useFixedPos: boolean?,
	specialData: DetailDisplayData
): nil
end

--[[
	根据 Struct.Item 数据对象显示详情
	@param itemData StructItem - 背包条目
	@param anchorFrame Frame - 参考控件
	@param frameName string - 详情子 Frame 名称
	@param useFixedPos boolean? - true 时固定锚点
	@param ... any - 透传子 ModuleScript 的额外参数
	@return nil - 无返回值
]]
function ShowDetail.ShowDetailByData(
	itemData: StructItem,
	anchorFrame: Frame,
	frameName: string,
	useFixedPos: boolean?,
	...: any
): nil
end

--[[
	显示 GamePass 说明详情
	@param plr Player - 目标玩家
	@param passTag string - GamePass 配置标签
	@param anchorFrame Frame - 参考控件
	@return nil - 无返回值
]]
function ShowDetail.ShowGamePassDetail(plr: Player, passTag: string, anchorFrame: Frame): nil
end

--[[
	隐藏指定 GamePass 标签的详情
	@param passTag string - GamePass 配置标签
	@return nil - 无返回值
]]
function ShowDetail.HideGamePassDetail(passTag: string): nil
end

return ShowDetail
