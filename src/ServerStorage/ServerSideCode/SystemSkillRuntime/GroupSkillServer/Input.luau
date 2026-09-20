--[[
	Module: GroupSkillServer.Input
	Description: 组技能派生输入路由（由 GroupSkillServer/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-18

	功能：
	- onInputRequest：按 skillCastId 或最近运行实例 applyInputRequest

	与 init / InstanceFactory：
	- ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT 由 init 传入，只定义一处
	- 新释放走 requestRelease（Factory），不在此创建实例
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)

type GroupSkillServer = typeof(Class.GroupSkillServer)
type SkillInputData = typeof(Class.SkillInputData)

--[[
	挂载输入 API 到 GroupSkillServer 类表。
	@param GroupSkillServer table - 与 init 同一份类表
	@param ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT boolean - 跨槽打断后禁派生
	@return () - 无返回值
]]
return function(GroupSkillServer, ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT)
	--[[
		处理按键输入请求（用于技能派生）。
		跨槽打断后若开启禁派生则直接返回；优先按 skillCastId 路由，否则回落到最近运行实例。

		@param self GroupSkillServer - 组技能服实例
		@param inputNameOrData string | SkillInputData? - 输入名（如 "buttonUp"）或整包输入；nil 时只按最近实例记时戳
		@param skillInputData SkillInputData? - 当第一参为字符串时的输入包；含可选 skillCastId 用于定向路由
		@return nil
	]]
	function GroupSkillServer.onInputRequest(self: GroupSkillServer, inputNameOrData: string | SkillInputData?, skillInputData: SkillInputData?)
		if ENABLE_DERIVE_SUPPRESS_AFTER_CROSS_INTERRUPT and self.deriveSuppressedAfterCrossInterrupt then
			return
		end
		-- 输入路由：只要有 runtime:hasRunningBaseSkill() 的实例，就允许路由；是否真能派生由 condition(ctx) 决定
		local inputData: SkillInputData? = nil
		if type(inputNameOrData) == "string" then
			inputData = skillInputData
		else
			inputData = inputNameOrData
		end
		local targetSkillCastId = (inputData and inputData.skillCastId) :: string?

		--【P2】优先按 skillCastId 查找实例，否则回退到“最近运行实例”
		local targetInstance = nil
		if targetSkillCastId and #targetSkillCastId > 0 then
			targetInstance = self.runtimeByCastId[targetSkillCastId]
			if targetInstance and not targetInstance:hasRunningBaseSkill() then
				targetInstance = nil
			end
		end
		if not targetInstance then
			for i = #self.runningRuntimeList, 1, -1 do
				local r = self.runningRuntimeList[i]
				if r:hasRunningBaseSkill() then
					targetInstance = r
					break
				end
			end
		end

		if targetInstance then
			local inputName = (type(inputNameOrData) == "string") and inputNameOrData or nil
			local nextBaseSkillIndex = targetInstance.activeBaseSkillIndex + 1
			local nextSkillConfig = self.groupSkillModule.Skill[nextBaseSkillIndex]
			targetInstance:applyInputRequest(inputData, inputName, nextSkillConfig and nextBaseSkillIndex or nil)
		else
			Log.warn("技能组未运行，无法处理按键输入请求")
		end
	end
end
