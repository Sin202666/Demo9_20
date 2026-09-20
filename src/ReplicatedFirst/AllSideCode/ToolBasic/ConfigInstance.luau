
local ConfigInstance ={}
ConfigInstance.key={
buffdataConf={"isShow","ZhName","buffName","isOver","des","addPower","Icon"},
codeConf={"code","codeType","startTime","endTime","rewardId","rewardNum"},
dailyawardConf={"index","week","AwardID","CountID","BtnColor","BtnIcon"},
enemyConf={"model","","tp","des","ZhName","InjuredSound","animIdleName","animWalkName","animRunName","animHitName","animDieName","animStunName","Ai","boss","xyd","Lv","spMax","moveSkill","moveSkillCd","enablePreCastMove","skill","hpLimitSkill","skillCastMoveSpeedMul","cd","rgMin","rgMax","attackRange","rangerSafeDistance","chaseRunDistance","moveAway","at","atv","atInherit","proactiveDetectionAggro","stunImmune","detectionRange","patientRange","patientTime","idleTime","wanderTime","chaseRunSpeedMul","wanderRange","hitstunDisabled","outOfCombatRegenDelaySeconds","outOfCombatRegenMaxHealthPerSecond","despawnTime","changeSkill","isDeadMan","animWalkRefSpeed","animRunRefSpeed","isindex","World","deathPresentation","EventTp","Icon","eggInitHpRatio","eggRegenPerSec","eggMaxDamagePerHit","eggHatchIds","eggHatchWeights","rangerMaxMoveDistance"},
gamepassitemConf={"ZhName","OnlyTag","UnlockInf","hasCount","tp","Icon","xyd","ColorStr"},
itemdataConf={"ZhName","xyd","UnlockInf","isShow","isBag","hasCount","bagTp","tp","sort","ZhDes","UseNow","UseScript","parms","Icon","Model","init","newPlayerInit","ScriptTypeClient","ScriptTypeServer","ZhEffectDes"},
itemshopdataConf={"ZhName","ZhDes","OnlyTag","NeedBuy","NextBug","BuyLimitNum","gamePassItemID","cost","passID","GiftID","price","oriPrice","itemID","itemCount","Icon","ColorStr"},
mountConf={"ZhName","LocomotionType","Model","SummonCd","CombatPolicy","Icon","xyd","SpeedMul","AttachName","CameraProfile","AnimSet","ExtJson"},
onlineawardConf={"AwardID","CountID","OnlinTime","Icon"},
petConf={"EggName","xyd","tp","SellItem","SellCount","ZhName","Model","PowerAdd"},
peteggConf={"DisName","ZhName","PoolOnlyTag","tp","pool","weight","cost","price","Model"},
settingConf={"ZhName","ShowName","SetType","TempType","set","range","isPecent","ZhDes","isShow","mobieFade"},
skillConf={"ZhName","ScriptName","","","Icon","Priority","Range","EffectTarget","needCheck","isBase","exp","","ElementTp","AttackEffectPos","CD","DamageRate","","buffs","","","","ForceHitAnimation","Size","Band","SummonBand"},
updatelogConf={"UpdateTime","ZhTagTitle","ZhUpdateText"},
}

ConfigInstance.buffdataConf={
	[101]={1,"幸运加成","幸运固定值",0,"幸运加成描述",30,108326414755506},
	[102]={1,"超级幸运加成","幸运固定值",0,"超级幸运加成描述",20,99531617003166}
}

ConfigInstance.codeConf={
	[1]={"NEW GAME",1,1763719200,1766311220,{101},{10}}
}

ConfigInstance.dailyawardConf={
	[1]={1,1,2,10,"2","86589195945629"},
	[2]={2,1,2,10,"3","86589195945629"},
	[3]={3,1,2,10,"4","86589195945629"},
	[4]={4,1,2,10,"4","86589195945629"},
	[5]={5,1,2,10,"4","86589195945629"},
	[6]={6,1,2,10,"5","86589195945629"},
	[7]={7,1,2,10,"4","86589195945629"},
	[8]={1,2,2,10,"3","86589195945629"},
	[9]={2,2,2,10,"3","86589195945629"},
	[10]={3,2,2,10,"4","86589195945629"},
	[11]={4,2,2,10,"4","86589195945629"},
	[12]={5,2,2,10,"4","86589195945629"},
	[13]={6,2,2,10,"5","86589195945629"},
	[14]={7,2,2,10,"5","86589195945629"},
	[15]={1,3,2,10,"4","86589195945629"},
	[16]={2,3,2,10,"4","86589195945629"},
	[17]={3,3,2,10,"5","86589195945629"},
	[18]={4,3,2,10,"5","86589195945629"},
	[19]={5,3,2,10,"4","86589195945629"},
	[20]={6,3,2,10,"5","86589195945629"},
	[21]={7,3,2,10,"5","86589195945629"}
}

ConfigInstance.enemyConf={
	[5011001]={"近战哥布林","1",5,"矮人描述","近战哥布林","受击-哥布林1","人型待机R6-2","人型行走R6-3","人型奔跑R6-2","人型受击R6-1","人型死亡R6","人型眩晕R6","Ranger","0",1,1,"","","","",{10300001},{},{1},{3},{0},{6},4,0,3,0,{1,5,9},{10,21,12},{},1,"",200,200,0,{},{},2,{},0,"0","1",3,3,0,16,24,1,1,"",0,"","","","",{},{},""}
}

ConfigInstance.gamepassitemConf={
	[3000001]={"幸运","Luck",1,1,3,108747975906117,3,"绿"},
	[3000002]={"超级幸运","SuperLuck",1,1,3,94456338219776,3,"橙"}
}

ConfigInstance.itemdataConf={
	[1]={"金钱",5,1,1,0,1,0,0,0,"Gem",0,"0",{"0"},90521258639290,"","0","10",{},{},""},
	[2]={"宝石",5,1,1,0,1,0,0,0,"zuanshi",0,"0",{"0"},103812808522717,"Gem","0","0",{},{},""},
	[11]={"宝物背包容量",5,1,1,0,1,0,0,0,"zuanshi",0,"0",{"0"},103812808522717,"","0","300",{},{},""},
	[101]={"幸运药水",4,1,0,0,1,0,1,1,"幸运药水描述",0,"AddBUFF",{"101","10"},89172471073603,"幸运药水","0","0",{"道具Client"},{},""},
	[102]={"超级幸运药水",6,1,0,0,1,0,1,2,"超级幸运药水描述",0,"AddBUFF",{"102","10"},71569149809464,"超级幸运药水","0","0",{"道具Client"},{},""}
}

ConfigInstance.itemshopdataConf={
	[1]={"双倍幸运","双倍幸运描述","LuckX2","","","","",2,1489329041,"3412848849",199,"",{},{},{"119377429859111"},"2"},
	[2]={"机器礼包1","机器礼包1描述","MachinePack1","","","","",1,3412830887,"3412835012",69,"",{8100003,8200002},{1},{"128053029377978","127280162932038"},"3"},
	[3]={"一键解锁在线奖励","","OnlineAwardClaimAll","","","","",1,3612011629,"",79,"",{},{},{},""}
}

ConfigInstance.mountConf={
	[6001001]={"独角兽","GroundMount","独角兽",3,"ForceExit","",3,1.5,"MountSaddle","MountGround","MountUnicorn","{\"AccelSec\":0.9,\"DecelSec\":1.35,\"TurnRateDeg\":220,\"TurnHighSpeedMul\":0.38,\"TurnSpeedPow\":1.35,\"TurnAlignMin\":0.65,\"TurnAlignPow\":1.1,\"AboutFaceDot\":-0.75,\"AboutFaceAlignMin\":0,\"AboutFaceTurnMul\":2.9,\"AboutFaceBrake\":160,\"AboutFaceCompleteDeg\":12,\"AboutFaceStickBack\":0.9,\"AboutFaceCooldownSec\":0.2,\"AirTurnMul\":0.85,\"AirFlipTurnMul\":2.6,\"DoubleJumpFlipWindowSec\":0.4,\"AirFlipVelAlign\":8,\"DoubleJumpVelBlend0\":0.45,\"DoubleJumpRedirectSec\":0.22,\"JumpHeight\":22,\"DoubleJumpSpeed\":55,\"AirGravityScale\":0.72,\"CanDoubleJump\":1,\"AirThrottleMul\":1,\"AirFlipThrottleMul\":1,\"AirSpeedMaintainSoft\":0.9,\"AirSpeedLeanRate\":8,\"AirCoastDecel\":6,\"FirstJumpMinFlat\":16,\"FirstJumpSnapFrac\":0.6,\"FirstJumpRampSec\":0.06,\"FirstJumpLookAbsorb\":0.08,\"LeapPushSec\":0.24,\"LeapPushAccel\":55,\"LeapPushPow\":1.35,\"LeapStandPushMul\":1.2,\"LeapGallopPushMul\":0.45,\"DoubleJumpPushSec\":0.22,\"DoubleJumpPushAccel\":70,\"AboutFaceTravelDot\":-0.75,\"TurnCruiseDot\":0.85,\"TurnPivotBackStuds\":3.5,\"DoubleJumpMinFlat\":18,\"DriveMode\":\"MountRoot\",\"GroundClearance\":0.08,\"WalkSpeedMul\":0.42,\"GallopEnterThrottle\":0.82,\"GallopEnterHoldSec\":0.55,\"GallopExitThrottle\":0.28,\"WalkAccelSec\":0.5,\"GallopAccelSec\":1.05,\"SlipDecelSec\":1.85,\"BrakeDecelSec\":0.55,\"BrakeSpeed01\":0.36,\"DoubleJumpAirDelaySec\":0.12}"},
	[6002001]={"测试吉普","WheeledVehicle","Mount_Jeep_Test",5,"ForceExit","",2,0,"","MountVehicle","","{\"MaxSpeed\":80,\"Acceleration\":40,\"TurnRadius\":12}"},
	[6003001]={"测试飞龙","FlyingCreature","Mount_Dragon_Test",8,"ForceExit","",4,0,"MountDragon","MountFlying","MountDragonBasic","{\"MaxAltitude\":200,\"ClimbRate\":40,\"DescendRate\":35,\"HoverAllowed\":1}"},
	[6004001]={"测试直升机","Aircraft","Mount_Helicopter_Test",10,"ForceExit","",4,0,"PilotSeat","MountAircraft","MountHeliBasic","{\"ControlScheme\":\"Helicopter\",\"MaxSpeed\":90,\"HoverThrust\":50}"}
}

ConfigInstance.onlineawardConf={
	[1]={1,100,300,""},
	[2]={1,200,600,""},
	[3]={1,400,900,""},
	[4]={1,800,1200,""},
	[5]={1,1500,1500,""},
	[6]={1,3000,1800,""},
	[7]={1,5000,2100,""},
	[8]={1,8000,2400,""},
	[9]={1,12000,2700,""},
	[10]={1,20000,3000,""},
	[11]={1,30000,3300,""},
	[12]={1,50000,3600,""}
}

ConfigInstance.petConf={
	[5001101]={"宠物蛋1",2,5,{1,2},{1,1},"排球狗","排球狗",1.2},
	[5001102]={"宠物蛋1",3,5,{1,2},{1,1},"乒乓球兔","乒乓球兔",1.5},
	[5001103]={"宠物蛋1",4,5,{1,2},{1,1},"篮球熊","篮球熊",2},
	[5001201]={"宠物蛋2",2,5,{1,2},{1,1},"铅笔蜂","铅笔蜂",2},
	[5001202]={"宠物蛋2",3,5,{1,2},{1,1},"书本熊","书本熊",3},
	[5001203]={"宠物蛋2",4,5,{1,2},{1,1},"尺子豹","尺子豹",4},
	[5001204]={"宠物蛋2",5,5,{1,2},{1,1},"博士猴","博士猴",5},
	[5001301]={"宠物蛋3",2,5,{1,2},{1,1},"兔子向导","兔子向导",5},
	[5001302]={"宠物蛋3",3,5,{1,2},{1,1},"探险松鼠","探险松鼠",6},
	[5001303]={"宠物蛋3",4,5,{1,2},{1,1},"矿工猫猫","矿工猫猫",7},
	[5001304]={"宠物蛋3",80,5,{1,2},{1,1},"寻宝豹","寻宝豹",10}
}

ConfigInstance.peteggConf={
	[7000001]={"Egg1","Egg1","Egg1",7,{5001101,5001102,5001103},{524000,300000,110000},1,2,"宠物蛋1"},
	[7000002]={"Egg2","Egg2","Egg2",7,{5001201,5001202,5001203,5001204},{524000,300000,110000,50000},1,300,"宠物蛋2"},
	[7000003]={"Egg3","Egg3","Egg3",7,{5001301,5001302,5001303,5001304},{524000,300000,110000,50000},1,2000,"宠物蛋3"}
}

ConfigInstance.settingConf={
	[1]={"称号","EquipTitle",1,3,0,{},"",{},1,""},
	[2]={"兑换码","Code",1,4,0,{},"",{"请输入兑换码"},1,""},
	[3]={"背景音乐","BGM",2,1,100,{0,100},"",{},1,""},
	[4]={"游戏音效","EFFECT",2,1,100,{0,100},"",{},1,""},
	[5]={"任务","TASK",5,0,0,{0,1},"",{"关闭","开启"},0,""},
	[6]={"图像质量","GraphicsQuality",3,3,1,{0,1},"",{"低","高"},1,""},
	[7]={"界面尺寸","PopScale",3,1,100,{75,100},"",{},0,""},
	[8]={"快捷栏尺寸","ToolScale",3,1,100,{50,150},"",{},0,""},
	[9]={"物理效果","Pyhsic",3,2,1,{0,1},"",{"关闭","开启"},1,""},
	[10]={"屏幕震动","Shake",3,1,100,{0,100},"",{},1,""},
	[11]={"瞄准模式","AILock",4,3,1,{0,1},"",{"跟随鼠标","智能锁定"},1,"1"},
	[12]={"自动锁敌","TargetSelectMode",4,3,0,{0,1},"",{"锁定当前目标","锁定最近目标"},1,""},
	[13]={"长按攻击","HoldAtk",4,2,1,{0,1},"",{"关闭","开启"},1,""},
	[14]={"隐藏头部饰品","HideSelfHat",5,2,0,{0,1},"",{"关闭","开启"},1,""},
	[15]={"隐藏巫师袍","HideSelfRobe",5,2,0,{0,1},"",{"关闭","开启"},1,""},
	[16]={"隐藏种族外观","HideRace",5,2,0,{0,1},"",{"关闭","开启"},1,""},
	[17]={"视野范围","FieldOfView",5,1,70,{50,90},"",{},0,""},
	[18]={"掉落物模型","TipsItem",5,2,1,{0,1},"",{"关闭","开启"},1,""},
	[19]={"显示他人信息","ShowOtherPlrInfo",5,2,1,{0,1},"",{"关闭","开启"},1,""},
	[20]={"用户界面","HideUI",5,2,1,{0,1},"",{"关闭","开启"},1,""},
	[21]={"自动加点","AutoAttrPoint",5,2,1,{0,1},"",{"关闭","开启"},0,""},
	[22]={"记忆快速炼金","AutoGame3",5,2,0,{0,1},"",{},0,""},
	[23]={"奔跑模式","RunMode",4,3,0,{0,1},"",{"一键切换","长按奔跑"},1,""}
}

ConfigInstance.skillConf={
	[10000002]={"冲刺","NewRoll","","玩家基础技能","",1,0,1,0,0,0,"向前冲刺一段距离",0,3,2,{0},"",{},"基础技能","","","",{1},{1,1},{}},
	[10000010]={"演示施法","SkillDemoCast","","框架样例","",1,0,1,0,0,0,"短施法锁移动样例",0,3,2,{0},"",{},"主动技能","","","",{1},{1,1},{}},
	[10000011]={"陨石术","Meteor","","框架样例","",1,50,1,0,2,120,"在目标位置召唤一枚陨石",2,3,2,{1},"",{},"主动技能","","","",{0.6},{1,2},{}},
	[10000012]={"空间技能","SpaceSkill","","框架样例","",1,80,1,0,2,0,"空间裂缝双球表现（纯表现首版）",0,3,12,{0},"",{},"主动技能","","","",{1},{1,1},{}}
}

ConfigInstance.updatelogConf={
	[1]={1778839200,"更新_页签标题_1",{"更新_内容标题_1","更新_内容_1_1","更新_内容_1_2","更新_内容_1_3"}}
}
return ConfigInstance
