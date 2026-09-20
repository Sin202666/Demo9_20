--[[
	Module: EnemyLogicalTypes
	Description: 逻辑怪共享常量与 CFrame 序列化
	Author: 林奥宇
	Created: 2026-08-12
	Last Modified: 2026-08-28

	功能：
	- LOCAL_MONSTER_FOLDER_NAME：客户端表现父级 Folder（workspace.LocalMonster）
	- packCFrame / unpackCFrame：Remote 可序列化位姿

	加载：
		local EnemyLogicalTypes = Utils.EnemyLogicalTypes
]]

local EnemyLogicalTypes = {}

EnemyLogicalTypes.LOCAL_MONSTER_FOLDER_NAME = "LocalMonster"
EnemyLogicalTypes.ATTR_IS_LOGICAL = "IsLogicalEnemy"

--[[
	CFrame → 可 Remote 序列化字段
	@param cf CFrame - 位姿
	@return number, number, number, number, number, number - posXYZ + lookXYZ
]]
function EnemyLogicalTypes.packCFrame(cf: CFrame): (number, number, number, number, number, number)
	local look = cf.LookVector
	return cf.X, cf.Y, cf.Z, look.X, look.Y, look.Z
end

--[[
	序列化字段 → CFrame
	@param posX number - 世界坐标 X
	@param posY number - 世界坐标 Y
	@param posZ number - 世界坐标 Z
	@param lookX number - LookVector X
	@param lookY number - LookVector Y
	@param lookZ number - LookVector Z
	@return CFrame - 由位置与朝向重建的位姿
]]
function EnemyLogicalTypes.unpackCFrame(posX: number, posY: number, posZ: number, lookX: number, lookY: number, lookZ: number): CFrame
	local pos = Vector3.new(posX, posY, posZ)
	local look = Vector3.new(lookX, lookY, lookZ)
	if look.Magnitude < 1e-4 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	return CFrame.lookAt(pos, pos + look)
end

return EnemyLogicalTypes