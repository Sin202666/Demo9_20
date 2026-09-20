--[[
	Module: StoreRegistry
	Description: SystemDataStore 注册的 DataStore / GlobalDataStore 配置
	Author: Dev-Framework
	Created: 2026-07-03
	Last Modified: 2026-07-03
]]

-- ========================================
-- 模块定义
-- ========================================
local StoreRegistry = {}

-- ========================================
-- 常量定义
-- ========================================

export type StoreKind = "DataStore" | "GlobalDataStore"

export type StoreEntry = {
	kind: StoreKind,
	name: string?,
	nameFromConfig: string?,
}

-- 逻辑 Store ID，供 SystemDataStore.Get/Set 第一参数使用
StoreRegistry.STORE = {
	Player = "Player",
	Email = "Email",
	CDK = "CDK",
	PurchaseHistory = "PurchaseHistory",
	Global = "Global",
}

local ENTRIES: { [string]: StoreEntry } = {
	[StoreRegistry.STORE.Player] = {
		kind = "DataStore",
		nameFromConfig = "DataStore",
	},
	[StoreRegistry.STORE.Email] = {
		kind = "DataStore",
		name = "Email",
	},
	[StoreRegistry.STORE.CDK] = {
		kind = "DataStore",
		name = "CDKPools",
	},
	[StoreRegistry.STORE.PurchaseHistory] = {
		kind = "DataStore",
		name = "PurchaseHistory",
	},
	[StoreRegistry.STORE.Global] = {
		kind = "GlobalDataStore",
	},
}

StoreRegistry.ENTRIES = ENTRIES

return StoreRegistry
