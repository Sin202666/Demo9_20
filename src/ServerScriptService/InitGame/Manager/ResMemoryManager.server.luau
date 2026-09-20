--[[
	Module: ResMemoryManager
	Description: 资源内存管理器 管理资源内存相关功能
	Author: 林奥宇
	Created: 2026-03-10
	Last Modified: 2026-08-31

	功能：
	- 阻止技能模型与 SoundService 子项自动加载
	- 预清资源断言，需要时再 Restore
]]
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SoundService = Utils.SoundService
local ResRestore = Utils.ResRestore
local AssetPaths = Utils.AssetPaths

local skillResFolder = AssetPaths.Resolve("ModelRes/Skill", AssetPaths.Scope.Shared)
if skillResFolder then
	for _, skill in skillResFolder:GetChildren() do
		if skill:IsA("Model") then
			ResRestore.ClearAssert(skill)
		end
	end
end

for _, sound in SoundService:GetChildren() do
	ResRestore.ClearAssertSound(sound)
end
