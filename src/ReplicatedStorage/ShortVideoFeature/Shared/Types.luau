--[[
	Module: Types
	Description: ShortVideoFeature 共享类型说明（供注释与严格模式参考）
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-14
]]

export type VideoItem = {
	id: string,
	videoId: number,
	title: string?,
}

export type CommentItem = {
	cid: string,
	userId: number,
	name: string,
	text: string,
	likeCount: number,
	createdAt: number,
}

-- FetchComments 分页游标（上一页最后一条）
-- score：hot=赞序合成分；newest=createdAt（unix 秒）
export type CommentCursor = {
	score: number,
	cid: string,
}

-- FetchComments 排序：Constants.COMMENT_SORT.Hot | Newest
export type CommentSortMode = "hot" | "newest"

export type OpenOptions = {
	exitOnDeath: boolean?,
	exitOnCharacterRemove: boolean?,
	exitOnCameraDisturb: boolean?,
	lockCharacter: boolean?,
	boardAnchor: string?, -- "camera" | "character"
	followBoard: boolean?,
	displayMode: string?, -- "scene" | "screen"
	onClosed: ((reason: string?) -> ())?,
	-- 覆盖 Shared/Constants.UI 的局部字段（Nav / Action / Loading / ButtonFeedback）
	ui: any?,
}

local Types = {}
return Types