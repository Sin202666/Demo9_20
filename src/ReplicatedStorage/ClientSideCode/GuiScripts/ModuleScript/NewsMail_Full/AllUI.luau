--[[
	Module: AllUI
	Description: NewsMail_Full 弹窗 UI 节点索引
	Author: Dev-Framework
	Created: 2026-07-03
	Last Modified: 2026-07-03

	功能：
	- 绑定 ScreenGui_Full 下 NewsMail_Full 各 Frame/ScrollingFrame 引用
	- 供 init / Mail / News 子模块只读访问，不包含业务逻辑
]]

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui", math.huge)
local screenGui = playerGui:WaitForChild("ScreenGui_Full", math.huge)
local rootFrame = screenGui:WaitForChild("NewsMail_Full", math.huge)
local contentRoot = rootFrame:FindFirstChild("ContentClip") or rootFrame

local AllUI = {
	UIRoot = rootFrame,
}
-- NewsMail_Full.Main._Exit
AllUI["Exit"] = contentRoot["Main"]["_Exit"] :: Frame
-- NewsMail_Full.Main._MailPanel
AllUI["MailPanel"] = contentRoot["Main"]["_MailPanel"] :: Frame
-- NewsMail_Full.Main._UpdatePanel
AllUI["UpdatePanel"] = contentRoot["Main"]["_UpdatePanel"] :: Frame
-- NewsMail_Full.Main.TagList._MailTag
AllUI["MailTag"] = contentRoot["Main"]["TagList"]["_MailTag"] :: Frame
-- NewsMail_Full.Main.TagList._UpdateTag
AllUI["UpdateTag"] = contentRoot["Main"]["TagList"]["_UpdateTag"] :: Frame
-- NewsMail_Full.Main.Top._MailTitle
AllUI["MailTitle"] = contentRoot["Main"]["Top"]["_MailTitle"] :: Frame
-- NewsMail_Full.Main.Top._UpdateTitle
AllUI["UpdateTitle"] = contentRoot["Main"]["Top"]["_UpdateTitle"] :: Frame
-- NewsMail_Full.Main._MailPanel.AnimClips._MailBtnFrame
AllUI["MailBtnFrame"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailBtnFrame"] :: Frame
-- NewsMail_Full.Main._MailPanel.AnimClips._MailContent
AllUI["MailContent"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailContent"] :: Frame
-- NewsMail_Full.Main._MailPanel.AnimClips._MailLine
AllUI["MailLine"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailLine"] :: ImageLabel
-- NewsMail_Full.Main._MailPanel.Tag._MailPanelTag
AllUI["MailPanelTag"] = contentRoot["Main"]["_MailPanel"]["Tag"]["_MailPanelTag"] :: ScrollingFrame
-- NewsMail_Full.Main._MailPanel.Tag._MailScrollBar
AllUI["MailScrollBar"] = contentRoot["Main"]["_MailPanel"]["Tag"]["_MailScrollBar"] :: ImageLabel
-- NewsMail_Full.Main._UpdatePanel.AnimClips._UpdateContent
AllUI["UpdateContent"] = contentRoot["Main"]["_UpdatePanel"]["AnimClips"]["_UpdateContent"] :: Frame
-- NewsMail_Full.Main._UpdatePanel.Tag._UpdatePanelTag
AllUI["UpdatePanelTag"] = contentRoot["Main"]["_UpdatePanel"]["Tag"]["_UpdatePanelTag"] :: ScrollingFrame
-- NewsMail_Full.Main._UpdatePanel.Tag._UpdateScrollBar
AllUI["UpdateScrollBar"] = contentRoot["Main"]["_UpdatePanel"]["Tag"]["_UpdateScrollBar"] :: ImageLabel
-- NewsMail_Full.Main._MailPanel.AnimClips._MailBtnFrame._ClaimBtn
AllUI["ClaimBtn"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailBtnFrame"]["_ClaimBtn"] :: Frame
-- NewsMail_Full.Main._MailPanel.AnimClips._MailBtnFrame._DeleteBtn
AllUI["DeleteBtn"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailBtnFrame"]["_DeleteBtn"] :: Frame
-- NewsMail_Full.Main._MailPanel.AnimClips._MailContent._MailScroll
AllUI["MailScroll"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailContent"]["_MailScroll"] :: ScrollingFrame
-- NewsMail_Full.Main._MailPanel.Tag.BG._MailPanelTagBG
AllUI["MailPanelTagBG"] = contentRoot["Main"]["_MailPanel"]["Tag"]["BG"]["_MailPanelTagBG"] :: ImageLabel
-- NewsMail_Full.Main._MailPanel.Tag._MailPanelTag._MailTagTemp
AllUI["MailTagTemp"] = contentRoot["Main"]["_MailPanel"]["Tag"]["_MailPanelTag"]["_MailTagTemp"] :: Frame
-- NewsMail_Full.Main._UpdatePanel.Tag.BG._UpdatePanelTagBG
AllUI["UpdatePanelTagBG"] = contentRoot["Main"]["_UpdatePanel"]["Tag"]["BG"]["_UpdatePanelTagBG"] :: ImageLabel
-- NewsMail_Full.Main._UpdatePanel.Tag._UpdatePanelTag._UpdateTagTemp
AllUI["UpdateTagTemp"] = contentRoot["Main"]["_UpdatePanel"]["Tag"]["_UpdatePanelTag"]["_UpdateTagTemp"] :: Frame
-- NewsMail_Full.Main._MailPanel.AnimClips._MailContent.Title._MailDataTitle
AllUI["MailDataTitle"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailContent"]["Title"]["_MailDataTitle"] :: TextLabel
-- NewsMail_Full.Main._MailPanel.AnimClips._MailContent._MailScroll._MailAwardList
AllUI["MailAwardList"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailContent"]["_MailScroll"]["_MailAwardList"] :: Frame
-- NewsMail_Full.Main._MailPanel.AnimClips._MailContent._MailScroll._MailContentTemp
AllUI["MailContentTemp"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailContent"]["_MailScroll"]["_MailContentTemp"] :: Frame
-- NewsMail_Full.Main._MailPanel.AnimClips._MailContent._MailScroll._MailContentTitleTemp
AllUI["MailContentTitleTemp"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailContent"]["_MailScroll"]["_MailContentTitleTemp"] :: Frame
-- NewsMail_Full.Main._UpdatePanel.AnimClips._UpdateContent.Title._UpdateCfgTitle
AllUI["UpdateCfgTitle"] = contentRoot["Main"]["_UpdatePanel"]["AnimClips"]["_UpdateContent"]["Title"]["_UpdateCfgTitle"] :: TextLabel
-- NewsMail_Full.Main._MailPanel.AnimClips._MailContent._MailScroll._MailAwardList._MailAwardTemp
AllUI["MailAwardTemp"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailContent"]["_MailScroll"]["_MailAwardList"]["_MailAwardTemp"] :: Frame
-- NewsMail_Full.Main._MailPanel.AnimClips._MailContent._MailScroll._MailAwardList._MailAwardTemp_Title
AllUI["MailAwardTemp_Title"] = contentRoot["Main"]["_MailPanel"]["AnimClips"]["_MailContent"]["_MailScroll"]["_MailAwardList"]["_MailAwardTemp_Title"] :: Frame

return AllUI
