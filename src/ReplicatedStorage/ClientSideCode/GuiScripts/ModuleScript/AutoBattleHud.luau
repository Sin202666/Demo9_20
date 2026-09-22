--[[
	Module: AutoBattleHud
	Description: 自动战斗顶栏血条（Main.Top.HP）；只读服快照，不改权威数据
	Author: 程莘
	Created: 2026-09-22
	Last Modified: 2026-09-22

	功能：
	- Init：缓存 Top.HP 节点，订阅 AUTO_BATTLE_SESSION_CHANGED
	- 快照刷新 MyHP / EnemyHP 文案与 HpBar 比例
	- 战斗结束后隐藏 HP 框

	加载：PlayerAutoBattleClientManager require 后 Init
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local LocalPlayer = Utils.LocalPlayer
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local TranslationHelper = Utils.TranslationHelper

local AutoBattleHud = {}

local WAIT_FOREVER = math.huge
local KEY_MY = "我方"
local KEY_ENEMY = "敌方"

local _inited = false
local _hpRoot: Frame? = nil
local _myHpLabel: TextLabel? = nil
local _myZhName: TextLabel? = nil
local _myBar: Frame? = nil
local _enemyHpLabel: TextLabel? = nil
local _enemyZhName: TextLabel? = nil
local _enemyBar: Frame? = nil
local _myBarFullSize: UDim2? = nil
local _enemyBarFullSize: UDim2? = nil

--[[
	查找 TextLabel / Frame 子节点
	@param parent Instance - 父级
	@param name string - 子名
	@return Instance? - 子节点
]]
local function _waitChild(parent: Instance, name: string): Instance?
	local child = parent:FindFirstChild(name)
	if child then
		return child
	end
	return parent:WaitForChild(name, WAIT_FOREVER)
end

--[[
	刷新一侧血条
	@param hpLabel TextLabel? - 数值文案
	@param bar Frame? - HpBar
	@param fullSize UDim2? - 满血尺寸
	@param hp number - 当前血
	@param maxHp number - 最大血
]]
local function _applySide(
	hpLabel: TextLabel?,
	bar: Frame?,
	fullSize: UDim2?,
	hp: number,
	maxHp: number
)
	local safeMax = if maxHp > 0 then maxHp else 1
	local safeHp = math.clamp(hp, 0, safeMax)
	if hpLabel then
		TranslationHelper.SetRawText(hpLabel, string.format("%d/%d", math.floor(safeHp + 0.5), math.floor(safeMax + 0.5)))
	end
	if bar and fullSize then
		local ratio = safeHp / safeMax
		bar.Size = UDim2.new(fullSize.X.Scale * ratio, fullSize.X.Offset * ratio, fullSize.Y.Scale, fullSize.Y.Offset)
	end
end

--[[
	显示/隐藏 HP 根
	@param visible boolean - 是否显示
]]
local function _setVisible(visible: boolean)
	if _hpRoot then
		_hpRoot.Visible = visible
	end
end

--[[
	应用快照
	@param snapshot table - SyncState
]]
local function _applySnapshot(snapshot: { [string]: any })
	local my = snapshot.my
	local enemy = snapshot.enemy
	if type(my) == "table" then
		_applySide(_myHpLabel, _myBar, _myBarFullSize, tonumber(my.hp) or 0, tonumber(my.maxHp) or 1)
	end
	if type(enemy) == "table" then
		_applySide(_enemyHpLabel, _enemyBar, _enemyBarFullSize, tonumber(enemy.hp) or 0, tonumber(enemy.maxHp) or 1)
	end
	_setVisible(true)
end

--[[
	Session 变更回调
	@param snapshot any - 快照
	@param endResult any? - 结束载荷
]]
local function _onSessionChanged(snapshot: any, endResult: any?)
	if type(endResult) == "table" then
		if type(snapshot) == "table" then
			_applySnapshot(snapshot)
		end
		_setVisible(false)
		return
	end
	if type(snapshot) ~= "table" then
		return
	end
	if snapshot.phase == "Ended" then
		_applySnapshot(snapshot)
		_setVisible(false)
		return
	end
	_applySnapshot(snapshot)
end

--[[
	初始化 HUD（幂等）
]]
function AutoBattleHud.Init()
	if _inited then
		return
	end
	_inited = true

	local playerGui = LocalPlayer:WaitForChild("PlayerGui", WAIT_FOREVER) :: PlayerGui
	local screenGui = playerGui:WaitForChild("ScreenGui", WAIT_FOREVER) :: ScreenGui
	local main = _waitChild(screenGui, "Main")
	if not main then
		Log.warn("AutoBattleHud: Main 缺失")
		return
	end
	local top = _waitChild(main, "Top")
	if not top then
		Log.warn("AutoBattleHud: Top 缺失")
		return
	end
	local hpRoot = _waitChild(top, "HP")
	if not hpRoot or not hpRoot:IsA("Frame") then
		Log.warn("AutoBattleHud: Top.HP 缺失")
		return
	end
	_hpRoot = hpRoot

	local myHp = _waitChild(hpRoot, "MyHP")
	local enemyHp = _waitChild(hpRoot, "EnemyHP")
	if myHp then
		_myHpLabel = myHp:FindFirstChild("Hp") :: TextLabel?
		_myZhName = myHp:FindFirstChild("ZhName") :: TextLabel?
		local hpBg = myHp:FindFirstChild("HpBg")
		if hpBg then
			_myBar = hpBg:FindFirstChild("HpBar") :: Frame?
		end
	end
	if enemyHp then
		_enemyHpLabel = enemyHp:FindFirstChild("Hp") :: TextLabel?
		_enemyZhName = enemyHp:FindFirstChild("ZhName") :: TextLabel?
		local hpBg = enemyHp:FindFirstChild("HpBg")
		if hpBg then
			_enemyBar = hpBg:FindFirstChild("HpBar") :: Frame?
		end
	end

	if _myBar then
		_myBarFullSize = _myBar.Size
	end
	if _enemyBar then
		_enemyBarFullSize = _enemyBar.Size
	end

	if _myZhName then
		TranslationHelper.SetText(_myZhName, KEY_MY)
	end
	if _enemyZhName then
		TranslationHelper.SetText(_enemyZhName, KEY_ENEMY)
	end

	_setVisible(false)

	NetWork.RegisterBindableEvent(NetMsg.AUTO_BATTLE_SESSION_CHANGED, _onSessionChanged)
end

return AutoBattleHud
