--[[
	Module: SystemInput.LocalBindingSave
	Description: 客户端键位存档加载/保存（经 SystemInputBind Remote）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-01
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork

local LocalBindingSave = {}

--[[
	从服务端拉取并应用到 BindingStore
	@param bindingStore any - BindingStore 实例（ApplySerialized）
	@return boolean - 成功为 true
]]
function LocalBindingSave.LoadAndApply(bindingStore: any): boolean
	local ok, result = pcall(function()
		return NetWork.InvokeServer(NetMsg.INPUT_BINDINGS_GET)
	end)
	if not ok then
		Log.warn("[SystemInput.LocalBindingSave] GET failed:", result)
		return false
	end
	if type(result) ~= "table" then
		return false
	end
	bindingStore:ApplySerialized(result)
	return true
end

--[[
	将 BindingStore 序列化上送存档
	@param bindingStore any - BindingStore 实例（Serialize）
	@return boolean - 成功为 true
]]
function LocalBindingSave.SaveFromStore(bindingStore: any): boolean
	local payload = bindingStore:Serialize()
	local ok, result = pcall(function()
		return NetWork.InvokeServer(NetMsg.INPUT_BINDINGS_SET, payload)
	end)
	if not ok then
		Log.warn("[SystemInput.LocalBindingSave] SET failed:", result)
		return false
	end
	return result == true
end

return LocalBindingSave
