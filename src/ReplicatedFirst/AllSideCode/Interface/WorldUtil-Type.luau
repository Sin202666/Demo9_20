--[[
	Module: WorldUtil-Type
	Description: WorldUtil 类型声明（完整使用说明见 ToolSystem/WorldUtil.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01
]]

local WorldUtil = {}

--[[
	获取当前服务器类型（Dev 或 Official）
	@return string - "Dev" 或 "Official"；未匹配 PlaceId 时为 "Official"
]]
function WorldUtil.GetServerType(): string
end

--[[
	获取当前世界 ID
	@return number - PLACE_ID_INFO 命中的世界 ID；未匹配时为 1
]]
function WorldUtil.GetCurWorld(): number
end

--[[
	获取当前场景 ID（由服务器类型映射，不是独立配置）
	Dev → 1，Official → 2
	@return number - 场景 ID（1 或 2）
]]
function WorldUtil.GetSceneId(): number
end

--[[
	注册私人服务器 owner 通信（仅服务端；可重复调用，仅首次生效）
	@return nil - 非服务端或已注册时直接返回
]]
function WorldUtil.RegisterNetWork()
end

return WorldUtil
