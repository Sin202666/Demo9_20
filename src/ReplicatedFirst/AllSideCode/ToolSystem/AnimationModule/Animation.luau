--[[
	Module: Animation
	Description: 动画名 → AssetId 映射表
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-08-31

	功能：
	- 供 TrackCache.GetConfiguredAnimID / AnimationModule.GetAnimID / GetPreloadTable 读取
	- 新增动作：追加 ["逻辑名"] = rbx 数字 ID；勿在此写业务逻辑
]]

local Animation = {
	-- 示例：
	-- ["攻击动作1"] = 241252,
	["WalkForward"] = 139654422461240,
	["WalkLeft"] = 119106930873594,
	["WalkRight"] = 74286139489224,
	["WalkBack"] = 91745560081619,
	["RunForward"] = 126394617080362,
	["RunLeft"] = 115864488601800,
	["RunRight"] = 80771194323564,
	["RunBack"] = 91745560081619,
	["Fall"] = 80109568260492,
	["Land"] = 79155093635462,
	["Climb"] = 180436334, -- 官方动作
	["LightLand"] = 95077157938466,
	["Jump"] = 74574734044792,
	["Idle"] = 73017323943165,
	-- 衔接动作：待机↔行走/奔跑 过渡用
	["StartRun"] = 110076234433144,
	["StopRun"] = 74711175308982,
	["StartWalk"] = 83627064347968,
	["StopWalk"] = 131876402162668,
	["Swim"] = 127117575260465,
	["SwimIdle"] = 123064778192220,
	-- NewRoll 四向翻滚（从 RP17 迁移 ID；取正式环境 [2]）
	["RollForward"] = 124339740610221,
	["RollBackward"] = 99063386493491,
	["RollRight"] = 110450995762708,
	["RollLeft"] = 102102686370194,
	-- Meteor 施法（RP17 技能释放动作4：开发 [1]=118083405064163，正式 [2]=122070563111213 待上传；取开发 [1]）
	["技能释放动作4"] = 118083405064163,
	["空间运镜技能"] = 84619712212347,
	-- Upper Overlay（AnimationLayer.Slot.Upper）：须只键 R6 上半身（勿键 Left/Right Hip）；替换为真实半身片 ID 后用于边跑边施法验收
	-- ["Cast_Upper"] = 0,

	-- 敌人行为（仅保留当前 enemyConf 5011001 引用的动作名）
	["人型待机R6-2"] = 101041130493724,
	["人型行走R6-3"] = 71839937558923,
	["人型奔跑R6-2"] = 86867774712819,
	["人型受击R6-1"] = 106030741950075,
	["人型死亡R6"] = 97727319397653,
	["人型眩晕R6"] = 72748869713332,

	-- 坐骑：独角兽（MountAnimSets.MountUnicorn）
	["Mount_Unicorn_Idle"] = 89438925466021,
	["Mount_Unicorn_Run"] = 132544717496376,
	["Mount_Unicorn_Jump"] = 101872593896232,
}

return Animation
