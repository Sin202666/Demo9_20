--[[
	Module: LogicalEnemySpawnTest
	Description: 【临时】在 workspace「刷怪测试」Part 处刷逻辑怪，便于 L3/L4 手测
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-08-28

	功能：
	- 开服后在标记 Part 位姿 CreateLogicalEnemy(5011001, maxHp=300)
	- 若该测试怪已死亡/不存在，延迟补刷（始终维持约 1 只）
	- 可选 Attribute M1Test（写在「刷怪测试」Part 上，缺省不跑命令）：
	  Pause → 刷出约 2s 后 PauseMoveAi 3s 再 ResumeMoveAi
	  Goal → 刷出约 2s 后对 workspace「走点测试」SetMoveGoal（timeout 8s）
	  Dir → 刷出约 2s 后 SetMoveDir(LookVector, 2s)

	约束：
	- 临时脚本，测完请禁用本 Script 或删除本文件
	- 不进关卡/波次体系；仅找 Name==「刷怪测试」的 BasePart
	- 业务刷怪勿仿本文件
	- 依赖 GameConfig.怪物系统.启用；false 时本脚本直接退出

	启用：保持本 Script Enabled=true 且怪物系统启用
	关闭：Enabled=false、移出 InitGame，或关「怪物系统.启用」
]]

local Workspace = game:GetService("Workspace")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "怪物系统", "启用" }) == false then
	return
end

local SystemEnemy = Utils.SystemEnemy
local EnemyLogicalStore = Utils.EnemyLogicalStore
local Log = Utils.Log

local MARKER_NAME = "刷怪测试"
local TEST_CFG_ID = 5011001
local TEST_MAX_HP = 300
local BOOT_DELAY_SEC = 2
local RESPAWN_CHECK_SEC = 3
local MARKER_WAIT_SEC = 30

local _currentId: number? = nil

--[[
	查找刷怪标记 Part
	@return BasePart?
]]
local function _findMarker(): BasePart?
	local inst = Workspace:FindFirstChild(MARKER_NAME)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	return nil
end

--[[
	在标记处刷一只测试逻辑怪
	@return number? - 运行时 id
]]
local function _spawnTestEnemy(): number?
	local marker = _findMarker()
	if not marker then
		Log.warn("[LogicalEnemySpawnTest] 未找到 workspace." .. MARKER_NAME)
		return nil
	end
	local id = SystemEnemy.CreateLogicalEnemy(TEST_CFG_ID, marker.CFrame, {
		maxHp = TEST_MAX_HP,
	})
	if not id then
		Log.warn("[LogicalEnemySpawnTest] CreateLogicalEnemy 失败 cfg=", TEST_CFG_ID)
		return nil
	end
	Log.print("[LogicalEnemySpawnTest] 已刷逻辑怪 id=", id, " cfg=", TEST_CFG_ID)
	return id
end

--[[
	可选 M1 命令手测（仅当标记 Part.M1Test 有值）
	@param id number - 刚刷出的运行时 id
]]
local function _runOptionalM1Test(id: number)
	local marker = _findMarker()
	if not marker then
		return
	end
	local kind = marker:GetAttribute("M1Test")
	if kind == "Pause" then
		task.wait(2)
		local ok = SystemEnemy.PauseMoveAi(id)
		Log.print("[LogicalEnemySpawnTest] M1 PauseMoveAi id=", id, " ok=", ok)
		task.wait(3)
		ok = SystemEnemy.ResumeMoveAi(id)
		Log.print("[LogicalEnemySpawnTest] M1 ResumeMoveAi id=", id, " ok=", ok)
	elseif kind == "Goal" then
		local goalPart = Workspace:FindFirstChild("走点测试")
		if not (goalPart and goalPart:IsA("BasePart")) then
			Log.warn("[LogicalEnemySpawnTest] M1Test=Goal 但没有 workspace.走点测试")
			return
		end
		task.wait(2)
		local ok = SystemEnemy.SetMoveGoal(id, goalPart.Position, { timeoutSec = 8 })
		Log.print("[LogicalEnemySpawnTest] M1 SetMoveGoal id=", id, " ok=", ok)
	elseif kind == "Dir" then
		task.wait(2)
		local ok = SystemEnemy.SetMoveDir(id, marker.CFrame.LookVector, 2)
		Log.print("[LogicalEnemySpawnTest] M1 SetMoveDir id=", id, " ok=", ok)
	end
end

--[[
	当前测试怪是否仍存活
	@return boolean
]]
local function _isCurrentAlive(): boolean
	local id = _currentId
	if not id then
		return false
	end
	local rec = EnemyLogicalStore.get(id)
	return rec ~= nil and rec.alive == true
end

task.spawn(function()
	task.wait(BOOT_DELAY_SEC)

	local deadline = os.clock() + MARKER_WAIT_SEC
	while not _findMarker() and os.clock() < deadline do
		task.wait(0.5)
	end

	if not _findMarker() then
		Log.warn("[LogicalEnemySpawnTest] 等待超时，仍无 Part「" .. MARKER_NAME .. "」，退出")
		return
	end

	_currentId = _spawnTestEnemy()
	if _currentId then
		task.spawn(_runOptionalM1Test, _currentId)
	end

	while true do
		task.wait(RESPAWN_CHECK_SEC)
		if not _isCurrentAlive() then
			_currentId = _spawnTestEnemy()
			if _currentId then
				task.spawn(_runOptionalM1Test, _currentId)
			end
		end
	end
end)
