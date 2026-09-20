--[[
	Module: BaseSkillServer.Sync
	Description: 同步半径与中途广播（由 BaseSkillServer/init 挂载，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-08-31

	功能：
	- getSyncRadius：按 phase 取 SkillDataSchema 归一化半径
	- fireProjectileHitConfirmed / fireProximityStrikeWave / fireSolarFlareMeteorShot / fireProjectilePathConfirmed
	- getCharacterPosition：路由半径筛选用

	与 init / Lifecycle：
	- 业务只调 BaseSkillServer 实例方法
	- _finish 的 StopSkill 仍走 self:getCharacterPosition
	- 不发 BaseSkillStarted（仅 GroupSkillServer）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Class = require(game.ReplicatedFirst.AllSideCode.Class.Class)

local BaseSkillFolder = game.ReplicatedStorage.ClientSideCode.SystemSkill.BaseSkill
local SkillSyncEventFactory = require(BaseSkillFolder.SkillSyncEventFactory)
local SkillSyncDispatcher = require(BaseSkillFolder.SkillSyncDispatcher)
local SkillDataSchema = require(BaseSkillFolder.SkillDataSchema)

local SkillSyncLog = Utils.SkillSyncLog

type BaseSkillServer = Class.BaseSkillServer

--[[
	挂载同步广播 API 到 BaseSkillServer 类表。
	@param BaseSkillServer table - 与 init 同一份类表
	@return () - 无返回值
]]
return function(BaseSkillServer)
	--[[
		获取同步半径（统一策略，使用 SkillDataSchema 归一化后的默认值）。

		@param self BaseSkillServer - 基础技能服实例
		@param phase string? - "DamageTip" | "ProjectileHitConfirmed" | "StopSkill"；nil 时用 syncRadius
		@return number - 半径（studs）
	]]
	function BaseSkillServer.getSyncRadius(self: BaseSkillServer, phase: string?): number
		local data = SkillDataSchema.normalizeSkillData(self.skillModule and self.skillModule.Data)
		if phase == "DamageTip" then
			return data.damageTipRadius
		end
		if phase == "ProjectileHitConfirmed" then
			return data.hitConfirmRadius
		end
		if phase == "StopSkill" then
			return data.stopSyncRadius
		end
		return data.syncRadius
	end

	--[[
	    广播 ProjectileHitConfirmed（供技能模块在障碍物命中等场景调用）。

	    @param self BaseSkillServer - 基础技能服实例
	    @param hitPosition Vector3 - 命中世界坐标
	    @param hitType "Enemy" | "Obstacle" - 命中类型
	    @param targetId any? - Player UserId 或障碍标识；nil 表示无目标 id
	    @param extraFields table? - 附加同步字段，浅合并进 payload
	    @return nil
	]]
	function BaseSkillServer.fireProjectileHitConfirmed(self: BaseSkillServer, hitPosition: Vector3, hitType: "Enemy" | "Obstacle", targetId: any?, extraFields: { [string]: any }?)
		if not self.skillCastId or not self.baseSkillInstanceId then return end
		local hitConfirmedData = SkillSyncEventFactory.projectileHitConfirmed(self, hitPosition, hitType, targetId)
		if extraFields then
			for key, value in extraFields do
				hitConfirmedData[key] = value
			end
		end
		SkillSyncLog.log(self.skillName, self.skillCastId, self.baseSkillInstanceId, "Server", "ProjectileHitConfirmed", string.format("hitType=%s target=%s", hitType, tostring(targetId or "?")))
		local pos = hitPosition or self:getCharacterPosition()
		SkillSyncDispatcher.dispatch(self, "ProjectileHitConfirmed", hitConfirmedData, pos)
	end

	--[[
		广播近身追加落雷波次（服务端检测落点 → 客户端表现与 Hitbox 对齐）。

		@param self BaseSkillServer - 基础技能服实例
		@param waveIndex number - 波次序号（从 1 起）
		@param centerPos Vector3 - 波次中心世界坐标
		@param positions {Vector3} - 各落点世界坐标
		@return nil
	]]
	function BaseSkillServer.fireProximityStrikeWave(
		self: BaseSkillServer,
		waveIndex: number,
		centerPos: Vector3,
		positions: { Vector3 }
	)
		if not self.skillCastId or not self.baseSkillInstanceId then
			return
		end
		if type(positions) ~= "table" or #positions == 0 then
			return
		end
		local payload = SkillSyncEventFactory.proximityStrikeWave(self, waveIndex, centerPos, positions)
		SkillSyncLog.log(
			self.skillName,
			self.skillCastId,
			self.baseSkillInstanceId,
			"Server",
			"ProximityStrikeWave",
			string.format("wave=%d count=%d", waveIndex, #positions)
		)
		SkillSyncDispatcher.dispatch(self, "ProximityStrikeWave", payload, centerPos)
	end

	--[[
		广播太阳耀斑单颗陨石落点（服务端开飞时裁决 → 客户端表现与 Hitbox 对齐）。

		@param self BaseSkillServer - 基础技能服实例
		@param meteorIndex number - 陨石序号
		@param startPos Vector3 - 起飞点
		@param endPos Vector3 - 落点
		@return nil
	]]
	function BaseSkillServer.fireSolarFlareMeteorShot(
		self: BaseSkillServer,
		meteorIndex: number,
		startPos: Vector3,
		endPos: Vector3
	)
		if not self.skillCastId or not self.baseSkillInstanceId then
			return
		end
		if type(meteorIndex) ~= "number" or typeof(startPos) ~= "Vector3" or typeof(endPos) ~= "Vector3" then
			return
		end
		local payload = SkillSyncEventFactory.solarFlareMeteorShot(self, meteorIndex, startPos, endPos)
		SkillSyncLog.log(
			self.skillName,
			self.skillCastId,
			self.baseSkillInstanceId,
			"Server",
			"SolarFlareMeteorShot",
			string.format("idx=%d end=(%.1f,%.1f,%.1f)", meteorIndex, endPos.X, endPos.Y, endPos.Z)
		)
		SkillSyncDispatcher.dispatch(self, "SolarFlareMeteorShot", payload, endPos)
	end

	--[[
		广播直线弹道路径（Shoot 系：服务端 buildShootPath → 客户端子弹与 Hitbox 对齐）。

		@param self BaseSkillServer - 基础技能服实例
		@param projectileIndex number - 子弹序号
		@param startPos Vector3 - 路径起点
		@param endPos Vector3 - 路径终点
		@param flyDir Vector3 - 飞行方向（单位向量）
		@return nil
	]]
	function BaseSkillServer.fireProjectilePathConfirmed(
		self: BaseSkillServer,
		projectileIndex: number,
		startPos: Vector3,
		endPos: Vector3,
		flyDir: Vector3
	)
		if not self.skillCastId or not self.baseSkillInstanceId then
			return
		end
		if type(projectileIndex) ~= "number"
			or typeof(startPos) ~= "Vector3"
			or typeof(endPos) ~= "Vector3"
			or typeof(flyDir) ~= "Vector3"
		then
			return
		end
		local payload = SkillSyncEventFactory.projectilePathConfirmed(self, projectileIndex, startPos, endPos, flyDir)
		SkillSyncLog.log(
			self.skillName,
			self.skillCastId,
			self.baseSkillInstanceId,
			"Server",
			"ProjectilePathConfirmed",
			string.format(
				"idx=%d start=(%.1f,%.1f,%.1f) end=(%.1f,%.1f,%.1f)",
				projectileIndex,
				startPos.X,
				startPos.Y,
				startPos.Z,
				endPos.X,
				endPos.Y,
				endPos.Z
			)
		)
		SkillSyncDispatcher.dispatch(self, "ProjectilePathConfirmed", payload, startPos)
	end

	--[[
		获取施法者角色当前位置（用于同步路由半径筛选）。

		@param self BaseSkillServer - 基础技能服实例
		@return Vector3? - HumanoidRootPart / PrimaryPart 世界坐标；无角色则为 nil
	]]
	function BaseSkillServer.getCharacterPosition(self: BaseSkillServer): Vector3?
		local char = self.character
		if not char then return nil end
		local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
		if root then return root.Position end
		return nil
	end
end
