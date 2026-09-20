--[[
	Module: FootstepSoundsConfig
	Description: 脚步声音材质音效配置（IntervalSounds / LoopSounds / VolumeMultipliers）
	Author: Dev-Framework
	Created: 2026-07-03
	Last Modified: 2026-07-03

	功能：
	- IntervalSounds：按材质分组的间隔式脚步声 assetId 列表
	- LoopSounds：持续循环脚步声（供简单 Running 替换方案使用）
	- VolumeMultipliers：材质音量倍率，相对基础音量 1.0

	加载：local cfg = Utils.FootstepSoundsConfig
]]

local FootstepSoundsConfig = {

	-- 间隔式脚步声（每走一步播放一次）
	IntervalSounds = {
		[Enum.Material.Concrete] = {
			"rbxassetid://6026529548", "rbxassetid://6026529596", "rbxassetid://6026529818",
		},
		[Enum.Material.Fabric] = {
			"rbxassetid://2243118996", "rbxassetid://2243118358", "rbxassetid://2243118686",
		},
		[Enum.Material.CorrodedMetal] = {
			"rbxassetid://6026527724", "rbxassetid://6026527992", "rbxassetid://6026528049",
		},
		[Enum.Material.Metal] = {
			"rbxassetid://9126739090", "rbxassetid://9126738967", "rbxassetid://9126738896",
		},
		[Enum.Material.Plastic] = {
			"rbxassetid://6026526656", "rbxassetid://6026526679", "rbxassetid://6026526636",
		},
		[Enum.Material.Pavement] = {
			"rbxassetid://6026526748", "rbxassetid://6026526771", "rbxassetid://6026526956",
		},
		[Enum.Material.Slate] = {
			"rbxassetid://6026526696", "rbxassetid://6026526715", "rbxassetid://6026526795",
		},
		[Enum.Material.Marble] = {
			"rbxassetid://6026526840", "rbxassetid://6026526825", "rbxassetid://6026526891",
			"rbxassetid://6026526928", "rbxassetid://6026526866",
		},
		[Enum.Material.SmoothPlastic] = {
			"rbxassetid://9126734172", "rbxassetid://9126733896", "rbxassetid://9126734560",
		},
		[Enum.Material.Ground] = {
			"rbxassetid://6026529241", "rbxassetid://6026529332", "rbxassetid://6026529285",
		},
		[Enum.Material.Grass] = {
			"rbxassetid://481147101", "rbxassetid://481147984", "rbxassetid://481148039",
		},
		[Enum.Material.Wood] = {
			"rbxassetid://6026526561", "rbxassetid://6026526450", "rbxassetid://6026526499",
		},
		[Enum.Material.Pebble] = {
			"rbxassetid://6026528910", "rbxassetid://6026528890", "rbxassetid://6026528867",
		},
		[Enum.Material.DiamondPlate] = {
			"rbxassetid://9126737728", "rbxassetid://9126736554", "rbxassetid://9126737597",
		},
		[Enum.Material.Snow] = {
			"rbxassetid://9126732128", "rbxassetid://9126731099", "rbxassetid://9126732016",
		},
		[Enum.Material.Sand] = {
			"rbxassetid://9126733118", "rbxassetid://9126733408", "rbxassetid://9126733225",
		},
		[Enum.Material.Glass] = {
			"rbxassetid://6026529021", "rbxassetid://6026529091", "rbxassetid://6026529110",
		},
		[Enum.Material.Mud] = {
			"rbxassetid://9126734842", "rbxassetid://9126734314", "rbxassetid://9126734778",
		},
		["Ladder"] = {
			"rbxassetid://9126740217", "rbxassetid://9126739039", "rbxassetid://9126740133",
			"rbxassetid://9126739947", "rbxassetid://9126740044", "rbxassetid://9126740305",
			"rbxassetid://9126739834", "rbxassetid://9126739622", "rbxassetid://9126739505",
			"rbxassetid://9126739406", "rbxassetid://9126739332", "rbxassetid://9126739229",
		},
		["Chainlink"] = {
			"rbxassetid://9126738423", "rbxassetid://9126737791", "rbxassetid://9126738338",
			"rbxassetid://9126738197", "rbxassetid://9126738113", "rbxassetid://9126738032",
			"rbxassetid://9126737943", "rbxassetid://9126737853",
		},
		["Classic"] = {
			"rbxassetid://15683780960", "rbxassetid://15683782486", "rbxassetid://15683782352",
			"rbxassetid://15683781630", "rbxassetid://15683782180", "rbxassetid://15683781363",
			"rbxassetid://15683781160", "rbxassetid://15683781892",
		},
		["Squish"] = {
			"rbxassetid://1708960146", "rbxassetid://1708959866", "rbxassetid://1708959571",
			"rbxassetid://1708959157", "rbxassetid://1708958855",
		},
	},

	-- 循环式脚步声（持续播放）
	LoopSounds = {
		[Enum.Material.Ground] = "rbxassetid://178054124",
		[Enum.Material.Wood] = "rbxassetid://177940988",
		[Enum.Material.Concrete] = "rbxassetid://277067660",
		[Enum.Material.Grass] = "rbxassetid://4776173570",
		[Enum.Material.Metal] = "rbxassetid://4790537991",
		[Enum.Material.Sand] = "rbxassetid://4777003964",
		[Enum.Material.Fabric] = "rbxassetid://4776951843",
		[Enum.Material.Slate] = "rbxassetid://4776998555",
		[Enum.Material.Marble] = "rbxassetid://4776962643",
	},

	-- 材质音量倍率（相对于基础音量，1.0 = 100%）
	VolumeMultipliers = {
		[Enum.Material.Sandstone] = 1.2,
		[Enum.Material.Concrete] = 1.0,
		[Enum.Material.Fabric] = 1.0,
		[Enum.Material.CorrodedMetal] = 1.0,
		[Enum.Material.Metal] = 1.9,
		[Enum.Material.Plastic] = 1.0,
		[Enum.Material.Pavement] = 1.8,
		[Enum.Material.Slate] = 1.8,
		[Enum.Material.SmoothPlastic] = 1.0,
		[Enum.Material.Ground] = 1.0,
		[Enum.Material.Grass] = 1.0,
		[Enum.Material.Wood] = 1.0,
		[Enum.Material.Pebble] = 1.0,
		[Enum.Material.DiamondPlate] = 1.2,
		[Enum.Material.Snow] = 0.6,
		[Enum.Material.Sand] = 0.8,
		[Enum.Material.Glass] = 1.1,
		[Enum.Material.Mud] = 0.9,
		["Ladder"] = 1.0,
		["Chainlink"] = 1.1,
		["Classic"] = 1.0,
		["Squish"] = 0.8,
	},
}

-- 材质映射：将相似材质映射到已有音效
FootstepSoundsConfig.IntervalSounds[Enum.Material.CrackedLava] = FootstepSoundsConfig.IntervalSounds[Enum.Material.Plastic]
FootstepSoundsConfig.IntervalSounds[Enum.Material.Sandstone] = FootstepSoundsConfig.IntervalSounds[Enum.Material.Plastic]
FootstepSoundsConfig.IntervalSounds[Enum.Material.ForceField] = FootstepSoundsConfig.IntervalSounds[Enum.Material.Plastic]
FootstepSoundsConfig.IntervalSounds[Enum.Material.Marble] = FootstepSoundsConfig.IntervalSounds[Enum.Material.Plastic]
FootstepSoundsConfig.IntervalSounds[Enum.Material.Neon] = FootstepSoundsConfig.IntervalSounds[Enum.Material.Plastic]
FootstepSoundsConfig.IntervalSounds[Enum.Material.Granite] = FootstepSoundsConfig.IntervalSounds[Enum.Material.Plastic]
FootstepSoundsConfig.IntervalSounds[Enum.Material.Glacier] = FootstepSoundsConfig.IntervalSounds[Enum.Material.Glass]
FootstepSoundsConfig.IntervalSounds[Enum.Material.Ice] = FootstepSoundsConfig.IntervalSounds[Enum.Material.Glass]
FootstepSoundsConfig.IntervalSounds[Enum.Material.Salt] = FootstepSoundsConfig.IntervalSounds[Enum.Material.Sand]
FootstepSoundsConfig.IntervalSounds[Enum.Material.Foil] = FootstepSoundsConfig.IntervalSounds[Enum.Material.DiamondPlate]
FootstepSoundsConfig.IntervalSounds[Enum.Material.LeafyGrass] = FootstepSoundsConfig.IntervalSounds[Enum.Material.Grass]
FootstepSoundsConfig.IntervalSounds[Enum.Material.WoodPlanks] = FootstepSoundsConfig.IntervalSounds[Enum.Material.Wood]

-- 材质音量倍率映射：将相似材质映射到已有音量倍率
FootstepSoundsConfig.VolumeMultipliers[Enum.Material.ForceField] = FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Plastic]
FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Marble] = FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Plastic]
FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Neon] = FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Plastic]
FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Granite] = FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Plastic]
FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Glacier] = FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Glass]
FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Ice] = FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Glass]
FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Salt] = FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Sand]
FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Foil] = FootstepSoundsConfig.VolumeMultipliers[Enum.Material.DiamondPlate]
FootstepSoundsConfig.VolumeMultipliers[Enum.Material.LeafyGrass] = FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Grass]
FootstepSoundsConfig.VolumeMultipliers[Enum.Material.WoodPlanks] = FootstepSoundsConfig.VolumeMultipliers[Enum.Material.Wood]

FootstepSoundsConfig.LoopSounds[Enum.Material.SmoothPlastic] = FootstepSoundsConfig.LoopSounds[Enum.Material.Concrete]
FootstepSoundsConfig.LoopSounds[Enum.Material.Plastic] = FootstepSoundsConfig.LoopSounds[Enum.Material.Concrete]
FootstepSoundsConfig.LoopSounds[Enum.Material.ForceField] = FootstepSoundsConfig.LoopSounds[Enum.Material.Concrete]
FootstepSoundsConfig.LoopSounds[Enum.Material.Mud] = FootstepSoundsConfig.LoopSounds[Enum.Material.Ground]
FootstepSoundsConfig.LoopSounds[Enum.Material.Pebble] = FootstepSoundsConfig.LoopSounds[Enum.Material.Ground]
FootstepSoundsConfig.LoopSounds[Enum.Material.Sandstone] = FootstepSoundsConfig.LoopSounds[Enum.Material.Sand]
FootstepSoundsConfig.LoopSounds[Enum.Material.Snow] = FootstepSoundsConfig.LoopSounds[Enum.Material.Sand]
FootstepSoundsConfig.LoopSounds[Enum.Material.Rock] = FootstepSoundsConfig.LoopSounds[Enum.Material.Slate]
FootstepSoundsConfig.LoopSounds[Enum.Material.Basalt] = FootstepSoundsConfig.LoopSounds[Enum.Material.Slate]
FootstepSoundsConfig.LoopSounds[Enum.Material.Asphalt] = FootstepSoundsConfig.LoopSounds[Enum.Material.Slate]
FootstepSoundsConfig.LoopSounds[Enum.Material.Glacier] = FootstepSoundsConfig.LoopSounds[Enum.Material.Slate]
FootstepSoundsConfig.LoopSounds[Enum.Material.WoodPlanks] = FootstepSoundsConfig.LoopSounds[Enum.Material.Wood]
FootstepSoundsConfig.LoopSounds[Enum.Material.LeafyGrass] = FootstepSoundsConfig.LoopSounds[Enum.Material.Grass]
FootstepSoundsConfig.LoopSounds[Enum.Material.Ice] = FootstepSoundsConfig.LoopSounds[Enum.Material.Marble]
FootstepSoundsConfig.LoopSounds[Enum.Material.Salt] = FootstepSoundsConfig.LoopSounds[Enum.Material.Marble]
FootstepSoundsConfig.LoopSounds[Enum.Material.Pavement] = FootstepSoundsConfig.LoopSounds[Enum.Material.Marble]
FootstepSoundsConfig.LoopSounds[Enum.Material.Limestone] = FootstepSoundsConfig.LoopSounds[Enum.Material.Marble]
FootstepSoundsConfig.LoopSounds[Enum.Material.Neon] = FootstepSoundsConfig.LoopSounds[Enum.Material.Marble]
FootstepSoundsConfig.LoopSounds[Enum.Material.Glass] = FootstepSoundsConfig.LoopSounds[Enum.Material.Marble]
FootstepSoundsConfig.LoopSounds[Enum.Material.Foil] = FootstepSoundsConfig.LoopSounds[Enum.Material.Metal]
FootstepSoundsConfig.LoopSounds[Enum.Material.DiamondPlate] = FootstepSoundsConfig.LoopSounds[Enum.Material.Metal]
FootstepSoundsConfig.LoopSounds[Enum.Material.CorrodedMetal] = FootstepSoundsConfig.LoopSounds[Enum.Material.Metal]

return FootstepSoundsConfig
